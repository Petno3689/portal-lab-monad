import { describe, expect, it } from 'vitest';
import { displayName, shortAddress, validateName } from './names';

const LENGTH = '3 to 20 characters';
const CHARSET = 'Only Latin letters, digits, _ and -';

describe('validateName', () => {
  it('enforces the length bounds', () => {
    expect(validateName('ab')).toEqual({ ok: false, reason: LENGTH });
    expect(validateName('abc')).toEqual({ ok: true, name: 'abc' });
    expect(validateName('a'.repeat(20))).toEqual({ ok: true, name: 'a'.repeat(20) });
    expect(validateName('a'.repeat(21))).toEqual({ ok: false, reason: LENGTH });
  });

  it('accepts every allowed class', () => {
    expect(validateName('abcxyz').ok).toBe(true);
    expect(validateName('ABCXYZ').ok).toBe(true);
    expect(validateName('012789').ok).toBe(true);
    expect(validateName('a_b').ok).toBe(true);
    expect(validateName('a-b').ok).toBe(true);
  });

  it('rejects other characters', () => {
    for (const bad of ['ab cd', 'ab.cd', 'ab@cd', 'привет', 'ab😀cd']) {
      expect(validateName(bad)).toEqual({ ok: false, reason: CHARSET });
    }
  });

  it('measures length in bytes', () => {
    // 2 Cyrillic characters = 4 bytes: in bounds, so the charset is what fails.
    expect(validateName('пр')).toEqual({ ok: false, reason: CHARSET });
    // 12 Cyrillic characters = 24 bytes: out of bounds.
    expect(validateName('приветпривет')).toEqual({ ok: false, reason: LENGTH });
  });

  it('rejects empty input', () => {
    expect(validateName('')).toEqual({ ok: false, reason: LENGTH });
    expect(validateName('   ')).toEqual({ ok: false, reason: LENGTH });
  });

  it('trims surrounding spaces', () => {
    expect(validateName('  abc  ')).toEqual({ ok: true, name: 'abc' });
    expect(validateName(' ab ')).toEqual({ ok: false, reason: LENGTH });
  });
});

describe('display', () => {
  const address = '0x0540000000000000000000000000000000CcA6'.padEnd(42, '0').slice(0, 38) + 'CcA6';
  it('shortens an address', () => {
    expect(shortAddress(address)).toBe(`${address.slice(0, 6)}…CcA6`);
  });
  it('joins name and address, or shows the address alone', () => {
    expect(displayName('neo', address)).toBe(`neo · ${shortAddress(address)}`);
    expect(displayName('', address)).toBe(shortAddress(address));
  });
});
