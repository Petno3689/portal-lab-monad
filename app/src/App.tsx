import { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import { formatEther, isAddress, type Address } from 'viem';
import { MONAD_CHAIN_ID, MONAD_RPC_URL } from './config';
import { publicClient, readPlayer, readPending, readFee, readCanAct, readBestRun, readDeferredOutcome, blockOf, sendTx, revertOf, type ChainState } from './contract';
import { preview } from '@shared/preview';
import { catchUp } from '@shared/time';
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

const PENDING_POLL_MS = 3000;

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

const nowSec = () => BigInt(Math.floor(Date.now() / 1000));

/** Refusals are warnings; failed transactions and anything unexpected are errors. */
function describeError(error: unknown): TransactionStatus {
  const r = revertOf(error);
  const fail = (text: string): TransactionStatus => ({ pending: false, message: '', error: text });
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
  const [account, setAccount] = useState<Address | null>(null);
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

  const player = account ?? urlPlayer;

  useEffect(() => {
    if (!window.ethereum) return;
    if (!disconnected.current) {
      window.ethereum.request({ method: 'eth_accounts' }).then((a: string[]) => a[0] && setAccount(a[0] as Address));
    }
    window.ethereum.request({ method: 'eth_chainId' }).then((id: string) => setChain(parseInt(id, 16)));
    window.ethereum.on?.('accountsChanged', (a: string[]) => {
      if (disconnected.current) return;
      setAccount((a[0] as Address) ?? null);
    });
    window.ethereum.on?.('chainChanged', (id: string) => setChain(parseInt(id, 16)));
  }, []);

  const connectWallet = async () => {
    if (!window.ethereum) {
      setTxStatus({ pending: false, message: '', error: 'MetaMask not found' });
      return;
    }
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    disconnected.current = false;
    writeDisconnected(false);
    setAccount(accounts[0]);
    const id = await window.ethereum.request({ method: 'eth_chainId' });
    setChain(parseInt(id as string, 16));
  };

  const disconnectWallet = async () => {
    try {
      await window.ethereum?.request({ method: 'wallet_revokePermissions', params: [{ eth_accounts: {} }] });
    } catch {
      // not every wallet supports revoking permissions
    }
    disconnected.current = true;
    writeDisconnected(true);
    setAccount(null);
    setState(null);
    setBestRun(null);
    setConfirmNew(false);
    setTxStatus({ pending: false, message: '' });
    awaited.current = null;
    awaitedBlock.current = null;
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
      setState(await readPlayer(player));
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
    const id = setInterval(async () => {
      const epoch = cancelEpoch.current;
      const cancelled = () => cancelling.current || cancelEpoch.current !== epoch;
      try {
        const p = await readPending(player);
        if (p.active || cancelled()) return;
        // The outcome events are at or before this block.
        const seenAt = await publicClient.getBlockNumber();
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
    return () => clearInterval(id);
  }, [pendingActive, player]);

  const send = async (
    label: string,
    fn: 'startGame' | 'act' | 'sync' | 'settle' | 'cancelDeferred',
    args: readonly unknown[],
    value = 0n,
    doneMessage?: string,
  ) => {
    if (!account) return;
    setConfirmNew(false);
    setTxStatus({ pending: true, message: label });
    try {
      if (chain !== MONAD_CHAIN_ID) await switchToMonad();
      const hash = await sendTx(account, fn, args, value);
      const fresh = await readPlayer(account);
      setState(fresh);
      setNow(nowSec());
      if (fn === 'settle' || fn === 'startGame') refreshBestRun(account);
      if (fresh.pending.active) {
        awaited.current = fresh.pending;
        awaitedBlock.current = await blockOf(hash).catch(() => null);
        setTxStatus({ pending: true, message: `${label}: waiting for the random word from Pyth (tx ${hash.slice(0, 10)}…)` });
      } else {
        setTxStatus({ pending: false, message: doneMessage ?? `${label}: done (tx ${hash.slice(0, 10)}…)` });
      }
    } catch (error) {
      console.error(error);
      setTxStatus(describeError(error));
    }
  };

  const performAction = async (slot: number, action: Action) => {
    if (!account || !state) return;
    if (state.pending.active) {
      setTxStatus({ pending: true, message: 'Previous action is still waiting for the random word' });
      return;
    }
    const refusal = await readCanAct(account, slot, action);
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

  const cancelRequest = async () => {
    if (!player) return;
    cancelling.current = true;
    cancelEpoch.current += 1;
    awaited.current = null;
    awaitedBlock.current = null;
    try {
      await send('Cancel request', 'cancelDeferred', [player], 0n, 'Request cancelled');
    } finally {
      cancelling.current = false;
      cancelEpoch.current += 1;
    }
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
      return { spawns, edgeHour: lastHour, fallsAt };
    } catch (error) {
      console.error('Forecast failed:', error);
      return null;
    }
  }, [state, projected, now]);

  return (
    <div className="app">
      <header className="header">
        <h1>Unstable Portals Lab</h1>
        <div className="wallet-section">
          {!account ? (
            <button onClick={connectWallet} className="primary">
              Connect Wallet
            </button>
          ) : (
            <>
              <span className="address">{account.slice(0, 6)}...{account.slice(-4)}</span>
              <button onClick={disconnectWallet}>Disconnect</button>
              {chain !== MONAD_CHAIN_ID && (
                <button onClick={switchToMonad} className="danger">
                  Switch to Monad Testnet
                </button>
              )}
            </>
          )}
          {!account && urlPlayer && <span className="address">View only: {urlPlayer.slice(0, 6)}...{urlPlayer.slice(-4)}</span>}
        </div>
      </header>

      {txStatus.error && <div className="error-message">{txStatus.error}</div>}
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
                <button onClick={cancelRequest} disabled={!account}>
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
          <p>Connect your wallet (or open the page with ?player=0x…)</p>
        </div>
      ) : loading && !state ? (
        <div className="loading">Loading game state...</div>
      ) : !hasGame || !projected || !game ? (
        <div className="no-game">
          <p>No active game. Start a new one!</p>
          <button onClick={async () => send('New game', 'startGame', [], await readFee())} className="primary" disabled={!account}>
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
                      <button onClick={() => performAction(idx, Action.ToggleQuestioned)}>❓</button>
                      <button onClick={() => performAction(idx, Action.Stabilize)}>⬆</button>
                      <button onClick={() => performAction(idx, Action.Destabilize)}>⬇</button>
                      <button onClick={() => performAction(idx, Action.SendObserver)}>👁</button>
                      <button onClick={() => performAction(idx, Action.RecallObserver)}>🔙</button>
                      <button onClick={() => performAction(idx, Action.SendRescuer)}>🚀</button>
                      <button onClick={() => performAction(idx, Action.RecallRescuer)}>🔙</button>
                      <button onClick={() => performAction(idx, Action.Evacuate)}>✈</button>
                      <button onClick={() => performAction(idx, Action.Close)}>✖</button>
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
                disabled={!account}
              >
                Sync (pays for word)
              </button>
            )}
            {game.finished && !game.settled && (
              <button onClick={() => send('Settle game', 'settle', [player])} className="primary" disabled={!account}>
                Settle Game
              </button>
            )}
            <button
              onClick={async () => {
                if (game.finished) await send('New game', 'startGame', [], await readFee());
                else setConfirmNew(true);
              }}
              className="secondary"
              disabled={!account}
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
              >
                Forfeit and start new
              </button>{' '}
              <button onClick={() => setConfirmNew(false)}>Keep playing</button>
            </div>
          )}
        </div>
      )}

      <Leaderboard account={account} refreshKey={leaderboardTick} />
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
