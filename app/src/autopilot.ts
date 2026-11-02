export interface AutoBuyWordInput {
  enabled: boolean;
  hasBurner: boolean;
  busy: boolean;
  gameStarted: boolean;
  chainFinished: boolean;
  projectedFinished: boolean;
  pendingActive: boolean;
  projectedCapped: boolean;
  canPay: boolean;
  blockedUntil: number;
  now: number;
}

/** Whether to buy the next random word: a live run held at the pinned edge, with nothing already bought. */
export function shouldAutoBuyWord(input: AutoBuyWordInput): boolean {
  return (
    input.enabled &&
    input.hasBurner &&
    !input.busy &&
    input.gameStarted &&
    !input.chainFinished &&
    !input.projectedFinished &&
    !input.pendingActive &&
    input.projectedCapped &&
    input.canPay &&
    input.now >= input.blockedUntil
  );
}

export interface AutoSettleInput {
  enabled: boolean;
  hasBurner: boolean;
  busy: boolean;
  gameStarted: boolean;
  projectedFinished: boolean;
  settled: boolean;
  pendingActive: boolean;
  blockedUntil: number;
  now: number;
}

/** Whether to record the run: it is over and not recorded, and no word is on its way. */
export function shouldAutoSettle(input: AutoSettleInput): boolean {
  return (
    input.enabled &&
    input.hasBurner &&
    !input.busy &&
    input.gameStarted &&
    input.projectedFinished &&
    !input.settled &&
    !input.pendingActive &&
    input.now >= input.blockedUntil
  );
}

/**
 * Reverts that mean "not now", not "broken", so they never count towards stopping: the
 * page was behind the chain, or (settle) the death lies beyond the pinned edge.
 */
export function isExpectedRevert(fn: 'sync' | 'settle', revertName: string | undefined): boolean {
  if (fn === 'sync') return revertName === 'ActionPending';
  return revertName === 'GameNotFinished' || revertName === 'AlreadySettled';
}

export interface BackoffOptions {
  cooldownMs?: number;
  maxFailures?: number;
}

export interface Backoff {
  success: () => void;
  failure: (now: number) => { blockedUntil: number; stopped: boolean };
  reset: () => void;
}

/** Spaces out retries after a failure; `maxFailures` in a row stop them until `reset()`. */
export function createBackoff({ cooldownMs = 30_000, maxFailures = 3 }: BackoffOptions = {}): Backoff {
  let failures = 0;
  let stopped = false;

  return {
    success() {
      failures = 0;
    },
    failure(now) {
      failures += 1;
      if (failures >= maxFailures) stopped = true;
      return { blockedUntil: now + cooldownMs, stopped };
    },
    reset() {
      failures = 0;
      stopped = false;
    },
  };
}
