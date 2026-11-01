import { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import { formatEther, isAddress, toHex, type Address, type Hex } from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';
import { MONAD_CHAIN_ID, MONAD_RPC_URL } from './config';
import { publicClient, readPlayer, readPending, readFee, readCanAct, readBestRun, readDeferredOutcome, readGasPrice, sendTx, topUp, withdraw, revertOf, isInsufficientFunds, TxReverted, type ChainState } from './contract';
import {
  SESSION_MESSAGE,
  checkBurner,
  clearSessionKey,
  deriveSessionKey,
  getGasMultiplierPct,
  setGasMultiplierPct,
  loadSessionKey,
  rememberBurner,
  rememberedBurner,
  saveSessionKey,
  type StorageLike,
} from './sessionKey';
import { createTxQueue } from './txQueue';
import { canPayWord, parseTopUp, withdrawAmount, wordCost } from './funds';
import { preview } from '@shared/preview';
import { catchUp } from '@shared/time';
import { fallsNoLaterThan } from './edgeBound';
import { Action, getRefusalMessage, getCancelReasonMessage, portalTypeNames } from './types';
import { Journal } from './Journal';
import { Leaderboard } from './Leaderboard';
import type { Pending, BestRun } from '@shared/types';
import './App.css';

declare global {
  interface Window {
    ethereum?: any;
  }
}

interface TransactionStatus {
  pending: boolean;
  message: string;
  error?: string;
  // A legitimate refusal (not a failure): shown amber, not red.
  warn?: string;
}

type GameFunction = 'startGame' | 'act' | 'sync' | 'settle' | 'cancelDeferred';

/** A reverted call the player may send once more with more gas. */
interface RetryCall {
  label: string;
  fn: GameFunction;
  args: readonly unknown[];
  value: bigint;
  doneMessage?: string;
}

const PENDING_POLL_MS = 3000;
const BALANCE_POLL_MS = 10_000;
const RETRY_GAS_PCT = 160;
const NO_FUNDS_ERROR = 'Game wallet has not enough MON';
const GAS_PCT_OPTIONS = [100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200];

// The burner's transactions, one at a time, for the whole page.
const txQueue = createTxQueue({
  getBlockNumber: () => publicClient.getBlockNumber({ cacheTime: 0 }),
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
});

// Read-only view of any player's game: ?player=0x...
const urlPlayer = (() => {
  const p = new URLSearchParams(window.location.search).get('player');
  return p && isAddress(p) ? (p as Address) : null;
})();

const projectAt = (s: ChainState, nowTs: bigint) =>
  preview(
    { game: s.game, portals: s.portals, epochWord: s.epochWord, coveredEpochs: s.pending.coveredEpochs },
    s.config,
    s.types,
    nowTs,
  );

const DISCONNECTED_KEY = 'portal-lab:disconnected';

function readDisconnected(): boolean {
  try {
    return window.localStorage.getItem(DISCONNECTED_KEY) === '1';
  } catch {
    return false;
  }
}

function writeDisconnected(on: boolean) {
  try {
    if (on) window.localStorage.setItem(DISCONNECTED_KEY, '1');
    else window.localStorage.removeItem(DISCONNECTED_KEY);
  } catch {
    // storage unavailable: behave as "not disconnected"
  }
}

// Merely reading window.sessionStorage throws when the browser denies site data.
function browserStorage(name: 'sessionStorage' | 'localStorage'): StorageLike | null {
  try {
    return window[name];
  } catch {
    return null;
  }
}

function restoreBurner(owner: Address): PrivateKeyAccount | null {
  const key = loadSessionKey(browserStorage('sessionStorage'), owner);
  if (!key) return null;
  try {
    return privateKeyToAccount(key);
  } catch {
    return null;
  }
}

const nowSec = () => BigInt(Math.floor(Date.now() / 1000));

/** Refusals are warnings; failed transactions and anything unexpected are errors. */
function describeError(error: unknown): TransactionStatus {
  const r = revertOf(error);
  const fail = (text: string): TransactionStatus => ({ pending: false, message: '', error: text });
  if (error instanceof TxReverted) {
    return fail(
      `Transaction was included but reverted (gas limit ${error.gasLimit}). It may have run out of gas or hit Monad's reserve-balance rule.`,
    );
  }
  if (isInsufficientFunds(error)) return fail(NO_FUNDS_ERROR);
  if (r?.name === 'ActionRefused') {
    return { pending: false, message: '', warn: getRefusalMessage(Number(r.args[0])) };
  }
  if (r?.name === 'NoPendingAction') {
    return { pending: false, message: '', warn: 'Nothing to cancel: the random word has just arrived' };
  }
  if (r?.name === 'RequestNotTimedOut') {
    return { pending: false, message: '', warn: 'Too early to cancel this request' };
  }
  if (r?.name === 'ActionPending') return fail('Previous action is still waiting for the random word');
  if (r?.name === 'InsufficientFee') return fail(`Word fee too low: need ${formatEther(r.args[0] as bigint)} MON`);
  if (r) return fail(r.name);
  return fail((error as { shortMessage?: string })?.shortMessage ?? String(error));
}

function App() {
  // `owner` is the MetaMask wallet: it only connects and signs SESSION_MESSAGE.
  // `burner` is the game key: it is the player and signs every game transaction.
  const [owner, setOwner] = useState<Address | null>(null);
  const [burner, setBurner] = useState<PrivateKeyAccount | null>(null);
  // Current values for async code that outlives a render; changed only with the state above.
  const ownerRef = useRef<Address | null>(null);
  const burnerRef = useRef<PrivateKeyAccount | null>(null);
  // True while a transaction is being sent; the ref guards clicks that land before the re-render.
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [balance, setBalance] = useState<bigint | null>(null);
  const balanceRef = useRef<bigint | null>(null);
  // Word fee and gas price, refreshed together with the balance.
  const [prices, setPrices] = useState<{ fee: bigint; gasPrice: bigint } | null>(null);
  const [topUpInput, setTopUpInput] = useState('3');
  const [confirmWithdraw, setConfirmWithdraw] = useState(false);
  const [gasPct, setGasPct] = useState(120);
  const [unlocking, setUnlocking] = useState(false);
  // A derived key that differs from the one remembered: not in use until the player accepts it.
  const [mismatch, setMismatch] = useState<{ expected: string; key: Hex; address: Address } | null>(null);
  const [retry, setRetry] = useState<RetryCall | null>(null);
  const [copied, setCopied] = useState(false);
  const [chain, setChain] = useState<number | null>(null);
  const [state, setState] = useState<ChainState | null>(null);
  const [now, setNow] = useState(nowSec());
  const [txStatus, setTxStatus] = useState<TransactionStatus>({ pending: false, message: '' });
  const [loading, setLoading] = useState(false);
  // The deferred action we started, so the result can be reported when it clears.
  const awaited = useRef<Pending | null>(null);
  // Block of the transaction that committed the deferral: where to start looking for its outcome events.
  const awaitedBlock = useRef<bigint | null>(null);
  // State as of the moment the deferral was observed, to tell a fresh game's first word from a plain sync.
  const stateRef = useRef<ChainState | null>(null);
  stateRef.current = state;
  const [bestRun, setBestRun] = useState<BestRun | null>(null);
  const [confirmNew, setConfirmNew] = useState(false);
  // Mirrors the localStorage flag; read by the one-time accountsChanged listener.
  const disconnected = useRef(readDisconnected());
  // A cancellation must never be reported as a word delivery: the poll bails while
  // one is in flight (`cancelling`) and when one finished since the poll started (`cancelEpoch`).
  const cancelling = useRef(false);
  const cancelEpoch = useRef(0);

  const player = burner?.address ?? urlPlayer;

  const adoptBurner = useCallback((next: PrivateKeyAccount | null) => {
    if (next?.address === burnerRef.current?.address) return;
    burnerRef.current = next;
    setBurner(next);
    // A different player: nothing on screen or in flight belongs to them.
    setBalance(null);
    balanceRef.current = null;
    setPrices(null);
    setConfirmWithdraw(false);
    setGasPct(next ? getGasMultiplierPct(browserStorage('localStorage'), next.address) : 120);
    setState(null);
    setBestRun(null);
    setConfirmNew(false);
    setRetry(null);
    setTxStatus({ pending: false, message: '' });
    awaited.current = null;
    awaitedBlock.current = null;
  }, []);

  const adoptOwner = useCallback((next: Address | null) => {
    if (next?.toLowerCase() === ownerRef.current?.toLowerCase()) return;
    ownerRef.current = next;
    setOwner(next);
    setMismatch(null);
    // The game key belongs to one owner: a switched account must not keep playing with it.
    adoptBurner(next ? restoreBurner(next) : null);
  }, [adoptBurner]);

  useEffect(() => {
    if (!window.ethereum) return;
    if (!disconnected.current) {
      window.ethereum.request({ method: 'eth_accounts' }).then((a: string[]) => a[0] && adoptOwner(a[0] as Address));
    }
    window.ethereum.request({ method: 'eth_chainId' }).then((id: string) => setChain(parseInt(id, 16)));
    window.ethereum.on?.('accountsChanged', (a: string[]) => {
      if (disconnected.current) return;
      const next = (a[0] as Address) ?? null;
      if (!next && ownerRef.current) clearSessionKey(browserStorage('sessionStorage'), ownerRef.current);
      adoptOwner(next);
    });
    window.ethereum.on?.('chainChanged', (id: string) => setChain(parseInt(id, 16)));
  }, [adoptOwner]);

  const connectWallet = async () => {
    if (!window.ethereum) {
      setTxStatus({ pending: false, message: '', error: 'MetaMask not found' });
      return;
    }
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    disconnected.current = false;
    writeDisconnected(false);
    adoptOwner(accounts[0]);
    const id = await window.ethereum.request({ method: 'eth_chainId' });
    setChain(parseInt(id as string, 16));
  };

  const disconnectWallet = async () => {
    // The key goes first: the wallet may keep the revoke request open indefinitely.
    disconnected.current = true;
    writeDisconnected(true);
    if (ownerRef.current) clearSessionKey(browserStorage('sessionStorage'), ownerRef.current);
    adoptOwner(null);
    setTxStatus({ pending: false, message: '' });
    try {
      await window.ethereum?.request({ method: 'wallet_revokePermissions', params: [{ eth_accounts: {} }] });
    } catch {
      // not every wallet supports revoking permissions
    }
  };

  const adoptKey = (signer: Address, key: Hex) => {
    saveSessionKey(browserStorage('sessionStorage'), signer, key);
    adoptBurner(privateKeyToAccount(key));
  };

  const unlockGameKey = async () => {
    const signer = ownerRef.current;
    if (!signer) return;
    setUnlocking(true);
    try {
      const signature = (await window.ethereum.request({
        method: 'personal_sign',
        params: [toHex(SESSION_MESSAGE), signer],
      })) as Hex;
      // The wallet may have switched accounts while its prompt was open.
      if (ownerRef.current !== signer) return;
      const key = deriveSessionKey(signature);
      const { address } = privateKeyToAccount(key);
      const local = browserStorage('localStorage');
      const known = checkBurner(local, signer, address);
      if (known === 'mismatch') {
        setMismatch({ expected: rememberedBurner(local, signer) ?? '', key, address });
        return;
      }
      if (known === 'new') rememberBurner(local, signer, address);
      adoptKey(signer, key);
    } catch (error) {
      const reason = error as { code?: number; message?: string } | null;
      setTxStatus({
        pending: false,
        message: '',
        error: reason?.code === 4001 ? 'Signature request was rejected' : (reason?.message ?? String(error)),
      });
    } finally {
      setUnlocking(false);
    }
  };

  const acceptNewKey = () => {
    const signer = ownerRef.current;
    if (!signer || !mismatch) return;
    rememberBurner(browserStorage('localStorage'), signer, mismatch.address);
    adoptKey(signer, mismatch.key);
    setMismatch(null);
  };

  const copyBurnerAddress = async () => {
    if (!burner) return;
    try {
      await navigator.clipboard.writeText(burner.address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      setTxStatus({ pending: false, message: '', error: `Could not copy. Game key address: ${burner.address}` });
    }
  };

  const switchToMonad = async () => {
    const chainId = `0x${MONAD_CHAIN_ID.toString(16)}`;
    try {
      await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] });
    } catch (error: any) {
      if (error.code !== 4902) throw error;
      await window.ethereum.request({
        method: 'wallet_addEthereumChain',
        params: [{
          chainId,
          chainName: 'Monad Testnet',
          rpcUrls: [MONAD_RPC_URL],
          nativeCurrency: { name: 'MON', symbol: 'MON', decimals: 18 },
        }],
      });
    }
    const id = await window.ethereum.request({ method: 'eth_chainId' });
    setChain(parseInt(id as string, 16));
  };

  // Bumped wherever the best run is re-read: the leaderboard re-reads at the same moments.
  const [leaderboardTick, setLeaderboardTick] = useState(0);

  const refreshBestRun = useCallback((p: Address) => {
    setLeaderboardTick((t) => t + 1);
    readBestRun(p).then(setBestRun).catch((error) => console.error('Failed to load best run:', error));
  }, []);

  const load = useCallback(async () => {
    if (!player) return;
    setLoading(true);
    try {
      const fresh = await readPlayer(player);
      // The game key may have been unlocked or dropped during the read.
      if ((burnerRef.current?.address ?? urlPlayer) !== player) return;
      setState(fresh);
      setNow(nowSec());
      refreshBestRun(player);
    } catch (error) {
      console.error('Failed to load game state:', error);
      setTxStatus(describeError(error));
    } finally {
      setLoading(false);
    }
  }, [player, refreshBestRun]);

  useEffect(() => {
    load();
  }, [load]);

  const refreshBalance = useCallback(async (address: Address) => {
    try {
      const [value, fee, gasPrice] = await Promise.all([
        publicClient.getBalance({ address }),
        readFee(),
        readGasPrice(),
      ]);
      if (burnerRef.current?.address !== address) return;
      const before = balanceRef.current;
      balanceRef.current = value;
      setBalance(value);
      setPrices({ fee, gasPrice });
      // Funds arrived: the "not enough MON" error is stale.
      if (before !== null && value > before) {
        setTxStatus((s) => (s.error === NO_FUNDS_ERROR ? { ...s, error: undefined } : s));
      }
    } catch (error) {
      console.error('Failed to load balance:', error);
    }
  }, []);

  const burnerAddress = burner?.address;
  useEffect(() => {
    if (!burnerAddress) return;
    refreshBalance(burnerAddress);
    const id = setInterval(() => refreshBalance(burnerAddress), BALANCE_POLL_MS);
    return () => clearInterval(id);
  }, [burnerAddress, refreshBalance]);

  // Clock for the local projection.
  useEffect(() => {
    const id = setInterval(() => setNow(nowSec()), 1000);
    return () => clearInterval(id);
  }, []);

  const projected = useMemo(() => (state ? projectAt(state, now) : null), [state, now]);

  // While a deferred action waits for its word, poll getPending; when it clears,
  // reload and report what happened.
  const pendingActive = state?.pending.active ?? false;
  useEffect(() => {
    if (!pendingActive || !player) return;
    let live = true;
    const id = setInterval(async () => {
      const epoch = cancelEpoch.current;
      const cancelled = () => !live || cancelling.current || cancelEpoch.current !== epoch;
      try {
        const p = await readPending(player);
        if (p.active || cancelled()) return;
        // The outcome events are at or before this block.
        const seenAt = await publicClient.getBlockNumber({ cacheTime: 0 });
        const fresh = await readPlayer(player);
        if (cancelled()) return;
        setState(fresh);
        setNow(nowSec());
        const done = awaited.current;
        const fromBlock = awaitedBlock.current;
        awaited.current = null;
        awaitedBlock.current = null;
        const message = await resultMessage(done, fresh, stateRef.current, player, fromBlock, seenAt);
        if (cancelled()) return;
        setTxStatus({ pending: false, message });
      } catch (error) {
        console.error('Pending poll failed:', error);
      }
    }, PENDING_POLL_MS);
    return () => {
      live = false;
      clearInterval(id);
    };
  }, [pendingActive, player]);

  const send = async (
    label: string,
    fn: GameFunction,
    args: readonly unknown[],
    value = 0n,
    doneMessage?: string,
    retryGasPct?: number,
  ) => {
    const key = burner;
    if (!key || busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    const dropped = () => burnerRef.current !== key;
    setConfirmNew(false);
    setRetry(null);
    setTxStatus({ pending: true, message: label });
    try {
      const pct = retryGasPct ?? getGasMultiplierPct(browserStorage('localStorage'), key.address);
      const { hash, blockNumber } = await txQueue.enqueue(async () => {
        // Disconnecting must stop what is still queued: nothing signs after the key is dropped.
        if (dropped()) throw new Error('Game key is no longer active');
        return sendTx(key, fn, args, pct, value);
      });
      if (dropped()) return;
      const fresh = await readPlayer(key.address);
      if (dropped()) return;
      setState(fresh);
      setNow(nowSec());
      if (fn === 'settle' || fn === 'startGame') refreshBestRun(key.address);
      if (fresh.pending.active) {
        awaited.current = fresh.pending;
        awaitedBlock.current = blockNumber;
        setTxStatus({ pending: true, message: `${label}: waiting for the random word from Pyth (tx ${hash.slice(0, 10)}…)` });
      } else {
        setTxStatus({ pending: false, message: doneMessage ?? `${label}: done (tx ${hash.slice(0, 10)}…)` });
      }
    } catch (error) {
      if (dropped()) return;
      console.error(error);
      setTxStatus(describeError(error));
      if (error instanceof TxReverted && retryGasPct === undefined) setRetry({ label, fn, args, value, doneMessage });
    } finally {
      busyRef.current = false;
      setBusy(false);
      refreshBalance(key.address);
    }
  };

  const performAction = async (slot: number, action: Action) => {
    if (!burner || !state || busyRef.current) return;
    if (state.pending.active) {
      setTxStatus({ pending: true, message: 'Previous action is still waiting for the random word' });
      return;
    }
    const refusal = await readCanAct(burner.address, slot, action);
    if (refusal !== 0) {
      setTxStatus({ pending: false, message: '', warn: getRefusalMessage(refusal) });
      return;
    }
    // PortalLab.act refunds msg.value in full when no word was needed and refunds
    // the excess when one was. Attaching the fee unconditionally removes the race
    // between prediction and execution.
    const value = await readFee();
    await send(`Action ${Action[action]} on slot ${slot}`, 'act', [slot, action], value);
  };

  const cancelRequest = async (retryGasPct?: number) => {
    if (!burner) return;
    cancelling.current = true;
    cancelEpoch.current += 1;
    awaited.current = null;
    awaitedBlock.current = null;
    try {
      await send('Cancel request', 'cancelDeferred', [burner.address], 0n, 'Request cancelled', retryGasPct);
    } finally {
      cancelling.current = false;
      cancelEpoch.current += 1;
    }
  };

  const retryWithMoreGas = async () => {
    if (!retry) return;
    // A cancellation keeps its guard against the pending poll.
    if (retry.fn === 'cancelDeferred') await cancelRequest(RETRY_GAS_PCT);
    else await send(retry.label, retry.fn, retry.args, retry.value, retry.doneMessage, RETRY_GAS_PCT);
  };

  const runFunds = async (label: string, job: () => Promise<{ hash: Hex }>, queued: boolean) => {
    const key = burner;
    if (!key || busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setConfirmWithdraw(false);
    setTxStatus({ pending: true, message: label });
    try {
      const { hash } = await job();
      if (burnerRef.current !== key) return;
      setTxStatus({ pending: false, message: `${label}: done (tx ${hash.slice(0, 10)}…)` });
    } catch (error) {
      if (burnerRef.current !== key) return;
      console.error(error);
      const code = (error as { code?: number } | null)?.code;
      if (!queued && code === 4001) setTxStatus({ pending: false, message: '', error: 'Transaction was rejected in the wallet' });
      else setTxStatus(describeError(error));
    } finally {
      busyRef.current = false;
      setBusy(false);
      refreshBalance(key.address);
    }
  };

  const topUpFromWallet = async () => {
    const amount = parseTopUp(topUpInput);
    const from = ownerRef.current;
    if (!burner || !from || amount === null) return;
    await runFunds(
      'Top up',
      async () => {
        if (chain !== MONAD_CHAIN_ID) await switchToMonad();
        return topUp(from, burner.address, amount);
      },
      false,
    );
  };

  const withdrawToWallet = async () => {
    const key = burner;
    const to = ownerRef.current;
    if (!key || !to) return;
    await runFunds(
      'Withdraw',
      () =>
        txQueue.enqueue(async () => {
          if (burnerRef.current !== key) throw new Error('Game key is no longer active');
          return withdraw(key, to);
        }),
      true,
    );
  };

  const game = projected?.game;
  const hasGame = !!game && game.startedAt !== 0n;
  // Seconds until the pending request can be cancelled (contract: block.timestamp > committedAt + timeout).
  const cancelWait =
    state && state.pending.active
      ? BigInt(state.pending.committedAt) + state.config.requestTimeoutHours * state.config.secPerHour - now + 1n
      : 0n;
  const openingLab = !!game && !game.finished && game.hoursElapsed === 0n && game.openPortals === 0n;

  // Everything the stored state will do before the next random word, if the player does nothing.
  const forecast = useMemo(() => {
    if (!state || !projected || state.game.startedAt === 0n || state.game.finished) return null;
    const covered = state.pending.coveredEpochs;
    // No word pinned, or the projection already sits at the edge: nothing to forecast.
    if (covered === 0n || projected.cappedShort) return null;
    try {
      const sph = state.config.secPerHour;
      const lastHour = covered * state.config.epochHours - 1n;
      // The last second of the last covered hour: the walk must not cross the pinned edge.
      const edgeTs = state.game.startedAt + (lastHour + 1n) * sph - 1n;
      const r = catchUp(
        state.game, state.portals, state.config, state.types,
        state.epochWord, state.epochWord, covered, covered,
        edgeTs,
      );
      const spawns = r.spawns
        .filter((sp) => sp.atHour > projected.game.hoursElapsed)
        .map((sp) => ({
          atHour: sp.atHour,
          inSec: state.game.startedAt + sp.atHour * sph - now,
          portalType: sp.portalType,
        }));
      const fallsAt = r.game.finished && r.game.diedAtHour <= lastHour ? r.game.diedAtHour : null;
      const boundAfterEdge = fallsAt === null ? fallsNoLaterThan(r.game, r.portals, state.config) : null;
      return { spawns, edgeHour: lastHour, fallsAt, boundAfterEdge };
    } catch (error) {
      console.error('Forecast failed:', error);
      return null;
    }
  }, [state, projected, now]);

  const secondsUntilHour = (hour: bigint): bigint => {
    const s = (game?.startedAt ?? 0n) + hour * (state?.config.secPerHour ?? 0n) - now;
    return s > 0n ? s : 0n;
  };
  // Latest fall hour while the world is held at the edge of its random word.
  const pausedBound =
    state && projected && projected.cappedShort && !projected.game.finished && !state.pending.active
      ? fallsNoLaterThan(projected.game, projected.portals, state.config)
      : null;
  const wallHour =
    game && state && state.config.secPerHour > 0n ? (now - game.startedAt) / state.config.secPerHour : 0n;

  return (
    <div className="app">
      <header className="header">
        <h1>Unstable Portals Lab</h1>
        <div className="wallet-section">
          {!owner ? (
            <button onClick={connectWallet} className="primary">
              Connect Wallet
            </button>
          ) : (
            <>
              <span className="address">{owner.slice(0, 6)}...{owner.slice(-4)}</span>
              {burner ? (
                <div className="game-key">
                  <span className="address">Game key {burner.address.slice(0, 6)}...{burner.address.slice(-4)}</span>
                  <button onClick={copyBurnerAddress}>{copied ? 'Copied' : 'Copy address'}</button>
                  {balance !== null && (
                    <span className="game-key-balance">{Number(formatEther(balance)).toFixed(4)} MON</span>
                  )}
                  {balance === 0n && <span className="game-key-fund">Fund this address from your wallet to play</span>}
                </div>
              ) : (
                <button onClick={unlockGameKey} className="primary" disabled={unlocking}>
                  Unlock game key
                </button>
              )}
              <button onClick={disconnectWallet}>Disconnect</button>
              {chain !== MONAD_CHAIN_ID && (
                <button onClick={switchToMonad} className="danger">
                  Switch to Monad Testnet
                </button>
              )}
            </>
          )}
          {!burner && urlPlayer && <span className="address">View only: {urlPlayer.slice(0, 6)}...{urlPlayer.slice(-4)}</span>}
        </div>
      </header>

      {burner && (
        <div className="funds-panel">
          <h2>Game key</h2>
          <div>
            Balance: <span className="game-key-balance">{balance === null ? '…' : `${Number(formatEther(balance)).toFixed(4)} MON`}</span>
            {balance !== null && prices && (
              <> · ≈ {String(balance / wordCost(prices.fee, prices.gasPrice))} random words left</>
            )}
          </div>
          {balance !== null && prices && !canPayWord(balance, prices.fee, prices.gasPrice) && (
            <div className="warn-message">
              Not enough MON for the next random word (~{Number(formatEther(wordCost(prices.fee, prices.gasPrice))).toFixed(4)} MON). Top up.
            </div>
          )}
          <div className="funds-row">
            <input
              type="text"
              inputMode="decimal"
              value={topUpInput}
              onChange={(e) => setTopUpInput(e.target.value)}
              aria-label="Top up amount in MON"
            />
            <button onClick={topUpFromWallet} disabled={busy || parseTopUp(topUpInput) === null}>
              Top up from wallet
            </button>
            <button onClick={() => setConfirmWithdraw(true)} disabled={busy || !!state?.pending.active}>
              Withdraw all to wallet
            </button>
          </div>
          {confirmWithdraw && owner && balance !== null && prices && (
            <div className="warn-message">
              Send ~{Number(formatEther(withdrawAmount(balance, prices.gasPrice))).toFixed(4)} MON to {owner}? Your game key will be
              empty and cannot act until topped up.{' '}
              <button onClick={withdrawToWallet} disabled={busy || !!state?.pending.active}>Withdraw</button>{' '}
              <button onClick={() => setConfirmWithdraw(false)}>Cancel</button>
            </div>
          )}
          <div className="funds-row">
            <label>
              Gas multiplier{' '}
              <select
                value={gasPct}
                onChange={(e) => {
                  const pct = Number(e.target.value);
                  setGasPct(pct);
                  setGasMultiplierPct(browserStorage('localStorage'), burner.address, pct);
                }}
              >
                {GAS_PCT_OPTIONS.map((p) => (
                  <option key={p} value={p}>{p}%</option>
                ))}
              </select>
            </label>
            <small>Monad charges the full gas limit; 120% has been enough in every measured transaction.</small>
          </div>
        </div>
      )}

      {mismatch && (
        <div className="warn-message">
          <p>
            Your wallet produced a different game key than before on this browser (expected {mismatch.expected}, got{' '}
            {mismatch.address}). It may not sign deterministically.
          </p>
          <button onClick={acceptNewKey}>Use the new key anyway</button>
        </div>
      )}
      {txStatus.error && <div className="error-message">{txStatus.error}</div>}
      {retry && (
        <div className="error-message">
          <button onClick={retryWithMoreGas} disabled={busy}>Retry with more gas</button>
        </div>
      )}
      {txStatus.warn && <div className="warn-message">{txStatus.warn}</div>}
      {txStatus.message && <div className="info-message">{txStatus.message}</div>}
      {state?.pending.active && (
        <div className="info-message">
          Waiting for the random word from Pyth: action {Action[state.pending.action]} on slot {String(state.pending.slot)}
          {state.pending.syncOnly ? ' (paid sync)' : ''}, request #{String(state.pending.requestId)}.
          Checking every {PENDING_POLL_MS / 1000} s…
          <div>
            {cancelWait > 0n ? (
              <>Can be cancelled in {String(cancelWait)} s</>
            ) : (
              <>
                <button onClick={() => cancelRequest()} disabled={!burner || busy}>
                  Cancel request
                </button>{' '}
                The Pyth fee is not refunded.
              </>
            )}
          </div>
        </div>
      )}

      {!player ? (
        <div className="no-game">
          <p>
            {owner
              ? 'Unlock your game key to play: one signature, then no more wallet popups.'
              : 'Connect your wallet (or open the page with ?player=0x…)'}
          </p>
        </div>
      ) : loading && !state ? (
        <div className="loading">Loading game state...</div>
      ) : !hasGame || !projected || !game ? (
        <div className="no-game">
          <p>No active game. Start a new one!</p>
          <button onClick={async () => send('New game', 'startGame', [], await readFee())} className="primary" disabled={!burner || busy}>
            Start Game
          </button>
        </div>
      ) : (
        <div className="game-container">
          <div className="stats-panel">
            <div className="stat">
              <label>HP</label>
              <div className="value">{String(game.hp)}</div>
            </div>
            <div className="stat">
              <label>Power</label>
              <div className="value">{String(game.power)}</div>
            </div>
            <div className="stat">
              <label>Hours Survived</label>
              <div className="value">{String(game.hoursElapsed)}</div>
            </div>
            <div className="stat">
              <label>Free Observers</label>
              <div className="value">{String(game.observersFree)}</div>
            </div>
            <div className="stat">
              <label>Free Rescuers</label>
              <div className="value">{String(game.rescuersFree)}</div>
            </div>
            <div className="stat">
              <label>Creatures Rescued</label>
              <div className="value">{String(game.creaturesRescued)}</div>
            </div>
            <div className="stat">
              <label>Status</label>
              <div className="value">{game.finished ? 'FINISHED' : 'ACTIVE'}</div>
            </div>
          </div>

          {openingLab && state?.pending.active && (
            <div className="info-message">Opening the lab — waiting for the random word</div>
          )}

          {projected.cappedShort && !game.finished && !state?.pending.active && (
            <div className="info-message">
              The world is paused at hour {String(game.hoursElapsed)}. It needs a fresh random epoch word;
              any action will fetch one (Pyth fee).
              {pausedBound !== null &&
                (wallHour < pausedBound ? (
                  <p className="forecast-death">
                    Without a new word the lab falls no later than hour {String(pausedBound)} (in{' '}
                    {String(secondsUntilHour(pausedBound))} s).
                  </p>
                ) : (
                  <p className="forecast-death">
                    The lab has fallen by hour {String(pausedBound)} at the latest. Sync (pays for word) to record the run.
                  </p>
                ))}
            </div>
          )}

          {game.finished ? (
            <div className="run-over">
              <h2>Run over</h2>
              <p>Hours survived: {String(game.diedAtHour)}</p>
              <p>Creatures rescued: {String(game.creaturesRescued)}</p>
              <p>
                {game.settled
                  ? 'This run is recorded.'
                  : 'This run is not recorded yet. Settle it, or start a new game: the finished run will be recorded automatically.'}
              </p>
              {bestRun && bestRun.settledAt !== 0n && (
                <p>
                  Best run: {String(bestRun.hoursSurvived)} hours, {String(bestRun.creaturesRescued)} creatures rescued
                </p>
              )}
            </div>
          ) : (
          <div className="portals-grid">
            {projected.portals.map((portal, idx) => {
              return (
              <div key={idx} className={`portal ${portal.status === 0 ? 'empty' : 'open'}`}>
                <div className="portal-header">
                  <h3>Slot {idx}</h3>
                  {portal.status !== 0 && (
                    <span className="type">
                      {portalTypeNames[portal.portalType] || 'Unknown'}
                    </span>
                  )}
                </div>

                {portal.status === 0 ? (
                  <div className="empty-slot">Empty</div>
                ) : (
                  <>
                    <div className="portal-info">
                      <div className="info-item">
                        <span>Status:</span>
                        <span>{['Empty', 'Open', 'Questioned'][portal.status]}</span>
                      </div>
                      <div className="info-item">
                        <span>Hours to Collapse:</span>
                        <span>{String(portal.hoursToCollapse)}</span>
                      </div>
                      {portal.surveyPending && <div className="info-item">Survey: waiting for the word…</div>}
                      {portal.rescuerPending && <div className="info-item">Blind entry: waiting for the word…</div>}
                      {portal.observerInside && <div className="info-item">Observer inside</div>}
                      {portal.rescuerInside && <div className="info-item">Rescuer inside</div>}

                      {portal.surveyed ? (
                        <>
                          <div className="info-item">
                            <span>Energy:</span>
                            <span>{String(portal.energy)}</span>
                          </div>
                          <div className="info-item">
                            <span>Stability:</span>
                            <span>{String(portal.stability)}</span>
                          </div>
                          <div className="info-item">
                            <span>Creatures:</span>
                            <span>{String(portal.creatures)}</span>
                          </div>
                        </>
                      ) : (
                        <>
                          {portal.narrowedOnce && (
                            <div className="info-item">Narrowed — one more survey reads exact</div>
                          )}
                          <div className="info-item">
                            <span>Energy Range:</span>
                            <span>
                              [{String(portal.energyLo)}, {String(portal.energyHi)}]
                            </span>
                          </div>
                          <div className="info-item">
                            <span>Stability Range:</span>
                            <span>
                              [{String(portal.stabilityLo)}, {String(portal.stabilityHi)}]
                            </span>
                          </div>
                          <div className="info-item">
                            <span>Creatures Range:</span>
                            <span>
                              [{String(portal.creaturesLo)}, {String(portal.creaturesHi)}]
                            </span>
                          </div>
                        </>
                      )}
                    </div>

                    <div className="action-buttons">
                      <button onClick={() => performAction(idx, Action.ToggleQuestioned)} disabled={busy}>❓</button>
                      <button onClick={() => performAction(idx, Action.Stabilize)} disabled={busy}>⬆</button>
                      <button onClick={() => performAction(idx, Action.Destabilize)} disabled={busy}>⬇</button>
                      <button onClick={() => performAction(idx, Action.SendObserver)} disabled={busy}>👁</button>
                      <button onClick={() => performAction(idx, Action.RecallObserver)} disabled={busy}>🔙</button>
                      <button onClick={() => performAction(idx, Action.SendRescuer)} disabled={busy}>🚀</button>
                      <button onClick={() => performAction(idx, Action.RecallRescuer)} disabled={busy}>🔙</button>
                      <button onClick={() => performAction(idx, Action.Evacuate)} disabled={busy}>✈</button>
                      <button onClick={() => performAction(idx, Action.Close)} disabled={busy}>✖</button>
                    </div>
                  </>
                )}
              </div>
              );
            })}
          </div>
          )}

          {!game.finished && forecast && (
            <div className="forecast">
              <h3>Coming before the next random word (if you do nothing)</h3>
              {forecast.fallsAt !== null && (
                <p className="forecast-death">If nothing is done, the lab falls at hour {String(forecast.fallsAt)}</p>
              )}
              {forecast.spawns.length === 0 ? (
                <p>No new portals.</p>
              ) : (
                <ul>
                  {forecast.spawns.map((sp, i) => (
                    <li key={i}>
                      Hour {String(sp.atHour)} (in {String(sp.inSec > 0n ? sp.inSec : 0n)} s): {portalTypeNames[sp.portalType] ?? 'Unknown'} portal
                    </li>
                  ))}
                </ul>
              )}
              {forecast.edgeHour !== null && <p>The current random word covers up to hour {String(forecast.edgeHour)}.</p>}
              {forecast.boundAfterEdge !== null && (
                <p className="forecast-death">
                  Without a new random word after hour {String(forecast.edgeHour)}, the lab falls no later than hour{' '}
                  {String(forecast.boundAfterEdge)} (in{' '}
                  {String(secondsUntilHour(forecast.boundAfterEdge))} s).
                </p>
              )}
            </div>
          )}

          <Journal player={player} state={state} />

          <div className="game-controls">
            <button onClick={load}>Refresh</button>
            {projected.cappedShort && !game.finished && !state?.pending.active && (
              <button
                onClick={async () => {
                  if (!state) return;
                  const value = state.pending.active ? 0n : await readFee();
                  await send('Paid sync', 'sync', [player], value);
                }}
                disabled={!burner || busy}
              >
                Sync (pays for word)
              </button>
            )}
            {game.finished && !game.settled && (
              <button onClick={() => send('Settle game', 'settle', [player])} className="primary" disabled={!burner || busy}>
                Settle Game
              </button>
            )}
            <button
              onClick={async () => {
                if (game.finished) await send('New game', 'startGame', [], await readFee());
                else setConfirmNew(true);
              }}
              className="secondary"
              disabled={!burner || busy}
            >
              New Game
            </button>
          </div>
          {confirmNew && !game.finished && (
            <div className="warn-message">
              <p>
                This run is still alive. Starting a new game forfeits it WITHOUT recording it on the leaderboard.
              </p>
              {projected.cappedShort && (
                <p>
                  The world is paused at the edge of its random word, so the contract cannot tell yet whether this
                  lab has already fallen. Use "Sync (pays for word)" first: if the run ended while you were away, it
                  will be recorded.
                </p>
              )}
              <button
                onClick={async () => {
                  setConfirmNew(false);
                  await send('New game', 'startGame', [], await readFee());
                }}
                className="danger"
                disabled={busy}
              >
                Forfeit and start new
              </button>{' '}
              <button onClick={() => setConfirmNew(false)}>Keep playing</button>
            </div>
          )}
        </div>
      )}

      <Leaderboard account={burner?.address ?? null} refreshKey={leaderboardTick} />
    </div>
  );
}

async function resultMessage(
  done: Pending | null,
  s: ChainState,
  before: ChainState | null,
  player: Address,
  fromBlock: bigint | null,
  toBlock: bigint,
): Promise<string> {
  if (!done) return 'Random word received, state updated';
  if (done.syncOnly && before && before.game.hoursElapsed === 0n && before.game.openPortals === 0n && s.game.openPortals > 0n) {
    return `Lab ready: hour ${s.game.hoursElapsed}, ${s.game.openPortals} portals`;
  }
  if (done.syncOnly) return `Sync complete: world at hour ${s.game.hoursElapsed}`;
  const slot = Number(done.slot);
  const p = s.portals[slot];
  if (done.action === Action.SendObserver) {
    if (p.surveyed) {
      return `Survey of slot ${slot}: energy ${p.energy}, stability ${p.stability}, creatures ${p.creatures}`;
    }
    if (p.id === done.portalId && p.narrowedOnce) {
      return `Survey of slot ${slot} narrowed the ranges — one more survey reads exact`;
    }
    return `Survey of slot ${slot} cancelled (portal collapsed or game over)`;
  }
  if (done.action === Action.SendRescuer) {
    return p.creaturesKnown
      ? `Blind entry to slot ${slot}: creatures ${p.creatures}${p.rescuerInside ? ', rescuer inside' : ', rescuer left to recover'}`
      : `Blind entry to slot ${slot} cancelled`;
  }
  const label = `Action ${Action[done.action]} on slot ${slot}`;
  if (fromBlock === null) return 'Random word received, state updated';
  try {
    const out = await readDeferredOutcome(player, slot, done.action, fromBlock, toBlock);
    if (out.cancelledReason !== null) {
      return `${label} cancelled: ${getCancelReasonMessage(out.cancelledReason)}`;
    }
    if (out.performed) return `${label} applied after the word arrived`;
  } catch (error) {
    console.error('Outcome log query failed:', error);
  }
  return 'Random word received, state updated';
}

export default App;
