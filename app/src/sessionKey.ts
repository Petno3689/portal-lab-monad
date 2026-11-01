import { keccak256, type Address, type Hex } from 'viem';

/** The part of the Web Storage API used here; `null` when the browser denies storage. */
export type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;
type MaybeStorage = StorageLike | null;

// This text is frozen: changing any byte changes every player's game key.
export const SESSION_MESSAGE = [
  'Unstable Portals Lab - game key',
  'Signing this creates your game key for Monad testnet (chain 10143).',
  'Version: session-key-v1',
  'Sign only on https://portal-lab-monad.vercel.app - any site that gets this signature can play with your game key and spend its MON.',
].join('\n');

const sessionKeyKey = (owner: Address) => `portal-lab:session-key:${owner.toLowerCase()}`;
const burnerOfKey = (owner: Address) => `portal-lab:burner-of:${owner.toLowerCase()}`;
const gasMultiplierKey = (burner: Address) => `portal-lab:gas-multiplier-pct:${burner.toLowerCase()}`;

const GAS_PCT_MIN = 100;
const GAS_PCT_MAX = 200;
const GAS_PCT_DEFAULT = 120;

function read(storage: MaybeStorage, key: string): string | null {
  try {
    return storage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(storage: MaybeStorage, key: string, value: string) {
  try {
    storage?.setItem(key, value);
  } catch {
    // storage full or denied: the value lives for this page only
  }
}

function remove(storage: MaybeStorage, key: string) {
  try {
    storage?.removeItem(key);
  } catch {
    // storage denied: nothing was stored
  }
}

/** The burner's private key: the hash of the owner's signature over SESSION_MESSAGE. */
export function deriveSessionKey(signature: Hex): Hex {
  return keccak256(signature);
}

// The key itself: pass sessionStorage only, so that it dies with the tab.
export function loadSessionKey(storage: MaybeStorage, owner: Address): Hex | null {
  const key = read(storage, sessionKeyKey(owner));
  return key && /^0x[0-9a-fA-F]{64}$/.test(key) ? (key as Hex) : null;
}

export function saveSessionKey(storage: MaybeStorage, owner: Address, key: Hex) {
  write(storage, sessionKeyKey(owner), key);
}

export function clearSessionKey(storage: MaybeStorage, owner: Address) {
  remove(storage, sessionKeyKey(owner));
}

// The burner ADDRESS this browser saw for `owner`, never the key: it reveals a wallet
// whose signatures are not deterministic before funds go to an address it cannot recreate.
export function rememberedBurner(storage: MaybeStorage, owner: Address): string | null {
  return read(storage, burnerOfKey(owner));
}

export function rememberBurner(storage: MaybeStorage, owner: Address, burner: Address) {
  write(storage, burnerOfKey(owner), burner);
}

export function checkBurner(storage: MaybeStorage, owner: Address, burner: Address): 'new' | 'match' | 'mismatch' {
  const known = rememberedBurner(storage, owner);
  if (known === null) return 'new';
  return known.toLowerCase() === burner.toLowerCase() ? 'match' : 'mismatch';
}

const clampGasPct = (pct: number) => Math.min(GAS_PCT_MAX, Math.max(GAS_PCT_MIN, Math.round(pct)));

export function getGasMultiplierPct(storage: MaybeStorage, burner: Address): number {
  const raw = read(storage, gasMultiplierKey(burner));
  return raw !== null && /^\d+$/.test(raw) ? clampGasPct(Number(raw)) : GAS_PCT_DEFAULT;
}

export function setGasMultiplierPct(storage: MaybeStorage, burner: Address, pct: number) {
  write(storage, gasMultiplierKey(burner), String(Number.isFinite(pct) ? clampGasPct(pct) : GAS_PCT_DEFAULT));
}
