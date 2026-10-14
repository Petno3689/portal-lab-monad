import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  encodeAbiParameters,
  hexToBigInt,
  http,
  keccak256,
  BaseError,
  ContractFunctionRevertedError,
  type Abi,
  type Address,
} from 'viem';
import { MONAD_RPC_URL, MONAD_CHAIN_ID, PORTAL_LAB_ADDRESS } from './config';
import type { Portal, Game, Config, PortalTypeParams, Pending, BestRun } from '@shared/types';
import ABI_JSON from './PortalLab.abi.json';

export const portalLabAbi = (ABI_JSON as { abi: Abi }).abi;

const randomSourceAbi = [
  { type: 'function', name: 'fee', inputs: [], outputs: [{ name: '', type: 'uint256' }], stateMutability: 'view' },
] as const satisfies Abi;

export const monadTestnet = defineChain({
  id: MONAD_CHAIN_ID,
  name: 'Monad Testnet',
  nativeCurrency: { decimals: 18, name: 'MON', symbol: 'MON' },
  rpcUrls: { default: { http: [MONAD_RPC_URL] } },
});

export const publicClient = createPublicClient({ chain: monadTestnet, transport: http(MONAD_RPC_URL, { retryCount: 5, retryDelay: 400 }),
});

const lab = { address: PORTAL_LAB_ADDRESS as Address, abi: portalLabAbi } as const;

// viem decodes uint8..uint48 as `number` and wider ints as `bigint`; the shared
// mirror wants every numeric field as `bigint`, but enum fields as plain numbers.
const ENUM_FIELDS = new Set(['portalType', 'status', 'action']);
function toMirror<T>(raw: unknown): T {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    out[k] = typeof v === 'number' && !ENUM_FIELDS.has(k) ? BigInt(v) : v;
  }
  return out as T;
}

// Slot of `_players` in PortalLab's storage (forge inspect PortalLab storageLayout)
// and the offset of `epochWord` inside `Player` (Game 2 + Portal[12] 12 + Pending 1).
// The contract has no getter for it, yet the mirror needs it to place spawns.
const PLAYERS_SLOT = 8n;
const EPOCH_WORD_OFFSET = 15n;

async function readEpochWord(player: Address, blockNumber?: bigint): Promise<bigint> {
  const base = hexToBigInt(
    keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [player, PLAYERS_SLOT])),
  );
  const raw = await publicClient.getStorageAt({
    address: lab.address,
    slot: `0x${(base + EPOCH_WORD_OFFSET).toString(16).padStart(64, '0')}`,
    blockNumber,
  });
  return raw ? hexToBigInt(raw) : 0n;
}

export interface ChainState {
  game: Game;
  portals: Portal[];
  pending: Pending;
  epochWord: bigint;
  config: Config;
  types: PortalTypeParams[];
}

// Config and type params are fixed at deploy (CLAUDE.md), so read them once.
// The public RPC allows ~15 requests/s; re-reading six immutable values on every
// refresh is what tipped the page over that limit.
let paramsOnce: Promise<{ config: Config; types: PortalTypeParams[] }> | null = null;
function readParams() {
  paramsOnce ??= Promise.all([
    publicClient.readContract({ ...lab, functionName: 'config' }),
    ...[0, 1, 2, 3, 4].map((t) => publicClient.readContract({ ...lab, functionName: 'portalTypeParams', args: [t] })),
  ]).then(([config, ...types]) => ({
    config: toMirror<Config>(config),
    types: types.map((t) => toMirror<PortalTypeParams>(t)),
  }));
  paramsOnce.catch(() => (paramsOnce = null));
  return paramsOnce;
}

/** Everything the page and the mirror need about `player`, read at one block. */
export async function readPlayer(player: Address, blockNumber?: bigint): Promise<ChainState> {
  const at = blockNumber === undefined ? {} : { blockNumber };
  const [game, portals, pending, epochWord, params] = await Promise.all([
    publicClient.readContract({ ...lab, functionName: 'getGame', args: [player], ...at }),
    publicClient.readContract({ ...lab, functionName: 'getPortals', args: [player], ...at }),
    publicClient.readContract({ ...lab, functionName: 'getPending', args: [player], ...at }),
    readEpochWord(player, blockNumber),
    readParams(),
  ]);
  return {
    game: toMirror<Game>(game),
    portals: (portals as unknown[]).map((p) => toMirror<Portal>(p)),
    pending: toMirror<Pending>(pending),
    epochWord,
    ...params,
  };
}

export async function readPending(player: Address): Promise<Pending> {
  const raw = await publicClient.readContract({ ...lab, functionName: 'getPending', args: [player] });
  return toMirror<Pending>(raw);
}

export async function readBestRun(player: Address): Promise<BestRun> {
  const raw = await publicClient.readContract({ ...lab, functionName: 'bestRun', args: [player] });
  return toMirror<BestRun>(raw);
}

/** The fee for one random word: `randomSource()` on PortalLab, then `fee()` there. */
export async function readFee(): Promise<bigint> {
  const source = (await publicClient.readContract({ ...lab, functionName: 'randomSource' })) as Address;
  return publicClient.readContract({ address: source, abi: randomSourceAbi, functionName: 'fee' });
}

export async function readCanAct(player: Address, slot: number, action: number): Promise<number> {
  return Number(await publicClient.readContract({ ...lab, functionName: 'canAct', args: [player, slot, action] }));
}

function walletClient(account: Address) {
  return createWalletClient({ account, chain: monadTestnet, transport: custom(window.ethereum) });
}

/** Send a PortalLab transaction from `account` and wait for its receipt. */
export async function sendTx(
  account: Address,
  functionName: 'startGame' | 'act' | 'sync' | 'settle' | 'cancelDeferred',
  args: readonly unknown[],
  value = 0n,
): Promise<`0x${string}`> {
  const wallet = walletClient(account);
  // Simulate first so a revert surfaces with the contract's own error, not a wallet popup.
  const { request } = await publicClient.simulateContract({
    ...lab,
    account,
    functionName,
    args: args as never,
    value,
  } as never);
  // The contract ages the world lazily, so the work an action does grows with the time
  // between this estimate and inclusion in a block; the bare estimate runs out of gas.
  // Trade-off: Monad charges by the DECLARED gas limit, not the amount used, so this
  // headroom is paid on every action. 60% covers a few extra game hours of catch-up;
  // it balances wasted fee against lost transactions, it is not a free margin.
  const gas = await publicClient.estimateContractGas({
    ...lab,
    account,
    functionName,
    args: args as never,
    value,
  } as never);
  const hash = await wallet.writeContract({ ...(request as object), gas: (gas * 160n) / 100n } as never);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`Transaction ${hash} reverted`);
  return hash;
}

/** The custom error a call reverted with, if any: `{ name, args }`. */
export function revertOf(error: unknown): { name: string; args: readonly unknown[] } | null {
  if (!(error instanceof BaseError)) return null;
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  if (reverted instanceof ContractFunctionRevertedError && reverted.data) {
    return { name: reverted.data.errorName, args: reverted.data.args ?? [] };
  }
  return null;
}

export async function blockOf(hash: `0x${string}`): Promise<bigint> {
  return (await publicClient.getTransactionReceipt({ hash })).blockNumber;
}

/** What the contract emitted for this player's deferred action in `slot`, from `fromBlock` to the latest block. */
export async function readDeferredOutcome(
  player: Address,
  slot: number,
  action: number,
  fromBlock: bigint,
): Promise<{ cancelledReason: number | null; performed: boolean }> {
  const range = { fromBlock, toBlock: 'latest' as const, args: { player } };
  const [cancels, performs] = await Promise.all([
    publicClient.getContractEvents({ ...lab, eventName: 'DeferredActionCancelled', ...range }),
    publicClient.getContractEvents({ ...lab, eventName: 'ActionPerformed', ...range }),
  ]);
  const match = (l: { args: unknown }) => {
    const a = l.args as { slot?: number; action?: number };
    return Number(a.slot) === slot && Number(a.action) === action;
  };
  const cancel = cancels.filter(match).at(-1);
  if (cancel) return { cancelledReason: Number((cancel.args as { reason: number }).reason), performed: false };
  return { cancelledReason: null, performed: performs.some(match) };
}
