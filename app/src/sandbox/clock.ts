/**
 * Virtual clock of the balance sandbox: the stand-in for block.timestamp.
 *
 * Driven by real time (an injected `Date.now`), but it can be paused: while paused
 * the clock stands still, so the world does not age, and on resume it carries on
 * from where it stopped. It never goes backwards, even if the real clock does.
 *
 * `now()` is whole seconds as a bigint (the engine's `nowTs`); `elapsedMs()` is the
 * running time in milliseconds (pauses excluded), used to time simulated delays.
 */
export class VirtualClock {
  private readonly real: () => number;
  /** Running milliseconds banked before `since`. */
  private banked = 0;
  /** Real time of the last resume (or the start); null while paused. */
  private since: number | null;
  private last = 0;

  /**
   * @param startTs first value of `now()` — a positive number of seconds (the engine
   *   refuses a non-positive timestamp). Defaults to the current real time in seconds.
   * @param real source of real time in milliseconds, `Date.now` by default.
   */
  constructor(startTs?: bigint, real: () => number = Date.now) {
    this.real = real;
    this.startTs = startTs ?? BigInt(Math.floor(real() / 1000));
    this.since = real();
  }

  readonly startTs: bigint;

  get paused(): boolean {
    return this.since === null;
  }

  /** Running time in ms since the start, pauses excluded; monotone. */
  elapsedMs(): number {
    const raw = this.since === null ? this.banked : this.banked + (this.real() - this.since);
    if (raw > this.last) this.last = raw;
    return this.last;
  }

  /** The current timestamp in whole seconds. */
  now(): bigint {
    return this.startTs + BigInt(Math.floor(this.elapsedMs() / 1000));
  }

  pause(): void {
    if (this.since === null) return;
    this.banked = this.elapsedMs();
    this.since = null;
  }

  resume(): void {
    if (this.since !== null) return;
    this.since = this.real();
  }
}
