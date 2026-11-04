/**
 * Chain-free game engine for the balance sandbox: plays a whole game of the lab in
 * the browser, with any configuration, on top of the rules mirror in shared/.
 *
 * shared/ mirrors the rules (catch-up, feasibility, cost, effects). What it does not
 * have is the ORCHESTRATION in contracts/src/PortalLab.sol — startGame, act and its
 * two-phase deferrals, the random-word callback (receiveWord) and sync. That is what
 * this module reproduces, step for step; every function below names the Solidity it
 * mirrors. Source of truth is PortalLab.sol: where this file and the contract
 * disagree, this file is wrong. Do not reorder steps — the order is visible in the
 * game (what the catch-up sees, which refusal wins, which slot a newborn takes).
 *
 * Functional core: no timers, no randomness of its own, no clock. Time (`nowTs`, the
 * stand-in for block.timestamp) and random words come in as arguments, so the same
 * sequence of calls always yields the same game. No function touches the state it is
 * given; each returns a new one (the convention of shared/).
 *
 * What is NOT mirrored, because the sandbox has no use for it: fees as amounts
 * (whether a word is bought is mirrored; what it costs is not), refunds of the
 * native coin, the leaderboard and settle/bestRun, forfeiting a running game,
 * cancelDeferred (the randomness timeout) and anything about other players.
 *
 * ── Two-phase calls ─────────────────────────────────────────────────────────
 *
 * On chain a deferral is a commit transaction and, ~0.6 s later, a callback from the
 * random source. Here `act` performs the commit and `resolve` performs the callback,
 * each at the `nowTs` it is given. `sync` is the paid sync of the live front's
 * autopilot with the callback folded in: the commit and the reveal both happen at the
 * one `nowTs`, so the world is carried across the pinned edge in one call.
 *
 * `startGame` with `buyFirstWord` mirrors the live front's start, which always pays:
 * the start commits a sync-only deferral for epoch 0 and `resolve` is its callback,
 * after which the starting hand of three portals stands at hour 0 (on chain, 2–3 s
 * after the start). Without it no word is bought and the hand waits for the first
 * `sync`, which the world only needs once the first hour has passed.
 *
 * ── The log ─────────────────────────────────────────────────────────────────
 *
 * `state.log` is append-only: one entry per thing that happened, in the order the
 * contract emits its events (SPEC §15.4: catch-up collapses, then catch-up spawns,
 * then the action's own events; with an hourly rule variant on, its arrivals and
 * jumps follow the spawns). Entries are plain JSON-serialisable objects:
 *   - every integer (bigint in the engine) is written as a decimal STRING;
 *   - enums (Action, Refusal, PortalType) are written as their integer values, as
 *     numbers; the one engine-only refusal is the string 'ActionPending';
 *   - `ts` is the `nowTs` of the call that produced the entry, `hour` the game hour
 *     the thing happened at (which may be earlier than `ts` — lazy time).
 * Entries with no on-chain event of their own: `deferralRequested` (except for the
 * survey commit, where it stands for SurveyRequested), `deferralResolved`,
 * `wordPinned`, and `actionRefused` (a refusal is a revert on chain and leaves no
 * trace there). A paid `sync` logs no deferral entries — only the `wordPinned` and
 * the catch-up it caused. A paid start logs a `deferralRequested` (crossing) at its
 * commit; its `resolve` logs the `wordPinned` and the catch-up, as a paid sync does.
 *
 * ── Rule variants (sandbox only) ────────────────────────────────────────────
 *
 * `startGame` may be given a variant set (variant/variants.ts). With none, or with
 * every variant off, `state.variants` stays unset and this module calls the plain
 * mirror in shared/ — the contract. With any variant on, every catch-up goes through
 * the fork in variant/time.ts and every `applyAction` through variant/effects.ts, and
 * each performed action adds the V6 pressure. Variant-only log entries:
 * `creatureArrived`, `stabilityJump`, and `earlyCollapse: true` on a
 * `portalCollapsed` (the field is absent otherwise).
 */

import {
  ContractRevert,
  addChecked,
  applyAction,
  applyBlindRescuerReveal,
  emptyPortal,
  subChecked,
  survey,
  trunc,
  type Outcome,
} from '@shared/effects';
import { preview, type PreviewResult } from '@shared/preview';
import { check, cost } from '@shared/rules';
import { catchUp, type CatchUpResult } from '@shared/time';
import {
  Action,
  MAX_OPEN_PORTALS,
  MAX_RESCUERS,
  Refusal,
  type Config,
  type Game,
  type Pending,
  type Portal,
  type PortalType,
  type PortalTypeParams,
} from '@shared/types';
import type { TypeTable } from './presets';
import { addActionPressure, applyActionVariant, type VOutcome } from './variant/effects';
import { catchUpVariant, type HourlyEvent, type VCollapse } from './variant/time';
import { anyVariantOn, cloneVariants, type VariantSet } from './variant/variants';

// ── State ────────────────────────────────────────────────────────────────────

/** Mirror of the on-chain `Player` record (PortalLabTypes.sol): everything the rules read. */
export interface PlayerRecord {
  game: Game;
  /** Exactly MAX_OPEN_PORTALS (12) portals. */
  portals: Portal[];
  /** The deferral slot; `coveredEpochs` in it is game state and outlives any deferral. */
  pending: Pending;
  /** The word pinning the spawn epochs below `pending.coveredEpochs`. */
  epochWord: bigint;
}

export interface EngineState {
  /** The configuration the game was started with (the contract's immutable `_config`). */
  config: Config;
  /** The per-type table it was started with (`_portalTypeParams`). */
  types: TypeTable;
  player: PlayerRecord;
  /**
   * Next request id the random source will hand out. Stands in for the source's own
   * sequence number (Pyth's), which on chain lives outside PortalLab; it only labels
   * deferrals and never feeds a rule.
   */
  nextRequestId: bigint;
  log: LogEntry[];
  /**
   * The rule variants of this game; unset when none is on — then every rule is the
   * mirror's (see "Rule variants" at the top).
   */
  variants?: VariantSet;
}

/** A refusal: a rules Refusal, or ActionPending — a distinct custom error on chain. */
export type EngineRefusal = Refusal | 'ActionPending';

export type ActResult =
  | { kind: 'done' }
  | { kind: 'deferred' }
  | { kind: 'refused'; reason: EngineRefusal }
  | { kind: 'error'; message: string };

/** Thrown where the contract reverts at an entry gate that `act`'s result type cannot express. */
export class EngineCallError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'EngineCallError';
  }
}

/** Thrown by `startGame` for a configuration PortalLab's constructor would reject. */
export class InvalidConfigError extends Error {
  constructor(public readonly reason: string) {
    super(`invalid config: ${reason}`);
    this.name = 'InvalidConfigError';
  }
}

// ── Log ──────────────────────────────────────────────────────────────────────

/** A bigint written as a decimal string (see the note on the log at the top). */
export type Dec = string;

export type LogEntry =
  | { kind: 'gameStarted'; ts: Dec; startedAt: Dec }
  | {
      kind: 'actionPerformed';
      ts: Dec;
      slot: Dec;
      action: Action;
      powerSpent: Dec;
      hour: Dec;
      powerBefore: Dec;
      powerAfter: Dec;
      hpAfter: Dec;
    }
  | { kind: 'actionRefused'; ts: Dec; slot: Dec; action: Action; reason: EngineRefusal; hour: Dec }
  | {
      kind: 'deferralRequested';
      ts: Dec;
      slot: Dec;
      action: Action;
      requestId: Dec;
      hour: Dec;
      /** True for an epoch-crossing deferral (the whole action waits for the word). */
      crossing: boolean;
    }
  | { kind: 'deferralResolved'; ts: Dec; slot: Dec; action: Action; requestId: Dec; hour: Dec }
  | {
      kind: 'deferralCancelled';
      ts: Dec;
      slot: Dec;
      action: Action;
      reason: Refusal;
      requestId: Dec;
      hour: Dec;
      /** Power given back (only the in-epoch survey and blind-rescue cancels refund). */
      powerRefunded: Dec;
    }
  /** Epochs [fromEpoch, toEpoch) were pinned to a new word. */
  | { kind: 'wordPinned'; ts: Dec; fromEpoch: Dec; toEpoch: Dec }
  | { kind: 'portalCollapsed'; ts: Dec; slot: Dec; deaths: Dec; hpLost: Dec; hour: Dec; earlyCollapse?: true }
  | { kind: 'portalSpawned'; ts: Dec; slot: Dec; portalType: PortalType; nameIndex: Dec; hour: Dec }
  | { kind: 'portalSurveyed'; ts: Dec; slot: Dec; precise: boolean; hour: Dec }
  | { kind: 'portalClosed'; ts: Dec; slot: Dec; deaths: Dec; hpLost: Dec; hour: Dec }
  | { kind: 'creaturesRescued'; ts: Dec; slot: Dec; count: Dec; hpGained: Dec; hour: Dec }
  | { kind: 'rescuerRecovering'; ts: Dec; slot: Dec; readyAtHour: Dec }
  | { kind: 'gameOver'; ts: Dec; hour: Dec }
  /** V1: a creature arrived in the portal in `slot`. */
  | { kind: 'creatureArrived'; ts: Dec; slot: Dec; hour: Dec }
  /** V2: the portal in `slot` lost `amount` stability (the drawn amount, before the floor at 0). */
  | { kind: 'stabilityJump'; ts: Dec; slot: Dec; amount: Dec; hour: Dec };

/** A catch-up result of either engine: the fork adds the early flags and the hourly events. */
type AnyCatchUp = CatchUpResult & { hourly?: readonly HourlyEvent[] };

const dec = (x: bigint): Dec => x.toString();

/** Collects the entries of one call; appended to the log only if the call stands. */
class Emitter {
  readonly entries: LogEntry[] = [];
  readonly ts: Dec;

  constructor(nowTs: bigint) {
    this.ts = dec(nowTs);
  }

  /** Mirror of PortalLab._emitCollapses and _emitSpawns, in that order. */
  catchUp(r: AnyCatchUp): void {
    for (const e of r.events) {
      const entry: LogEntry = { kind: 'portalCollapsed', ts: this.ts, slot: dec(e.slot), deaths: dec(e.deaths), hpLost: dec(e.hpLost), hour: dec(e.atHour) };
      if ((e as Partial<VCollapse>).early) entry.earlyCollapse = true;
      this.entries.push(entry);
    }
    for (const s of r.spawns) {
      this.entries.push({ kind: 'portalSpawned', ts: this.ts, slot: dec(s.slot), portalType: s.portalType, nameIndex: dec(s.nameIndex), hour: dec(s.atHour) });
    }
    for (const h of r.hourly ?? []) {
      if (h.kind === 'arrival') this.entries.push({ kind: 'creatureArrived', ts: this.ts, slot: dec(h.slot), hour: dec(h.atHour) });
      else this.entries.push({ kind: 'stabilityJump', ts: this.ts, slot: dec(h.slot), amount: dec(h.amount), hour: dec(h.atHour) });
    }
  }

  actionPerformed(slot: bigint, action: Action, powerSpent: bigint, hour: bigint, powerBefore: bigint, g: Game): void {
    this.entries.push({
      kind: 'actionPerformed',
      ts: this.ts,
      slot: dec(slot),
      action,
      powerSpent: dec(powerSpent),
      hour: dec(hour),
      powerBefore: dec(powerBefore),
      powerAfter: dec(g.power),
      hpAfter: dec(g.hp),
    });
  }

  /** The events `act` emits after ActionPerformed on the single-phase path (and the deferred generic path). */
  outcome(slot: bigint, action: Action, o: Outcome, hour: bigint): void {
    if (o.surveyDone) this.entries.push({ kind: 'portalSurveyed', ts: this.ts, slot: dec(slot), precise: o.surveyPrecise, hour: dec(hour) });
    if (action === Action.Evacuate) {
      this.entries.push({ kind: 'creaturesRescued', ts: this.ts, slot: dec(slot), count: dec(o.rescued), hpGained: dec(o.hpGained), hour: dec(hour) });
    } else if (action === Action.Close) {
      this.entries.push({ kind: 'portalClosed', ts: this.ts, slot: dec(slot), deaths: dec(o.deaths), hpLost: dec(o.hpLost), hour: dec(hour) });
    }
    if (o.rescuerBlindMiss) this.rescuerRecovering(slot, o.rescuerReadyAtHour);
    const rest = (o as Partial<VOutcome>).rescuerRestReadyAt;
    if (rest) this.rescuerRecovering(slot, rest); // V5
  }

  rescuerRecovering(slot: bigint, readyAtHour: bigint): void {
    this.entries.push({ kind: 'rescuerRecovering', ts: this.ts, slot: dec(slot), readyAtHour: dec(readyAtHour) });
  }

  surveyed(slot: bigint, precise: boolean, hour: bigint): void {
    this.entries.push({ kind: 'portalSurveyed', ts: this.ts, slot: dec(slot), precise, hour: dec(hour) });
  }

  gameOver(hour: bigint): void {
    this.entries.push({ kind: 'gameOver', ts: this.ts, hour: dec(hour) });
  }

  deferralRequested(pend: Pending): void {
    this.entries.push({
      kind: 'deferralRequested',
      ts: this.ts,
      slot: dec(pend.slot),
      action: pend.action,
      requestId: dec(pend.requestId),
      hour: dec(pend.atHour),
      crossing: pend.deferredWorld,
    });
  }

  deferralResolved(pend: Pending, hour: bigint): void {
    this.entries.push({ kind: 'deferralResolved', ts: this.ts, slot: dec(pend.slot), action: pend.action, requestId: dec(pend.requestId), hour: dec(hour) });
  }

  deferralCancelled(pend: Pending, reason: Refusal, hour: bigint, powerRefunded: bigint): void {
    this.entries.push({
      kind: 'deferralCancelled',
      ts: this.ts,
      slot: dec(pend.slot),
      action: pend.action,
      reason,
      requestId: dec(pend.requestId),
      hour: dec(hour),
      powerRefunded: dec(powerRefunded),
    });
  }

  wordPinned(fromEpoch: bigint, toEpoch: bigint): void {
    this.entries.push({ kind: 'wordPinned', ts: this.ts, fromEpoch: dec(fromEpoch), toEpoch: dec(toEpoch) });
  }
}

function withLog(state: EngineState, player: PlayerRecord, nextRequestId: bigint, em: Emitter): EngineState {
  return { ...state, player, nextRequestId, log: [...state.log, ...em.entries] };
}

// ── Helpers mirroring PortalLab internals ────────────────────────────────────

/** A zeroed Pending with the given coverage (the `Pending` of a fresh `delete`). */
function idlePending(coveredEpochs: bigint): Pending {
  return {
    active: false,
    action: Action.ToggleQuestioned,
    slot: 0n,
    portalId: 0n,
    atHour: 0n,
    requestId: 0n,
    coveredEpochs,
    deferredWorld: false,
    syncOnly: false,
    committedAt: 0n,
  };
}

/** Mirror of PortalLab._catchUpFree (lines 1339–1355): one stored word, one stored limit. */
function catchUpFree(state: EngineState, nowTs: bigint): AnyCatchUp {
  const rec = state.player;
  const covered = rec.pending.coveredEpochs;
  return catchUpAny(state, rec.game, rec.portals, rec.epochWord, rec.epochWord, covered, covered, nowTs);
}

/** The catch-up of this game: the mirror's, or the variant fork's when variants are on. */
function catchUpAny(
  state: EngineState,
  g: Game,
  portals: readonly Portal[],
  oldWord: bigint,
  newWord: bigint,
  storedCovered: bigint,
  maxCovered: bigint,
  nowTs: bigint,
): AnyCatchUp {
  if (state.variants) {
    return catchUpVariant(g, portals, state.config, state.types, state.variants, oldWord, newWord, storedCovered, maxCovered, nowTs);
  }
  return catchUp(g, portals, state.config, state.types, oldWord, newWord, storedCovered, maxCovered, nowTs);
}

/** The effect of an allowed action: the mirror's, or the variant fork's (V3–V5). */
function applyActionAny(state: EngineState, g: Game, p: Portal, tp: PortalTypeParams, a: Action): { game: Game; portal: Portal; outcome: Outcome } {
  if (state.variants) return applyActionVariant(g, p, state.config, tp, a, state.variants);
  return applyAction(g, p, state.config, tp, a);
}

/** V6: the pressure a performed action adds (none without variants). */
function actionPressure(state: EngineState, g: Game): Game {
  return state.variants ? addActionPressure(g, state.variants) : g;
}

/** Mirror of PortalLab._epochOf (lines 1331–1334). */
function epochOf(c: Config, startedAt: bigint, ts: bigint): bigint {
  if (ts <= startedAt) return 0n;
  return trunc((ts - startedAt) / c.secPerHour / c.epochHours, 32);
}

/** Mirror of PortalLab._setPortal: a new array with `p` in `slot`. */
function setPortal(portals: readonly Portal[], slot: bigint, p: Portal): Portal[] {
  const next = portals.slice();
  next[Number(slot)] = p;
  return next;
}

/** `p = portals[slot]` when the slot is valid, else a zeroed Portal (`Portal memory p;`). */
function portalAt(portals: readonly Portal[], slot: bigint): Portal {
  return slot < MAX_OPEN_PORTALS ? portals[Number(slot)] : emptyPortal();
}

/** Death from one's own action (act lines 559–563): returns the game with the flag set. */
function markDeath(g: Game): { game: Game; gameOver: boolean } {
  if (g.hp !== 0n) return { game: g, gameOver: false };
  return { game: { ...g, finished: true, diedAtHour: g.hoursElapsed }, gameOver: true };
}

/** Restore `refund` power, capped at powerMax (the reveal cancels, lines 668–671 / 743–746). */
function refundPower(g: Game, c: Config, refund: bigint): Game {
  const restored = g.power + refund;
  return { ...g, power: restored > c.powerMax ? c.powerMax : trunc(restored, 16) };
}

// ── startGame ────────────────────────────────────────────────────────────────

/** Mirror of the PortalLab constructor's validation (lines 199–246), same order, same reasons. */
export function validateConfig(cfg: Config, params: readonly PortalTypeParams[]): void {
  if (cfg.secPerHour === 0n) throw new InvalidConfigError('secPerHour');
  if (cfg.hpMax === 0n) throw new InvalidConfigError('hpMax');
  if (cfg.hpStart === 0n) throw new InvalidConfigError('hpStart');
  if (cfg.hpStart > cfg.hpMax) throw new InvalidConfigError('hpStart');
  if (cfg.powerMax === 0n) throw new InvalidConfigError('powerMax');
  if (cfg.observersTotal === 0n) throw new InvalidConfigError('observersTotal');
  if (cfg.rescuersTotal === 0n) throw new InvalidConfigError('rescuersTotal');
  if (cfg.rescuersTotal > MAX_RESCUERS) throw new InvalidConfigError('rescuersTotal');
  if (cfg.rescuerCooldownHours === 0n) throw new InvalidConfigError('rescuerCooldownHours');
  if (cfg.spawnCostUnits === 0n) throw new InvalidConfigError('spawnCostUnits');
  if (cfg.hpEmptyCollapse === 0n) throw new InvalidConfigError('hpEmptyCollapse');
  if (cfg.epochHours === 0n) throw new InvalidConfigError('epochHours');
  if (cfg.requestTimeoutHours === 0n) throw new InvalidConfigError('requestTimeoutHours');
  if (cfg.outsiderTimeoutHours === 0n || cfg.outsiderTimeoutHours < cfg.requestTimeoutHours) {
    throw new InvalidConfigError('outsiderTimeoutHours');
  }
  if (cfg.closeStabilityBelow > 100n) throw new InvalidConfigError('closeStabilityBelow');
  if (cfg.healPerCreature >= cfg.hpCollapsePerDeath) throw new InvalidConfigError('healPerCreature');

  // The contract takes a fixed PortalTypeParams[5]; here the length must be checked.
  if (params.length !== 5) throw new InvalidConfigError('portalTypeParams length');
  for (const p of params) {
    if (p.hoursMin === 0n) throw new InvalidConfigError('hoursMin');
    if (p.hoursMin > p.hoursMax) throw new InvalidConfigError('hoursMin>hoursMax');
    if (p.energyMin > p.energyMax) throw new InvalidConfigError('energyMin>energyMax');
    if (p.energyMax > 100n) throw new InvalidConfigError('energyMax');
    if (p.stabilityMin > p.stabilityMax) throw new InvalidConfigError('stabilityMin>stabilityMax');
    if (p.stabilityMax > 100n) throw new InvalidConfigError('stabilityMax');
    if (p.creaturesMin > p.creaturesMax) throw new InvalidConfigError('creaturesMin>creaturesMax');
    if (p.actionMultiplierPct === 0n) throw new InvalidConfigError('actionMultiplierPct');
  }
}

/** Options of `startGame`. */
export interface StartOptions {
  /**
   * Attach the fee (`msg.value > 0`): buy the first word at the start, as the live
   * front always does. False starts with no word, as a feeless call does.
   */
  buyFirstWord: boolean;
  /** Rule variants (sandbox only). Absent or all off: the mirror's rules. */
  variants?: VariantSet;
  /**
   * Run on the variant fork even when every variant is off. For the tests that prove
   * the fork with everything off equals the mirror; the page never sets it.
   */
  forceVariantEngine?: boolean;
}

/**
 * Mirror of PortalLab.startGame (lines 256–345) for a player with no game: the
 * constructor's validation, then a fresh record.
 *
 * With `buyFirstWord` the paid branch (lines 322–345) follows: a sync-only deferral
 * crossing into epoch 0 is committed and stays outstanding until `resolve` delivers
 * the word, which pins epoch 0 and births the starting hand of three portals at
 * hour 0. Until then every `act` is refused ActionPending and `needsWord` is true.
 * Without it no word is bought; the first `sync` pins epoch 0, and the hand is
 * likewise born at hour 0.
 */
export function startGame(config: Config, types: TypeTable, nowTs: bigint, opts: StartOptions): EngineState {
  validateConfig(config, types);
  // block.timestamp is never 0; a zero startedAt would read as "no game".
  if (nowTs <= 0n) throw new EngineCallError('startGame: nowTs must be positive');

  const portals: Portal[] = [];
  for (let i = 0n; i < MAX_OPEN_PORTALS; i++) portals.push(emptyPortal());
  const game: Game = {
    startedAt: trunc(nowTs, 40),
    lastTickAt: trunc(nowTs, 40),
    hoursElapsed: 0n,
    diedAtHour: 0n,
    hp: config.hpStart,
    power: config.powerMax,
    observersFree: config.observersTotal,
    rescuersFree: config.rescuersTotal,
    openPortals: 0n,
    finished: false,
    // A starting hand: three portals' worth of pressure already accrued at hour 0.
    spawnDebt: 3n * config.spawnCostUnits,
    spawnCount: 0n,
    rngNonce: 0n,
    rescuerReadyAt0: 0n,
    rescuerReadyAt1: 0n,
    rescuerReadyAt2: 0n,
    rescuerReadyAt3: 0n,
    creaturesRescued: 0n,
    settled: false,
  };

  const em = new Emitter(nowTs);
  em.entries.push({ kind: 'gameStarted', ts: em.ts, startedAt: dec(game.startedAt) });
  const fresh: EngineState = {
    config,
    types,
    player: { game, portals, pending: idlePending(0n), epochWord: 0n },
    nextRequestId: 1n,
    log: em.entries,
  };
  if (opts.variants && (opts.forceVariantEngine || anyVariantOn(opts.variants))) fresh.variants = cloneVariants(opts.variants);
  if (!opts.buyFirstWord) return fresh;

  // The paid branch (lines 325–344): buy the first word now, exactly like a paid
  // `sync` crossing the pinned edge (epoch 0 is not covered on a fresh game).
  const pend: Pending = {
    active: true,
    action: Action.ToggleQuestioned, // unused (syncOnly)
    slot: 0n,
    portalId: 0n,
    atHour: 0n,
    requestId: fresh.nextRequestId,
    coveredEpochs: fresh.player.pending.coveredEpochs,
    deferredWorld: true,
    syncOnly: true,
    committedAt: game.startedAt,
  };
  const paid = new Emitter(nowTs);
  paid.deferralRequested(pend);
  return withLog(fresh, { ...fresh.player, pending: pend }, fresh.nextRequestId + 1n, paid);
}

// ── view / needsWord ─────────────────────────────────────────────────────────

/** The world as the front draws it: exactly shared/preview (free, capped at the pinned edge). */
export function view(state: EngineState, nowTs: bigint): PreviewResult {
  const rec = state.player;
  if (state.variants) {
    // The same argument pairing as shared/preview, on the fork.
    const covered = rec.pending.coveredEpochs;
    const r = catchUpAny(state, rec.game, rec.portals, rec.epochWord, rec.epochWord, covered, covered, nowTs);
    return { game: r.game, portals: r.portals, cappedShort: r.cappedShort };
  }
  return preview(
    { game: rec.game, portals: rec.portals, epochWord: rec.epochWord, coveredEpochs: rec.pending.coveredEpochs },
    state.config,
    state.types,
    nowTs,
  );
}

/**
 * Whether a random word is required now: a deferral is waiting for its word (answer
 * with `resolve`), or the live world is capped at the pinned edge (answer with `sync`,
 * as the live front's autopilot does with a paid sync).
 *
 * At game hour 0 of a fresh game nothing is capped yet — the world has reached `now`,
 * it is merely empty — so this is false until the first hour passes. That is the
 * contract's own reading: a paid `sync` at hour 0 takes its free path and pins nothing.
 */
export function needsWord(state: EngineState, nowTs: bigint): boolean {
  if (state.player.pending.active) return true;
  const v = view(state, nowTs);
  return !v.game.finished && v.cappedShort;
}

// ── sync ─────────────────────────────────────────────────────────────────────

/**
 * Mirror of a PAID PortalLab.sync (lines 1115–1171) with its receiveWord callback
 * (_revealCrossing, lines 769–820) folded into the same `nowTs`.
 *
 * If the world is alive and capped at the pinned edge, the deferral is committed (the
 * free catch-up is discarded, as on chain) and revealed at once with `word`: the
 * world is aged in full and epochs up to `epochOf(nowTs)` are pinned. Otherwise this
 * is the free path: the caught-up world is persisted and `word` goes unused.
 *
 * Throws EngineCallError where the paid sync reverts ActionPending (a deferral is
 * outstanding and the world needs a word) — resolve the deferral first.
 * A ContractRevert from the rules propagates (the contract call would revert too).
 */
export function sync(state: EngineState, word: bigint, nowTs: bigint): EngineState {
  const rec = state.player;
  const wasFinished = rec.game.finished;
  const r = catchUpFree(state, nowTs);

  if (!r.game.finished && r.cappedShort) {
    if (rec.pending.active) throw new EngineCallError('sync: ActionPending — resolve the outstanding deferral first');
    const pend: Pending = {
      active: true,
      action: Action.ToggleQuestioned, // unused (syncOnly)
      slot: 0n,
      portalId: 0n,
      atHour: r.game.hoursElapsed,
      requestId: state.nextRequestId,
      coveredEpochs: rec.pending.coveredEpochs,
      deferredWorld: true,
      syncOnly: true,
      committedAt: trunc(nowTs, 40),
    };
    const committed: EngineState = { ...state, player: { ...rec, pending: pend }, nextRequestId: state.nextRequestId + 1n };
    return revealCrossing(committed, pend, word, nowTs, new Emitter(nowTs));
  }

  // Free path: persist and emit.
  const em = new Emitter(nowTs);
  em.catchUp(r);
  if (r.game.finished && !wasFinished) em.gameOver(r.game.diedAtHour);
  return withLog(state, { ...rec, game: r.game, portals: r.portals }, state.nextRequestId, em);
}

// ── act ──────────────────────────────────────────────────────────────────────

/**
 * Mirror of PortalLab.act (lines 375–594). A refusal returns `{ kind: 'refused' }` and
 * leaves the player record untouched (on chain it reverts); only an `actionRefused`
 * entry is added to the log. A ContractRevert from shared/ becomes `{ kind: 'error' }`
 * and changes nothing at all.
 */
export function act(state: EngineState, slot: bigint, action: Action, nowTs: bigint): { state: EngineState; result: ActResult } {
  try {
    return actInner(state, slot, action, nowTs);
  } catch (e) {
    if (e instanceof ContractRevert) return { state, result: { kind: 'error', message: e.message } };
    throw e;
  }
}

function refuse(state: EngineState, slot: bigint, action: Action, reason: EngineRefusal, hour: bigint, nowTs: bigint) {
  const entry: LogEntry = { kind: 'actionRefused', ts: dec(nowTs), slot: dec(slot), action, reason, hour: dec(hour) };
  return { state: { ...state, log: [...state.log, entry] }, result: { kind: 'refused', reason } as ActResult };
}

function actInner(state: EngineState, slot: bigint, action: Action, nowTs: bigint): { state: EngineState; result: ActResult } {
  const rec = state.player;
  const c = state.config;

  // One deferred action per player (line 379). On chain this reverts before any
  // catch-up; the hour logged is the projected one, computed only for the log.
  if (rec.pending.active) {
    let hour = rec.game.hoursElapsed;
    try {
      hour = catchUpFree(state, nowTs).game.hoursElapsed;
    } catch {
      // keep the stored hour
    }
    return refuse(state, slot, action, 'ActionPending', hour, nowTs);
  }

  // 1. Catch up (line 391).
  const r = catchUpFree(state, nowTs);
  let g = r.game;
  let portals = r.portals;

  // 2. The game ended during catch-up (line 396). Nothing is persisted.
  if (g.finished) return refuse(state, slot, action, Refusal.GameNotActive, g.hoursElapsed, nowTs);

  // 3. Crossing the pinned edge (lines 402–427): the WHOLE action defers, unchecked.
  //    The world is NOT advanced here; the reveal re-ages it in full.
  if (r.cappedShort) {
    const pend: Pending = {
      active: true,
      action,
      slot,
      portalId: slot < MAX_OPEN_PORTALS ? portals[Number(slot)].id : 0n,
      atHour: g.hoursElapsed,
      requestId: state.nextRequestId,
      coveredEpochs: rec.pending.coveredEpochs,
      deferredWorld: true,
      syncOnly: false,
      committedAt: trunc(nowTs, 40),
    };
    const em = new Emitter(nowTs);
    em.deferralRequested(pend);
    return { state: withLog(state, { ...rec, pending: pend }, state.nextRequestId + 1n, em), result: { kind: 'deferred' } };
  }

  let p = portalAt(portals, slot);

  // 4. Feasibility on the aged state (lines 435–436).
  const reason = check(g, p, c, slot, action);
  if (reason !== Refusal.None) return refuse(state, slot, action, reason, g.hoursElapsed, nowTs);

  // 5. Cost, then effect (lines 439–440).
  const powerBefore = g.power;
  const powerSpent = cost(c, action);
  g = { ...g, power: subChecked(g.power, powerSpent) };

  // ── Two-phase survey COMMIT (lines 443–501) ──
  if (action === Action.SendObserver && !p.surveyed) {
    p = { ...p, observerInside: true, surveyPending: true };
    g = { ...g, observersFree: subChecked(g.observersFree, 1n), rngNonce: addChecked(g.rngNonce, 1n, 32) };
    g = actionPressure(state, g);
    portals = setPortal(portals, slot, p);
    const pend: Pending = {
      active: true,
      action: Action.SendObserver,
      slot,
      portalId: p.id,
      atHour: g.hoursElapsed,
      requestId: state.nextRequestId,
      coveredEpochs: rec.pending.coveredEpochs,
      deferredWorld: false,
      syncOnly: false,
      committedAt: trunc(nowTs, 40),
    };
    const em = new Emitter(nowTs);
    em.catchUp(r);
    em.actionPerformed(slot, action, powerSpent, g.hoursElapsed, powerBefore, g);
    em.deferralRequested(pend); // SurveyRequested
    return { state: withLog(state, { ...rec, game: g, portals, pending: pend }, state.nextRequestId + 1n, em), result: { kind: 'deferred' } };
  }

  // ── Two-phase blind rescue COMMIT (lines 508–550) ──
  if (action === Action.SendRescuer && !p.creaturesKnown) {
    g = { ...g, rngNonce: addChecked(g.rngNonce, 1n, 32), rescuersFree: subChecked(g.rescuersFree, 1n) };
    g = actionPressure(state, g);
    p = { ...p, rescuerPending: true };
    portals = setPortal(portals, slot, p);
    const pend: Pending = {
      active: true,
      action: Action.SendRescuer,
      slot,
      portalId: p.id,
      atHour: g.hoursElapsed,
      requestId: state.nextRequestId,
      coveredEpochs: rec.pending.coveredEpochs,
      deferredWorld: false,
      syncOnly: false,
      committedAt: trunc(nowTs, 40),
    };
    const em = new Emitter(nowTs);
    em.catchUp(r);
    em.actionPerformed(slot, action, powerSpent, g.hoursElapsed, powerBefore, g);
    em.deferralRequested(pend); // no on-chain event of its own
    return { state: withLog(state, { ...rec, game: g, portals, pending: pend }, state.nextRequestId + 1n, em), result: { kind: 'deferred' } };
  }

  // ── Single-phase path (lines 553–593) ──
  const fx = applyActionAny(state, g, p, state.types[p.portalType], action);
  portals = setPortal(portals, slot, fx.portal);
  const death = markDeath(actionPressure(state, fx.game));
  g = death.game;

  const em = new Emitter(nowTs);
  em.catchUp(r);
  const atHour = g.hoursElapsed;
  em.actionPerformed(slot, action, powerSpent, atHour, powerBefore, g);
  em.outcome(slot, action, fx.outcome, atHour);
  if (death.gameOver) em.gameOver(g.diedAtHour);
  return { state: withLog(state, { ...rec, game: g, portals }, state.nextRequestId, em), result: { kind: 'done' } };
}

// ── resolve (receiveWord) ────────────────────────────────────────────────────

/**
 * Mirror of PortalLab.receiveWord (lines 613–627): deliver `word` for the outstanding
 * deferral at `nowTs`, dispatching on its shape exactly as the contract does.
 *
 * Throws EngineCallError when there is no deferral (the contract's UnknownRequest).
 * A ContractRevert from the rules propagates (the callback would revert too).
 */
export function resolve(state: EngineState, word: bigint, nowTs: bigint): EngineState {
  const pend = state.player.pending;
  if (!pend.active) throw new EngineCallError('resolve: UnknownRequest — no deferral is outstanding');
  const em = new Emitter(nowTs);
  if (pend.deferredWorld) return revealCrossing(state, pend, word, nowTs, em);
  if (pend.action === Action.SendObserver) return revealSurvey(state, pend, word, nowTs, em);
  return revealBlindRescue(state, pend, word, nowTs, em);
}

/** Mirror of PortalLab._revealSurvey (lines 632–687): the in-epoch survey reveal. */
function revealSurvey(state: EngineState, pend: Pending, word: bigint, nowTs: bigint, em: Emitter): EngineState {
  const rec = state.player;
  const c = state.config;
  const wasAlreadyFinished = rec.game.finished;

  const r = catchUpFree(state, nowTs);
  let g = r.game;
  let portals = r.portals;
  // Resolve the deferral but PRESERVE coverage.
  const pending = idlePending(rec.pending.coveredEpochs);

  const slot = pend.slot;
  const atHour = g.hoursElapsed;
  const stillLegal = !g.finished && slot < MAX_OPEN_PORTALS && portals[Number(slot)].surveyPending;

  em.catchUp(r);
  if (stillLegal) {
    const p0 = portals[Number(slot)];
    const sv = survey(p0, c, state.types[p0.portalType], word);
    portals = setPortal(portals, slot, { ...sv.portal, surveyPending: false });
    em.surveyed(slot, sv.precise, atHour);
    em.deferralResolved(pend, atHour);
  } else {
    const refund = cost(c, Action.SendObserver);
    g = refundPower(g, c, refund);
    if (slot < MAX_OPEN_PORTALS && portals[Number(slot)].surveyPending) {
      portals = setPortal(portals, slot, { ...portals[Number(slot)], surveyPending: false });
    }
    if (g.finished && !wasAlreadyFinished) em.gameOver(g.diedAtHour);
    // SurveyCancelled carries no reason on chain; it is derived the way the blind
    // rescue cancel derives its own (line 759).
    em.deferralCancelled(pend, g.finished ? Refusal.GameNotActive : Refusal.PortalEmpty, atHour, refund);
  }
  return withLog(state, { ...rec, game: g, portals, pending }, state.nextRequestId, em);
}

/** Mirror of PortalLab._revealBlindRescue (lines 699–762): the in-epoch blind rescue reveal. */
function revealBlindRescue(state: EngineState, pend: Pending, word: bigint, nowTs: bigint, em: Emitter): EngineState {
  const rec = state.player;
  const c = state.config;
  const wasAlreadyFinished = rec.game.finished;

  const r = catchUpFree(state, nowTs);
  let g = r.game;
  let portals = r.portals;
  const pending = idlePending(rec.pending.coveredEpochs);

  const slot = pend.slot;
  const atHour = g.hoursElapsed;
  const stillLegal = !g.finished && slot < MAX_OPEN_PORTALS && portals[Number(slot)].rescuerPending;

  em.catchUp(r);
  if (stillLegal) {
    const p0 = { ...portals[Number(slot)], rescuerPending: false };
    const fx = applyBlindRescuerReveal(g, p0, c, word);
    portals = setPortal(portals, slot, fx.portal);
    const death = markDeath(fx.game);
    g = death.game;
    if (fx.outcome.rescuerBlindMiss) em.rescuerRecovering(slot, fx.outcome.rescuerReadyAtHour);
    if (death.gameOver) em.gameOver(g.diedAtHour);
    em.deferralResolved(pend, atHour);
  } else {
    // The rescuer never entered: power refunded AND the rescuer returns.
    const refund = cost(c, Action.SendRescuer);
    g = refundPower(g, c, refund);
    g = { ...g, rescuersFree: addChecked(g.rescuersFree, 1n, 8) };
    if (slot < MAX_OPEN_PORTALS && portals[Number(slot)].rescuerPending) {
      portals = setPortal(portals, slot, { ...portals[Number(slot)], rescuerPending: false });
    }
    if (g.finished && !wasAlreadyFinished) em.gameOver(g.diedAtHour);
    em.deferralCancelled(pend, g.finished ? Refusal.GameNotActive : Refusal.PortalEmpty, atHour, refund);
  }
  return withLog(state, { ...rec, game: g, portals, pending }, state.nextRequestId, em);
}

/**
 * Mirror of PortalLab._revealCrossing (lines 769–820): age the world in full — the
 * old word below the stored coverage, the delivered word beyond — pin the new
 * coverage, then apply the deferred action (unless it is a paid-sync deferral).
 */
function revealCrossing(state: EngineState, pend: Pending, word: bigint, nowTs: bigint, em: Emitter): EngineState {
  const rec = state.player;
  const c = state.config;
  const wasAlreadyFinished = rec.game.finished;

  const oldWord = rec.epochWord;
  const storedCovered = pend.coveredEpochs;
  const newCovered = epochOf(c, rec.game.startedAt, nowTs) + 1n;

  const r = catchUpAny(state, rec.game, rec.portals, oldWord, word, storedCovered, newCovered, nowTs);
  let g = r.game;
  let portals = r.portals;

  // Pin the word and the new coverage, resolve the deferral — before any early return.
  em.wordPinned(storedCovered, newCovered);
  em.catchUp(r);

  const pinned = (game: Game, ps: Portal[]): EngineState =>
    withLog(state, { game, portals: ps, pending: idlePending(newCovered), epochWord: word }, state.nextRequestId, em);

  if (g.finished) {
    if (!wasAlreadyFinished) em.gameOver(g.diedAtHour);
    if (!pend.syncOnly) em.deferralCancelled(pend, Refusal.GameNotActive, g.hoursElapsed, 0n);
    return pinned(g, portals);
  }
  if (pend.syncOnly) return pinned(g, portals);

  ({ g, portals } = performDeferredAction(state, g, portals, pend, word, em));
  return pinned(g, portals);
}

/**
 * Mirror of PortalLab._performDeferredAction (lines 1025–1080) together with the three
 * helpers it delegates to: _applyEpochCrossingSurvey (827–848),
 * _applyEpochCrossingBlindRescue (899–921) and _applyGenericDeferredAction (854–893).
 * A cancel spends nothing and moves no crew — nothing was taken at commit.
 */
function performDeferredAction(
  state: EngineState,
  g: Game,
  portals: Portal[],
  pend: Pending,
  word: bigint,
  em: Emitter,
): { g: Game; portals: Portal[] } {
  const c = state.config;
  const slot = pend.slot;
  const action = pend.action;
  let p = portalAt(portals, slot);

  // The target is the portal chosen at commit, not whatever now sits in the slot.
  if (slot < MAX_OPEN_PORTALS && p.id !== pend.portalId) {
    em.deferralCancelled(pend, Refusal.PortalEmpty, g.hoursElapsed, 0n);
    return { g, portals };
  }

  const reason = check(g, p, c, slot, action);
  if (reason !== Refusal.None) {
    em.deferralCancelled(pend, reason, g.hoursElapsed, 0n);
    return { g, portals };
  }

  const powerBefore = g.power;
  const powerSpent = cost(c, action);
  g = { ...g, power: subChecked(g.power, powerSpent) };
  const atHour = g.hoursElapsed;
  const tp = state.types[p.portalType];

  if (action === Action.SendObserver && !p.surveyed) {
    // _applyEpochCrossingSurvey: the observer walks in and the survey is read at once.
    p = { ...p, observerInside: true };
    g = { ...g, observersFree: subChecked(g.observersFree, 1n), rngNonce: addChecked(g.rngNonce, 1n, 32) };
    g = actionPressure(state, g);
    const sv = survey(p, c, tp, word);
    portals = setPortal(portals, slot, sv.portal);
    em.actionPerformed(slot, action, powerSpent, atHour, powerBefore, g);
    em.surveyed(slot, sv.precise, atHour);
    em.deferralResolved(pend, atHour);
    return { g, portals };
  }

  if (action === Action.SendRescuer && !p.creaturesKnown) {
    // _applyEpochCrossingBlindRescue: the commit touched nothing; the rescuer leaves now.
    g = { ...g, rngNonce: addChecked(g.rngNonce, 1n, 32), rescuersFree: subChecked(g.rescuersFree, 1n) };
    g = actionPressure(state, g);
    const fx = applyBlindRescuerReveal(g, p, c, word);
    portals = setPortal(portals, slot, fx.portal);
    const death = markDeath(fx.game);
    g = death.game;
    em.actionPerformed(slot, action, powerSpent, atHour, powerBefore, g);
    if (fx.outcome.rescuerBlindMiss) em.rescuerRecovering(slot, fx.outcome.rescuerReadyAtHour);
    if (death.gameOver) em.gameOver(g.diedAtHour);
    em.deferralResolved(pend, atHour);
    return { g, portals };
  }

  // _applyGenericDeferredAction.
  const fx = applyActionAny(state, g, p, tp, action);
  portals = setPortal(portals, slot, fx.portal);
  const death = markDeath(actionPressure(state, fx.game));
  g = death.game;
  em.actionPerformed(slot, action, powerSpent, atHour, powerBefore, g);
  em.outcome(slot, action, fx.outcome, atHour);
  if (death.gameOver) em.gameOver(g.diedAtHour);
  em.deferralResolved(pend, atHour);
  return { g, portals };
}
