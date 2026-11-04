/**
 * One sandbox game: the engine state, the virtual clock, the simulated chain delays
 * and the record of every engine call. No React, no timers of its own — the page calls
 * `tick()` a few times a second and re-renders; everything is timed on the virtual
 * clock, so a pause freezes delays too.
 *
 * Exactly one thing is "in flight" at a time (`job`): an action waiting for its
 * transaction, a word request waiting for the random source, or the autopilot's sync.
 * That is what makes "one action in flight" and "one word request in flight" hold.
 */

import { Refusal, type Action } from '@shared/types';
import { act, needsWord, resolve, startGame, sync, view, type EngineState, type LogEntry } from './engine';
import { VirtualClock } from './clock';
import type { Call, ParamSet, PresetName } from './params';
import { cloneVariants, defaultVariants, type VariantSet } from './variant/variants';

export interface Delays {
  /** Click → transaction lands. */
  txMs: number;
  /** Request → word arrives. */
  wordMs: number;
  /** World capped at the pinned edge → the autopilot buys the next word. */
  autopilotMs: number;
}

/** Name of a refusal (the engine adds the string 'ActionPending' to the enum). */
export function refusalName(r: Refusal | 'ActionPending'): string {
  return typeof r === 'string' ? r : Refusal[r];
}

export const CHAIN_DELAYS: Delays = { txMs: 1000, wordMs: 2500, autopilotMs: 2000 };
export const NO_DELAYS: Delays = { txMs: 0, wordMs: 0, autopilotMs: 0 };

type Job = { kind: 'act'; slot: bigint; action: Action; dueMs: number } | { kind: 'resolve'; dueMs: number } | { kind: 'sync'; dueMs: number };

export type Status = 'game over' | 'paused' | 'action in flight' | 'waiting for word' | 'running';

export interface Deps {
  clock?: VirtualClock;
  /** A fresh 256-bit random word. */
  randomWord?: () => bigint;
}

/** 256 random bits from the browser's CSPRNG. */
export function cryptoWord(): bigint {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let w = 0n;
  for (const b of bytes) w = (w << 8n) | BigInt(b);
  return w;
}

export class Session {
  readonly clock: VirtualClock;
  readonly params: ParamSet;
  readonly preset: PresetName;
  /** The rule variants the game was started with (all off: the mirror's rules). */
  readonly variants: VariantSet;
  readonly startedAt: bigint;
  /** Delays in force for this game (changing the toggle affects the jobs scheduled afterwards). */
  delays: Delays;
  readonly delaysAtStart: boolean;
  readonly calls: Call[] = [];
  state: EngineState;
  /** The last note worth showing: a refusal, an error. */
  note: string | null = null;
  private job: Job | null = null;
  private readonly randomWord: () => bigint;
  private endedAtMs: number | null = null;

  /** Throws InvalidConfigError for a configuration the contract's constructor would reject. */
  constructor(params: ParamSet, preset: PresetName, delaysOn: boolean, deps: Deps = {}, variants: VariantSet = defaultVariants()) {
    this.params = params;
    this.preset = preset;
    this.variants = cloneVariants(variants);
    this.delaysAtStart = delaysOn;
    this.delays = delaysOn ? CHAIN_DELAYS : NO_DELAYS;
    this.clock = deps.clock ?? new VirtualClock();
    this.randomWord = deps.randomWord ?? cryptoWord;
    const nowTs = this.clock.now();
    this.state = startGame(params.config, params.types, nowTs, { buyFirstWord: true, variants: this.variants });
    this.startedAt = this.state.player.game.startedAt;
    this.calls.push({ kind: 'start', nowTs, buyFirstWord: true });
    this.schedule();
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  get over(): boolean {
    return this.state.player.game.finished;
  }

  get paused(): boolean {
    return this.clock.paused;
  }

  get log(): readonly LogEntry[] {
    return this.state.log;
  }

  /** Real (running) milliseconds of play; frozen once the game is over. */
  playedMs(): number {
    return this.endedAtMs ?? this.clock.elapsedMs();
  }

  /** Whether a click on an action would be accepted now. */
  canAct(): boolean {
    return !this.over && !this.paused && this.job === null && !needsWord(this.state, this.clock.now());
  }

  status(): Status {
    if (this.over) return 'game over';
    if (this.paused) return 'paused';
    if (this.job?.kind === 'act') return 'action in flight';
    if (this.job || needsWord(this.state, this.clock.now())) return 'waiting for word';
    return 'running';
  }

  // ── Commands ───────────────────────────────────────────────────────────────

  /** Queue an action: it reaches the engine after the transaction delay, at that moment's time. */
  requestAction(slot: bigint, action: Action): boolean {
    if (!this.canAct()) return false;
    this.note = null;
    this.job = { kind: 'act', slot, action, dueMs: this.clock.elapsedMs() + this.delays.txMs };
    this.tick();
    return true;
  }

  /** Switch the simulated chain delays; affects jobs scheduled from now on. */
  setDelays(on: boolean): void {
    this.delays = on ? CHAIN_DELAYS : NO_DELAYS;
  }

  setPaused(paused: boolean): void {
    if (this.over) return;
    if (paused) this.clock.pause();
    else this.clock.resume();
  }

  /** Advance the session: run a job that has come due and schedule the next. Call ~4×/s. */
  tick(): void {
    if (this.over || this.paused) return;
    for (let i = 0; i < 8; i++) {
      if (!this.step()) break;
    }
    if (this.over && this.endedAtMs === null) this.endedAtMs = this.clock.elapsedMs();
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  /** One step; true if something ran (so another step may follow at once). */
  private step(): boolean {
    if (this.job === null) {
      this.schedule();
      if (this.job === null) return this.finishIfDead();
    }
    const job = this.job as Job | null;
    if (job === null || this.clock.elapsedMs() < job.dueMs) return false;
    this.job = null;
    const nowTs = this.clock.now();
    try {
      if (job.kind === 'act') {
        const r = act(this.state, job.slot, job.action, nowTs);
        this.state = r.state;
        this.calls.push({ kind: 'act', nowTs, slot: job.slot, action: job.action });
        if (r.result.kind === 'refused') this.note = `refused: ${refusalName(r.result.reason)}`;
        else if (r.result.kind === 'error') this.note = `error: ${r.result.message}`;
      } else if (job.kind === 'resolve') {
        const word = this.randomWord();
        this.state = resolve(this.state, word, nowTs);
        this.calls.push({ kind: 'resolve', nowTs, word });
      } else {
        const word = this.randomWord();
        this.state = sync(this.state, word, nowTs);
        this.calls.push({ kind: 'sync', nowTs, word });
      }
    } catch (e) {
      this.note = `engine error: ${e instanceof Error ? e.message : String(e)}`;
    }
    return true;
  }

  /** Pick the next automatic job, if the world needs one. */
  private schedule(): void {
    if (this.job !== null || this.over) return;
    const nowTs = this.clock.now();
    const nowMs = this.clock.elapsedMs();
    if (this.state.player.pending.active) {
      this.job = { kind: 'resolve', dueMs: nowMs + this.delays.wordMs };
    } else if (needsWord(this.state, nowTs)) {
      this.job = { kind: 'sync', dueMs: nowMs + this.delays.autopilotMs };
    }
  }

  /**
   * The projection says the lab is dead but no call has recorded it yet: make the free
   * sync that persists the death (and logs the collapses and gameOver), so the log and
   * the summary are complete. Only when no deferral is outstanding (its reveal will do it).
   */
  private finishIfDead(): boolean {
    if (this.over || this.state.player.pending.active) return false;
    const nowTs = this.clock.now();
    if (!view(this.state, nowTs).game.finished) return false;
    const word = this.randomWord();
    try {
      this.state = sync(this.state, word, nowTs);
      this.calls.push({ kind: 'sync', nowTs, word });
    } catch (e) {
      this.note = `engine error: ${e instanceof Error ? e.message : String(e)}`;
      return false;
    }
    return true;
  }
}

// ── Summary ──────────────────────────────────────────────────────────────────

export interface Summary {
  hoursSurvived: bigint;
  realSeconds: bigint;
  actions: number;
  portalsClosed: number;
  portalsCollapsed: number;
  creaturesRescued: bigint;
}

export function summarize(s: Session): Summary {
  const g = s.state.player.game;
  const count = (kind: LogEntry['kind']) => s.state.log.filter((e) => e.kind === kind).length;
  return {
    hoursSurvived: g.diedAtHour,
    realSeconds: g.lastTickAt - g.startedAt,
    actions: count('actionPerformed'),
    portalsClosed: count('portalClosed'),
    portalsCollapsed: count('portalCollapsed'),
    creaturesRescued: g.creaturesRescued,
  };
}
