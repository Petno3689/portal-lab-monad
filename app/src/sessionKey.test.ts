import { describe, expect, it } from 'vitest';
import { keccak256, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import {
  SESSION_MESSAGE,
  checkBurner,
  clearSessionKey,
  deriveSessionKey,
  getGasMultiplierPct,
  loadSessionKey,
  rememberBurner,
  rememberedBurner,
  saveSessionKey,
  setGasMultiplierPct,
  type StorageLike,
} from './sessionKey';

function memoryStorage(): StorageLike & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return {
    map,
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    removeItem: (key) => void map.delete(key),
  };
}

const deniedStorage: StorageLike = {
  getItem: () => {
    throw new Error('denied');
  },
  setItem: () => {
    throw new Error('denied');
  },
  removeItem: () => {
    throw new Error('denied');
  },
};

const OWNER = '0xAbCdEf0123456789aBcDeF0123456789AbCdEf01' as Address;
const BURNER_A = '0x1111111111111111111111111111111111111111' as Address;
const BURNER_B = '0x2222222222222222222222222222222222222222' as Address;
const SIGNATURE_A = `0x${'ab'.repeat(65)}` as Hex;
const SIGNATURE_B = `0x${'cd'.repeat(65)}` as Hex;
const KEY = `0x${'11'.repeat(32)}` as Hex;

describe('deriveSessionKey', () => {
  it('gives the same key and address for the same signature', () => {
    const first = deriveSessionKey(SIGNATURE_A);
    const second = deriveSessionKey(SIGNATURE_A);
    expect(first).toBe(second);
    expect(first).toBe(keccak256(SIGNATURE_A));
    expect(privateKeyToAccount(first).address).toBe(privateKeyToAccount(second).address);
  });

  it('gives a different address for a different signature', () => {
    const a = privateKeyToAccount(deriveSessionKey(SIGNATURE_A));
    const b = privateKeyToAccount(deriveSessionKey(SIGNATURE_B));
    expect(a.address).not.toBe(b.address);
  });
});

describe('SESSION_MESSAGE', () => {
  it('equals the frozen four lines byte for byte', () => {
    const expected =
      'Unstable Portals Lab - game key\n' +
      'Signing this creates your game key for Monad testnet (chain 10143).\n' +
      'Version: session-key-v1\n' +
      'Sign only on https://portal-lab-monad.vercel.app - any site that gets this signature can play with your game key and spend its MON.';
    expect(SESSION_MESSAGE).toBe(expected);
    expect(new TextEncoder().encode(SESSION_MESSAGE)).toEqual(new TextEncoder().encode(expected));
    expect(SESSION_MESSAGE.split('\n')).toHaveLength(4);
    expect(SESSION_MESSAGE.endsWith('\n')).toBe(false);
    expect([...SESSION_MESSAGE].every((c) => c.charCodeAt(0) < 128)).toBe(true);
  });
});

describe('session key storage', () => {
  it('round-trips and clears, keyed by the lowercase owner', () => {
    const storage = memoryStorage();
    expect(loadSessionKey(storage, OWNER)).toBeNull();
    saveSessionKey(storage, OWNER, KEY);
    expect(loadSessionKey(storage, OWNER)).toBe(KEY);
    expect([...storage.map.keys()]).toEqual([`portal-lab:session-key:${OWNER.toLowerCase()}`]);
    clearSessionKey(storage, OWNER);
    expect(loadSessionKey(storage, OWNER)).toBeNull();
    expect(storage.map.size).toBe(0);
  });

  it('ignores a stored value that is not a private key', () => {
    const storage = memoryStorage();
    storage.map.set(`portal-lab:session-key:${OWNER.toLowerCase()}`, '0x1234');
    expect(loadSessionKey(storage, OWNER)).toBeNull();
  });

  it('survives storage that throws or is missing', () => {
    expect(() => saveSessionKey(deniedStorage, OWNER, KEY)).not.toThrow();
    expect(() => clearSessionKey(deniedStorage, OWNER)).not.toThrow();
    expect(loadSessionKey(deniedStorage, OWNER)).toBeNull();
    expect(loadSessionKey(null, OWNER)).toBeNull();
  });
});

describe('checkBurner', () => {
  it('reports new, match and mismatch', () => {
    const storage = memoryStorage();
    expect(checkBurner(storage, OWNER, BURNER_A)).toBe('new');
    rememberBurner(storage, OWNER, BURNER_A);
    expect(checkBurner(storage, OWNER, BURNER_A)).toBe('match');
    expect(checkBurner(storage, OWNER, BURNER_B)).toBe('mismatch');
  });

  it('compares addresses without regard to case', () => {
    const storage = memoryStorage();
    const mixed = '0xAAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa' as Address;
    rememberBurner(storage, OWNER, mixed);
    expect(checkBurner(storage, OWNER, mixed.toLowerCase() as Address)).toBe('match');
  });

  it('overwrites the record on rememberBurner and stores only the address', () => {
    const storage = memoryStorage();
    rememberBurner(storage, OWNER, BURNER_A);
    rememberBurner(storage, OWNER, BURNER_B);
    expect(rememberedBurner(storage, OWNER)).toBe(BURNER_B);
    expect(checkBurner(storage, OWNER, BURNER_B)).toBe('match');
    expect([...storage.map.entries()]).toEqual([[`portal-lab:burner-of:${OWNER.toLowerCase()}`, BURNER_B]]);
  });
});

describe('gas multiplier', () => {
  it('defaults to 120', () => {
    expect(getGasMultiplierPct(memoryStorage(), BURNER_A)).toBe(120);
    expect(getGasMultiplierPct(null, BURNER_A)).toBe(120);
  });

  it('persists per burner', () => {
    const storage = memoryStorage();
    setGasMultiplierPct(storage, BURNER_A, 150);
    expect(getGasMultiplierPct(storage, BURNER_A)).toBe(150);
    expect(getGasMultiplierPct(storage, BURNER_B)).toBe(120);
    expect(storage.map.get(`portal-lab:gas-multiplier-pct:${BURNER_A.toLowerCase()}`)).toBe('150');
  });

  it('clamps to [100, 200] on write and on read', () => {
    const storage = memoryStorage();
    setGasMultiplierPct(storage, BURNER_A, 50);
    expect(getGasMultiplierPct(storage, BURNER_A)).toBe(100);
    setGasMultiplierPct(storage, BURNER_A, 500);
    expect(getGasMultiplierPct(storage, BURNER_A)).toBe(200);
    storage.map.set(`portal-lab:gas-multiplier-pct:${BURNER_A.toLowerCase()}`, '999');
    expect(getGasMultiplierPct(storage, BURNER_A)).toBe(200);
  });

  it('keeps integers and falls back on garbage', () => {
    const storage = memoryStorage();
    setGasMultiplierPct(storage, BURNER_A, 133.6);
    expect(storage.map.get(`portal-lab:gas-multiplier-pct:${BURNER_A.toLowerCase()}`)).toBe('134');
    setGasMultiplierPct(storage, BURNER_A, Number.NaN);
    expect(getGasMultiplierPct(storage, BURNER_A)).toBe(120);
    storage.map.set(`portal-lab:gas-multiplier-pct:${BURNER_A.toLowerCase()}`, 'lots');
    expect(getGasMultiplierPct(storage, BURNER_A)).toBe(120);
  });
});
