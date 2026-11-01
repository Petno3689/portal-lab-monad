import { describe, expect, it } from 'vitest';
import { WORD_GAS, TRANSFER_GAS, canPayWord, parseTopUp, withdrawAmount, wordCost } from './funds';

describe('wordCost', () => {
  it('adds the fee and the gas budget at the gas price', () => {
    expect(wordCost(1000n, 2n)).toBe(1000n + WORD_GAS * 2n);
  });
  it('is the fee alone at a zero gas price', () => {
    expect(wordCost(1000n, 0n)).toBe(1000n);
  });
});

describe('canPayWord', () => {
  const cost = wordCost(1000n, 2n);
  it('accepts a balance exactly equal to the cost', () => {
    expect(canPayWord(cost, 1000n, 2n)).toBe(true);
  });
  it('rejects a balance one wei short', () => {
    expect(canPayWord(cost - 1n, 1000n, 2n)).toBe(false);
  });
  it('accepts more than enough and rejects zero', () => {
    expect(canPayWord(cost + 1n, 1000n, 2n)).toBe(true);
    expect(canPayWord(0n, 1000n, 2n)).toBe(false);
  });
});

describe('withdrawAmount', () => {
  const reserve = TRANSFER_GAS * 5n;
  it('leaves exactly the transfer gas behind', () => {
    expect(withdrawAmount(reserve + 100n, 5n)).toBe(100n);
  });
  it('is zero when the balance only covers the transfer gas', () => {
    expect(withdrawAmount(reserve, 5n)).toBe(0n);
  });
  it('is zero, not negative, when the balance is below the transfer gas', () => {
    expect(withdrawAmount(reserve - 1n, 5n)).toBe(0n);
    expect(withdrawAmount(0n, 5n)).toBe(0n);
  });
  it('is the whole balance at a zero fee', () => {
    expect(withdrawAmount(77n, 0n)).toBe(77n);
  });
});

describe('parseTopUp', () => {
  it('converts decimal MON to wei', () => {
    expect(parseTopUp('3')).toBe(3n * 10n ** 18n);
    expect(parseTopUp('0.5')).toBe(5n * 10n ** 17n);
    expect(parseTopUp(' 1.25 ')).toBe(125n * 10n ** 16n);
    expect(parseTopUp('.5')).toBe(5n * 10n ** 17n);
  });
  it('accepts exactly 18 decimals and the smallest amount', () => {
    expect(parseTopUp('0.000000000000000001')).toBe(1n);
  });
  it('rejects more than 18 decimals', () => {
    expect(parseTopUp('0.0000000000000000001')).toBeNull();
  });
  it('rejects empty and non-numeric input', () => {
    for (const bad of ['', '   ', 'abc', '1e3', '1,5', '0x10', '1.2.3', '.', '1 2']) {
      expect(parseTopUp(bad), bad).toBeNull();
    }
  });
  it('rejects zero and negative amounts', () => {
    for (const bad of ['0', '0.0', '-1', '-0.5']) expect(parseTopUp(bad), bad).toBeNull();
  });
});
