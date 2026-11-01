import { parseEther } from 'viem';

/** Gas budget of one action that buys a random word; above the measured 540k limit. */
export const WORD_GAS = 600_000n;
/** Gas of a plain value transfer. */
export const TRANSFER_GAS = 21_000n;

/** What the next random word costs: the Pyth fee plus the gas limit of the action that carries it. */
export function wordCost(fee: bigint, gasPrice: bigint): bigint {
  return fee + WORD_GAS * gasPrice;
}

export function canPayWord(balance: bigint, fee: bigint, gasPrice: bigint): boolean {
  return balance >= wordCost(fee, gasPrice);
}

/** Everything the burner can send away once it has paid for the transfer itself. */
export function withdrawAmount(balance: bigint, maxFeePerGas: bigint): bigint {
  const amount = balance - TRANSFER_GAS * maxFeePerGas;
  return amount > 0n ? amount : 0n;
}

/** A decimal MON amount in wei, or null when the text is not a positive amount with at most 18 decimals. */
export function parseTopUp(input: string): bigint | null {
  const text = input.trim();
  if (!/^\d*\.?\d+$|^\d+\.$/.test(text)) return null;
  const [, fraction = ''] = text.split('.');
  if (fraction.length > 18) return null;
  try {
    const wei = parseEther(text);
    return wei > 0n ? wei : null;
  } catch {
    return null;
  }
}
