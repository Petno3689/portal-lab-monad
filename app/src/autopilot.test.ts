import { describe, expect, it } from 'vitest';
import {
  createBackoff,
  isExpectedRevert,
  shouldAutoBuyWord,
  shouldAutoSettle,
  type AutoBuyWordInput,
  type AutoSettleInput,
} from './autopilot';

const NOW = 1_000_000;

const buyable: AutoBuyWordInput = {
  enabled: true,
  hasBurner: true,
  busy: false,
  gameStarted: true,
  chainFinished: false,
  projectedFinished: false,
  pendingActive: false,
  projectedCapped: true,
  canPay: true,
  blockedUntil: NOW,
  now: NOW,
};

const settleable: AutoSettleInput = {
  enabled: true,
  hasBurner: true,
  busy: false,
  gameStarted: true,
  projectedFinished: true,
  settled: false,
  pendingActive: false,
  blockedUntil: NOW,
  now: NOW,
};

describe('shouldAutoBuyWord', () => {
  it('is true when every condition holds', () => {
    expect(shouldAutoBuyWord(buyable)).toBe(true);
  });

  it.each<[string, Partial<AutoBuyWordInput>]>([
    ['disabled', { enabled: false }],
    ['no burner', { hasBurner: false }],
    ['busy', { busy: true }],
    ['no game', { gameStarted: false }],
    ['finished on chain', { chainFinished: true }],
    ['finished by projection', { projectedFinished: true }],
    ['a word on its way', { pendingActive: true }],
    ['not at the edge', { projectedCapped: false }],
    ['cannot pay', { canPay: false }],
    ['blocked', { blockedUntil: NOW + 1 }],
    ['blocked for good', { blockedUntil: Infinity }],
  ])('is false when %s', (_name, change) => {
    expect(shouldAutoBuyWord({ ...buyable, ...change })).toBe(false);
  });
});

describe('shouldAutoSettle', () => {
  it('is true when every condition holds', () => {
    expect(shouldAutoSettle(settleable)).toBe(true);
  });

  it.each<[string, Partial<AutoSettleInput>]>([
    ['disabled', { enabled: false }],
    ['no burner', { hasBurner: false }],
    ['busy', { busy: true }],
    ['no game', { gameStarted: false }],
    ['the run is alive', { projectedFinished: false }],
    ['already recorded', { settled: true }],
    ['a word on its way', { pendingActive: true }],
    ['blocked', { blockedUntil: NOW + 1 }],
    ['blocked for good', { blockedUntil: Infinity }],
  ])('is false when %s', (_name, change) => {
    expect(shouldAutoSettle({ ...settleable, ...change })).toBe(false);
  });
});

describe('isExpectedRevert', () => {
  it('knows the reverts of a page behind the chain', () => {
    expect(isExpectedRevert('sync', 'ActionPending')).toBe(true);
    expect(isExpectedRevert('settle', 'GameNotFinished')).toBe(true);
    expect(isExpectedRevert('settle', 'AlreadySettled')).toBe(true);
  });

  it('counts everything else as a failure', () => {
    expect(isExpectedRevert('sync', 'GameNotFinished')).toBe(false);
    expect(isExpectedRevert('sync', 'InsufficientFee')).toBe(false);
    expect(isExpectedRevert('settle', 'ActionPending')).toBe(false);
    expect(isExpectedRevert('settle', undefined)).toBe(false);
  });
});

describe('createBackoff', () => {
  it('cools down for 30 s and stops after the third failure in a row by default', () => {
    const backoff = createBackoff();
    expect(backoff.failure(100)).toEqual({ blockedUntil: 30_100, stopped: false });
    expect(backoff.failure(200)).toEqual({ blockedUntil: 30_200, stopped: false });
    expect(backoff.failure(300)).toEqual({ blockedUntil: 30_300, stopped: true });
  });

  it('honours its options', () => {
    const backoff = createBackoff({ cooldownMs: 5, maxFailures: 1 });
    expect(backoff.failure(10)).toEqual({ blockedUntil: 15, stopped: true });
  });

  it('counts only consecutive failures', () => {
    const backoff = createBackoff();
    backoff.failure(0);
    backoff.failure(0);
    backoff.success();
    expect(backoff.failure(0).stopped).toBe(false);
    expect(backoff.failure(0).stopped).toBe(false);
    expect(backoff.failure(0).stopped).toBe(true);
  });

  it('stays stopped through a success, until reset', () => {
    const backoff = createBackoff({ maxFailures: 2 });
    backoff.failure(0);
    backoff.failure(0);
    backoff.success();
    expect(backoff.failure(0).stopped).toBe(true);
    backoff.reset();
    expect(backoff.failure(0).stopped).toBe(false);
  });
});
