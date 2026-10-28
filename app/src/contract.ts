import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  encodeAbiParameters,
  hexToBigInt,
  http,
  keccak256,
  pad,
  parseEventLogs,
  toHex,
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

/** One PortalLab event decoded from a log. */
export interface LabEvent {
  eventName: string;
  args: Record<string, unknown>;
  blockNumber: bigint;
  logIndex: number;
}

// The public RPC accepts eth_getLogs over 101 blocks and answers 413 to 1000.
const LOG_CHUNK = 100n;

async function readChunk(player: Address, from: bigint, to: bigint): Promise<LabEvent[]> {
  const raw = (await publicClient.request({
    method: 'eth_getLogs',
    params: [
      {
        address: lab.address,
        // Every PortalLab event has `address indexed player` first: topic1.
        topics: [null, pad(player, { size: 32 })],
        fromBlock: toHex(from),
        toBlock: toHex(to),
      },
    ],
  })) as { blockNumber: string; logIndex: string }[];
  const logs = raw.map((l) => ({ ...l, blockNumber: BigInt(l.blockNumber), logIndex: Number(l.logIndex) }));
  const parsed = parseEventLogs({ abi: portalLabAbi, logs: logs as never }) as unknown as {
    eventName: string;
    args?: Record<string, unknown>;
    blockNumber: bigint;
    logIndex: number;
  }[];
  return parsed
    .map((l) => ({ eventName: l.eventName, args: l.args ?? {}, blockNumber: l.blockNumber, logIndex: l.logIndex }))
    .sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1));
}

/**
 * Every PortalLab event of `player` in [fromBlock, toBlock] (inclusive), read in chunks of
 * at most 100 blocks, one after another, in emission order.
 */
export async function readPlayerEvents(player: Address, fromBlock: bigint, toBlock: bigint): Promise<LabEvent[]> {
  const out: LabEvent[] = [];
  for (let from = fromBlock; from <= toBlock; from += LOG_CHUNK) {
    const to = from + LOG_CHUNK - 1n < toBlock ? from + LOG_CHUNK - 1n : toBlock;
    out.push(...(await readChunk(player, from, to)));
  }
  return out;
}

/**
 * Scan [lowBlock, highBlock] backward in 100-block chunks, newest first, at most
 * `maxChunks`. The scan ends after the first chunk for which `stop` returns true.
 * Returns the events of the chunks read (emission order) and whether `stop` fired.
 */
export async function scanPlayerEventsBackward(
  player: Address,
  lowBlock: bigint,
  highBlock: bigint,
  maxChunks: number,
  stop: (chunk: LabEvent[]) => boolean,
): Promise<{ events: LabEvent[]; stopped: boolean }> {
  const chunks: LabEvent[][] = [];
  let stopped = false;
  let to = highBlock;
  for (let n = 0; n < maxChunks && to >= lowBlock; n++) {
    const from = to - LOG_CHUNK + 1n > lowBlock ? to - LOG_CHUNK + 1n : lowBlock;
    const chunk = await readChunk(player, from, to);
    chunks.unshift(chunk);
    if (stop(chunk)) {
      stopped = true;
      break;
    }
    to = from - 1n;
  }
  return { events: chunks.flat(), stopped };
}

const DEFERRED_SCAN_CAP = 50;

/**
 * What the contract emitted for this player's deferred action in `slot`: scans backward
 * from `toBlock` (where the poll saw the pending action clear) to `fromBlock` (the
 * committing block), stops at the first chunk holding the outcome, gives up after 50 chunks.
 */
export async function readDeferredOutcome(
  player: Address,
  slot: number,
  action: number,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<{ cancelledReason: number | null; performed: boolean }> {
  const match = (e: LabEvent) => Number(e.args.slot) === slot && Number(e.args.action) === action;
  const cancelsIn = (c: LabEvent[]) => c.filter((e) => e.eventName === 'DeferredActionCancelled' && match(e));
  const performsIn = (c: LabEvent[]) => c.filter((e) => e.eventName === 'ActionPerformed' && match(e));
  let found: LabEvent[] = [];
  await scanPlayerEventsBackward(player, fromBlock, toBlock, DEFERRED_SCAN_CAP, (chunk) => {
    const hit = cancelsIn(chunk).length > 0 || performsIn(chunk).length > 0;
    if (hit) found = chunk;
    return hit;
  });
  const cancel = cancelsIn(found).at(-1);
  if (cancel) return { cancelledReason: Number(cancel.args.reason), performed: false };
  return { cancelledReason: null, performed: performsIn(found).length > 0 };
}

export interface LeaderboardRow {
  player: Address;
  run: BestRun;
}

const LEADERBOARD_PAGE = 100n;

/** The whole on-chain leaderboard in insertion order; pages are read one after another. */
export async function readLeaderboard(): Promise<LeaderboardRow[]> {
  const size = (await publicClient.readContract({ ...lab, functionName: 'leaderboardSize' })) as bigint;
  const rows: LeaderboardRow[] = [];
  for (let offset = 0n; offset < size; offset += LEADERBOARD_PAGE) {
    const [players, runs] = (await publicClient.readContract({
      ...lab,
      functionName: 'leaderboardPage',
      args: [offset, LEADERBOARD_PAGE],
    })) as unknown as [readonly Address[], readonly unknown[]];
    players.forEach((player, i) => rows.push({ player, run: toMirror<BestRun>(runs[i]) }));
  }
  return rows;
}
