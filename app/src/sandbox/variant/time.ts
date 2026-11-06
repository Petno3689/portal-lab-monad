/**
 * SANDBOX FORK of shared/src/time.ts `catchUp` (the TimeLib.sol mirror), with the
 * hourly rule variants V1 (creature arrivals) and V2 (stability as health) spliced
 * into the walk. It exists only for the balance sandbox; nothing here is on chain.
 *
 * With V1 and V2 both off this file is the mirror, line for line: the same walk, the
 * same fuse, the same commit. That is checked in time.test.ts against
 * shared/src/time.ts on random games (the engine routes to the plain mirror anyway
 * when no variant is on; the check is that the fork does not drift).
 *
 * ── What the fork adds: the hour step ───────────────────────────────────────
 *
 * The mirror walks EVENTS (collapses, births), never hours. The hourly variants need
 * one more kind of event: the HOUR STEP of each whole game hour h in (h0, hEnd] —
 * every hour the window newly reaches. Hour h0 itself belongs to the call that
 * reached it, so a split catch-up never steps an hour twice or skips one. Hours
 * beyond hEnd are not pinned to a word and get no step (the same rule as births).
 *
 * Order of everything at one hour h:
 *   1. the mirror's events at h, in the mirror's order: collapses (ties to the lower
 *      slot), births (first free slot), the collapse first at an equal hour;
 *   2. the hour step at h:
 *      a. every open portal is aged to h and re-snapshotted there (ageing composes,
 *         so this changes nothing the final `ageAll` would not do anyway);
 *      b. V2, slots ascending: the jump draw, then the early-collapse check — a
 *         surveyed portal at stability 0, an unsurveyed one at stabilityHi 0,
 *         collapses at h exactly as a scheduled collapse does (flagged early);
 *         with V2b the check goes through the critical phase instead (below);
 *      c. V1, slots ascending, over the portals still open: the arrival draw;
 *   3. births made possible at h by a slot that 2b freed (they get no step at h).
 * The segment before each event is lived by `advance` as in the mirror (power regen
 * and yield, the overflow drain while twelve are open).
 *
 * The fuse (MAX_CATCHUP_EVENTS) is kept exactly while no hourly variant is on. With
 * V1 or V2 on it is NOT applied: a fuse could stop the walk between the mirror's
 * events at an hour and that hour's step, and the next call (which starts its steps
 * at h0 + 1) would then skip that step. The sandbox has no gas limit to protect.
 *
 * ── V2b: the critical phase ─────────────────────────────────────────────────
 *
 * With V2 and V2b on, a portal meeting the V2 condition at hour step h does not
 * collapse: it gets a CRITICAL MARK { portalId, untilHour: h + hours } (hourly event
 * 'critical'). At each later hour step, in the same place of the order (2b, after the
 * jump draw): condition gone → the mark is dropped ('stabilized'); condition still
 * there and h ≥ untilHour → the portal collapses as a V2 early collapse, flagged
 * critical as well. A mark is dropped when its portal leaves its slot (any collapse
 * here; a Close or anything else that empties the slot is caught on the way in: the
 * marks of ids not open in `portals0` are discarded).
 *
 * The marks are state of the game, not of the walk: they come in as `critical0` and
 * go out as `critical` (sorted by portal id), and the engine stores them next to the
 * player record. Splitting a catch-up at b therefore hands the walk to c exactly the
 * marks the whole walk would hold at b — a split composes as before.
 *
 * Like the mirror, no exported function touches its arguments.
 */

import {
  SPAWN_DEBT_MAX,
  addChecked,
  emptyPortal,
  rescuerReadyAt,
  setRescuerReadyAt,
  subChecked,
  trunc,
} from '@shared/effects';
import { epochSeed, spawnDraw, spawnPressure, wordFor, type Collapse, type Spawn } from '@shared/time';
import {
  MAX_CATCHUP_EVENTS,
  MAX_OPEN_PORTALS,
  MAX_RESCUERS,
  PortalStatus,
  type Config,
  type Game,
  type Portal,
  type PortalType,
  type PortalTypeParams,
} from '@shared/types';
import { SALT_ARRIVAL, SALT_JUMP, amountIn, hourlyOn, rolled, variantDraw, type VariantSet } from './variants';

// Private constants of shared/src/time.ts, repeated (same values, same meaning).
const SALT_TYPE = 3n;
const SALT_HOURS = 4n;
const SALT_NAME = 5n;
const NAME_POOL_SIZE = 24n;
const NONE = (1n << 256n) - 1n;

/**
 * A collapse; `early` is true for a V2 collapse at stability 0, `critical` (present
 * only when true) for one that ends a V2b critical phase.
 */
export interface VCollapse extends Collapse {
  early: boolean;
  critical?: true;
}

/** V2b: the portal with this id is critical until `untilHour`. */
export interface CriticalMark {
  portalId: bigint;
  untilHour: bigint;
}

/** One thing an hourly variant did. */
export type HourlyEvent =
  | { kind: 'arrival'; slot: bigint; atHour: bigint }
  | { kind: 'jump'; slot: bigint; amount: bigint; atHour: bigint }
  | { kind: 'critical'; slot: bigint; untilHour: bigint; atHour: bigint }
  | { kind: 'stabilized'; slot: bigint; atHour: bigint };

/**
 * The HP a collapse of `p` costs, before the cap at the HP left — the rule of the
 * mirror's `_collapse` (shared/src/time.ts), used by `collapse` below and by the
 * board's forecast: deaths = the known creature count, else (lo + hi) / 2, plus the
 * crew inside; no deaths costs hpEmptyCollapse.
 */
export function collapseDamage(p: Portal, c: Config): { deaths: bigint; hpLost: bigint } {
  let deaths = p.creaturesKnown ? p.creatures : (p.creaturesLo + p.creaturesHi) / 2n;
  if (p.observerInside) deaths += 1n;
  if (p.rescuerInside) deaths += 1n;
  const hpLost = deaths > 0n ? c.hpCollapseBase + c.hpCollapsePerDeath * deaths : c.hpEmptyCollapse;
  return { deaths, hpLost };
}

export interface VCatchUpResult {
  game: Game;
  portals: Portal[];
  events: VCollapse[];
  spawns: Spawn[];
  /** The hourly variants' events, in walk order. */
  hourly: HourlyEvent[];
  /** V2b marks after the walk, sorted by portal id (always empty without V2 + V2b). */
  critical: CriticalMark[];
  cappedShort: boolean;
}

interface Walk {
  sph: bigint;
  h0: bigint;
  hEnd: bigint;
  hNow: bigint;
  debt0: bigint;
  aEnd: bigint;
  cursor: bigint;
  births: bigint;
  nextMature: bigint;
  openCount: bigint;
  yieldSum: bigint;
  nEv: bigint;
  colSlot: bigint;
  colNext: bigint;
  birthsOk: boolean;
  died: boolean;
  deathHour: bigint;
  oldWord: bigint;
  newWord: bigint;
  split: bigint;
  seedEpoch: bigint;
  seed: bigint;
  // ── fork ──
  v: VariantSet;
  hourly: boolean; // V1 or V2 on: hour steps, no fuse
  stepNext: bigint; // the next hour to step
  crit: Map<bigint, bigint>; // V2b: portal id → untilHour
}

/**
 * Fork of shared `catchUp`: the same arguments plus the variant set and the V2b marks
 * (last, optional: none); the result also carries the hourly events, the early flag
 * of each collapse and the marks after the walk.
 */
export function catchUpVariant(
  g0: Game,
  portals0: readonly Portal[],
  c: Config,
  types: readonly PortalTypeParams[],
  v: VariantSet,
  oldWord: bigint,
  newWord: bigint,
  storedCoveredEpochs: bigint,
  maxCoveredEpochs: bigint,
  nowTs: bigint,
  critical0: readonly CriticalMark[] = [],
): VCatchUpResult {
  if (BigInt(portals0.length) !== MAX_OPEN_PORTALS) {
    throw new Error(`catchUp: expected ${MAX_OPEN_PORTALS} portals, got ${portals0.length}`);
  }
  if (types.length !== 5) {
    throw new Error(`catchUp: expected 5 PortalTypeParams, got ${types.length}`);
  }

  const g: Game = { ...g0 };
  const portals: Portal[] = portals0.map((p) => ({ ...p }));
  const events: VCollapse[] = [];
  const spawns: Spawn[] = [];
  const hourly: HourlyEvent[] = [];
  // V2b marks of the portals still open (a mark never outlives its portal).
  const crit = new Map<bigint, bigint>();
  for (const m of critical0) {
    if (portals.some((p) => p.status !== PortalStatus.Empty && p.id === m.portalId)) crit.set(m.portalId, m.untilHour);
  }

  if (g.startedAt === 0n || g.finished || nowTs < g.startedAt) {
    return { game: g, portals, events, spawns, hourly, critical: marksOf(crit), cappedShort: false };
  }
  if (nowTs < g.lastTickAt) nowTs = g.lastTickAt;

  const w: Walk = {
    sph: c.secPerHour,
    h0: 0n,
    hEnd: 0n,
    hNow: 0n,
    debt0: g.spawnDebt,
    aEnd: 0n,
    cursor: 0n,
    births: 0n,
    nextMature: NONE,
    openCount: 0n,
    yieldSum: 0n,
    nEv: 0n,
    colSlot: 0n,
    colNext: NONE,
    birthsOk: false,
    died: false,
    deathHour: 0n,
    oldWord,
    newWord,
    split: storedCoveredEpochs,
    seedEpoch: NONE,
    seed: 0n,
    v,
    hourly: hourlyOn(v),
    stepNext: 0n,
    crit,
  };
  w.hNow = subChecked(nowTs, g.startedAt) / w.sph;
  w.h0 = subChecked(g.lastTickAt, g.startedAt) / w.sph;
  w.cursor = w.h0;
  w.stepNext = w.h0 + 1n;

  const edge = maxCoveredEpochs === 0n ? w.h0 : subChecked(maxCoveredEpochs * c.epochHours, 1n);
  w.birthsOk = maxCoveredEpochs > 0n && w.h0 <= edge && c.spawnCostUnits > 0n;
  const room = edge > w.h0 ? edge - w.h0 : 0n;
  const ahead = subChecked(w.hNow, w.h0);
  w.hEnd = w.h0 + (ahead < room ? ahead : room);
  let cappedShort = w.hEnd < w.hNow;
  w.aEnd = w.debt0 + spawnPressure(w.h0, w.hEnd, c);

  const colHour: bigint[] = [];
  for (let i = 0; i < Number(MAX_OPEN_PORTALS); i++) {
    const p = portals[i];
    if (p.status === PortalStatus.Empty) {
      colHour.push(NONE);
      continue;
    }
    w.openCount += 1n;
    w.yieldSum += types[p.portalType].powerYieldPerHour;
    colHour.push(subChecked(p.snapshotAt, g.startedAt) / w.sph + p.hoursToCollapse);
  }
  findNextCollapse(colHour, w);

  w.nextMature = w.birthsOk ? matureHour(w, c, w.h0) : NONE;
  const fuse = walk(g, portals, colHour, w, c, types, events, spawns, hourly);
  if (!w.died && !fuse) advance(g, w, c, w.hEnd);
  if (fuse) cappedShort = true;
  const hStop = fuse ? w.cursor : w.hEnd;

  let tailDeath = false;
  if (!w.died && !fuse && cappedShort && c.hpOverflowPerHour > 0n && w.openCount < MAX_OPEN_PORTALS) {
    const debtE = subChecked(w.aEnd, w.births * c.spawnCostUnits);
    const needed = (MAX_OPEN_PORTALS - w.openCount) * c.spawnCostUnits;
    if (debtE + spawnPressure(w.hEnd, w.hNow, c) >= needed) {
      const hFill = firstHour(w.hEnd, w.hEnd, w.hNow, debtE, needed, c);
      const ov = c.hpOverflowPerHour;
      const dh = hFill + (g.hp + ov - 1n) / ov;
      if (dh <= w.hNow) {
        w.died = true;
        w.deathHour = dh;
        tailDeath = true;
      }
    }
  }

  let hFreeze: bigint;
  let effTs: bigint;
  if (w.died) {
    hFreeze = tailDeath ? w.hEnd : w.deathHour > w.h0 ? w.deathHour : w.h0;
    effTs = trunc(g.startedAt + hFreeze * w.sph, 40);
    g.hp = 0n;
    g.finished = true;
    g.diedAtHour = trunc(w.deathHour, 32);
    g.hoursElapsed = trunc(w.deathHour, 32);
    g.lastTickAt = trunc(g.startedAt + w.deathHour * w.sph, 40);
  } else {
    hFreeze = hStop;
    effTs = cappedShort ? trunc(g.startedAt + hStop * w.sph, 40) : nowTs;
    g.hoursElapsed = trunc(hStop, 32);
    g.lastTickAt = effTs;
  }
  const debtOut = subChecked(available(w, c, hFreeze), w.births * c.spawnCostUnits);
  g.spawnDebt = debtOut > SPAWN_DEBT_MAX ? SPAWN_DEBT_MAX : trunc(debtOut, 32);
  g.openPortals = trunc(w.openCount, 8);

  for (let i = 0n; i < MAX_RESCUERS; i++) {
    const readyAt = rescuerReadyAt(g, i);
    if (readyAt !== 0n && readyAt <= hFreeze) {
      setRescuerReadyAt(g, i, 0n);
      if (g.rescuersFree < c.rescuersTotal) g.rescuersFree += 1n;
    }
  }

  ageAll(g, portals, c, types, w.sph, hFreeze, effTs);

  return { game: g, portals, events, spawns, hourly, critical: marksOf(w.crit), cappedShort };
}

function marksOf(crit: ReadonlyMap<bigint, bigint>): CriticalMark[] {
  return [...crit]
    .map(([portalId, untilHour]) => ({ portalId, untilHour }))
    .sort((a, b) => (a.portalId < b.portalId ? -1 : a.portalId > b.portalId ? 1 : 0));
}

/**
 * The mirror's walk with the hour step as a third kind of event, taken only when it
 * is strictly earlier than the next collapse or birth (so it follows them at an equal
 * hour). With no hourly variant this is the mirror's loop exactly.
 */
function walk(
  g: Game,
  portals: Portal[],
  colHour: bigint[],
  w: Walk,
  c: Config,
  types: readonly PortalTypeParams[],
  events: VCollapse[],
  spawns: Spawn[],
  hourly: HourlyEvent[],
): boolean {
  for (;;) {
    const ch = w.colNext;
    let bh = NONE;
    if (w.nextMature !== NONE && w.openCount < MAX_OPEN_PORTALS) {
      bh = w.nextMature > w.cursor ? w.nextMature : w.cursor;
    }
    const isCollapse = ch <= w.hEnd && ch <= bh;
    const eventHour = isCollapse ? ch : bh <= w.hEnd ? bh : NONE;

    // ── fork: the hour step ──
    if (w.hourly && w.stepNext <= w.hEnd && w.stepNext < eventHour) {
      const h = w.stepNext;
      advance(g, w, c, h);
      if (w.died) return false;
      hourStep(g, portals, colHour, w, c, types, events, hourly, h);
      if (w.died) return false;
      w.stepNext = h + 1n;
      continue;
    }

    if (eventHour === NONE) return false; // nothing more inside the window
    if (!w.hourly && w.nEv === MAX_CATCHUP_EVENTS) return true;
    advance(g, w, c, eventHour);
    if (w.died) return false;
    if (isCollapse) {
      collapse(g, portals, colHour, w, c, types, events, w.colSlot, ch, false, false);
      if (w.died) return false;
    } else {
      birth(g, portals, colHour, w, c, types, spawns, bh);
      w.nextMature = matureHour(w, c, w.nextMature);
    }
    w.nEv += 1n;
  }
}

/** Fork only: the hour step at `h` (see the order at the top of the file). */
function hourStep(
  g: Game,
  portals: Portal[],
  colHour: bigint[],
  w: Walk,
  c: Config,
  types: readonly PortalTypeParams[],
  events: VCollapse[],
  hourly: HourlyEvent[],
  h: bigint,
): void {
  if (w.openCount === 0n) return;
  const stampTs = trunc(g.startedAt + h * w.sph, 40);
  for (const p of portals) {
    if (p.status !== PortalStatus.Empty) ageOne(p, g, c, types, w.sph, h, stampTs);
  }
  const seed = seedFor(w, c, h);

  const sh = w.v.stabilityHealth;
  const cp = w.v.criticalPhase;
  if (sh.on) {
    for (let i = 0; i < portals.length; i++) {
      const p = portals[i];
      if (p.status === PortalStatus.Empty) continue;
      const d = variantDraw(seed, p.id, h, SALT_JUMP);
      if (rolled(d, sh.jumpChancePct)) {
        const amount = amountIn(d, sh.jumpMin, sh.jumpMax);
        if (amount > 0n) {
          if (p.surveyed) {
            p.stability = p.stability > amount ? p.stability - amount : 0n;
          } else {
            p.stabilityLo = p.stabilityLo > amount ? p.stabilityLo - amount : 0n;
            p.stabilityHi = p.stabilityHi > amount ? p.stabilityHi - amount : 0n;
          }
          hourly.push({ kind: 'jump', slot: BigInt(i), amount, atHour: h });
        }
      }
      const atZero = p.surveyed ? p.stability === 0n : p.stabilityHi === 0n;
      if (cp.on) {
        // V2b: the condition starts, keeps or ends a critical phase.
        const until = w.crit.get(p.id);
        if (!atZero) {
          if (until !== undefined) {
            w.crit.delete(p.id);
            hourly.push({ kind: 'stabilized', slot: BigInt(i), atHour: h });
          }
          continue;
        }
        if (until === undefined) {
          const untilHour = h + cp.hours;
          w.crit.set(p.id, untilHour);
          hourly.push({ kind: 'critical', slot: BigInt(i), untilHour, atHour: h });
          continue;
        }
        if (h < until) continue;
      }
      if (atZero) {
        collapse(g, portals, colHour, w, c, types, events, BigInt(i), h, true, cp.on);
        w.nEv += 1n;
        if (w.died) return;
      }
    }
  }

  const ca = w.v.creatureArrivals;
  if (ca.on) {
    for (let i = 0; i < portals.length; i++) {
      const p = portals[i];
      if (p.status === PortalStatus.Empty) continue;
      if (!rolled(variantDraw(seed, p.id, h, SALT_ARRIVAL), ca.chancePct)) continue;
      if (p.creaturesKnown) {
        if (p.creatures >= ca.maxPerPortal) continue;
        p.creatures += 1n;
      } else {
        if (p.creaturesHi >= ca.maxPerPortal) continue;
        p.creaturesHi += 1n;
      }
      hourly.push({ kind: 'arrival', slot: BigInt(i), atHour: h });
    }
  }
}

/** The seed of hour `h`'s epoch (the one births use), cached per epoch. */
function seedFor(w: Walk, c: Config, h: bigint): bigint {
  const epoch = h / c.epochHours;
  if (epoch !== w.seedEpoch) {
    w.seed = epochSeed(wordFor(epoch, w.oldWord, w.newWord, w.split), epoch);
    w.seedEpoch = epoch;
  }
  return w.seed;
}

function available(w: Walk, c: Config, h: bigint): bigint {
  return w.debt0 + spawnPressure(w.h0, h, c);
}

function firstHour(from: bigint, lo: bigint, hi: bigint, have: bigint, target: bigint, c: Config): bigint {
  const atLo = have + spawnPressure(from, lo, c);
  if (atLo >= target) return lo;
  const r = c.basePressurePerHour + c.pressureRampPerHour * lo;
  if (r > 0n) {
    const cap = lo + (target - atLo + r - 1n) / r;
    if (cap < hi) hi = cap;
  }
  if (subChecked(hi, lo) > 1n && have + spawnPressure(from, hi - 1n, c) < target) return hi;
  for (let it = 0; it < 64 && subChecked(hi, lo) > 1n; it++) {
    const mid = (lo + hi) / 2n;
    if (have + spawnPressure(from, mid, c) >= target) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

function matureHour(w: Walk, c: Config, from: bigint): bigint {
  const target = (w.births + 1n) * c.spawnCostUnits;
  if (w.aEnd < target) return NONE;
  return firstHour(w.h0, from, w.hEnd, w.debt0, target, c);
}

function findNextCollapse(colHour: readonly bigint[], w: Walk): void {
  let hour = NONE;
  let slot = 0n;
  for (let i = 0; i < colHour.length; i++) {
    if (colHour[i] < hour) {
      hour = colHour[i];
      slot = BigInt(i);
    }
  }
  w.colSlot = slot;
  w.colNext = hour;
}

function advance(g: Game, w: Walk, c: Config, to: bigint): void {
  if (to <= w.cursor) return;
  const delta = to - w.cursor;

  const np = g.power + (c.powerRegenPerHour + w.yieldSum) * delta;
  g.power = np > c.powerMax ? c.powerMax : trunc(np, 16);

  if (w.openCount === MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0n) {
    const ov = c.hpOverflowPerHour;
    const hToDeath = (g.hp + ov - 1n) / ov;
    if (hToDeath <= delta) {
      w.died = true;
      w.deathHour = w.cursor + hToDeath;
      w.cursor = w.deathHour;
      g.hp = 0n;
      return;
    }
    g.hp = trunc(g.hp - ov * delta, 16);
  }
  w.cursor = to;
}

/** The mirror's collapse; `early` and `critical` only label the record (the damage is the same). */
function collapse(
  g: Game,
  portals: Portal[],
  colHour: bigint[],
  w: Walk,
  c: Config,
  types: readonly PortalTypeParams[],
  events: VCollapse[],
  s: bigint,
  ch: bigint,
  early: boolean,
  critical: boolean,
): void {
  const p = portals[Number(s)];
  const { deaths, hpLost } = collapseDamage(p, c);
  const hpBefore = g.hp;
  const actualLost = hpBefore > hpLost ? hpLost : hpBefore;

  events.push({
    slot: s,
    deaths: trunc(deaths, 8),
    hpLost: trunc(actualLost, 16),
    atHour: trunc(ch, 32),
    early,
    ...(critical ? { critical: true as const } : {}),
  });
  w.crit.delete(p.id);
  g.hp = trunc(hpBefore - actualLost, 16);

  w.yieldSum = subChecked(w.yieldSum, types[p.portalType].powerYieldPerHour);
  portals[Number(s)] = emptyPortal();
  colHour[Number(s)] = NONE;
  w.openCount = subChecked(w.openCount, 1n);
  findNextCollapse(colHour, w);

  if (g.hp === 0n) {
    w.died = true;
    w.deathHour = ch;
  }
}

function birth(
  g: Game,
  portals: Portal[],
  colHour: bigint[],
  w: Walk,
  c: Config,
  types: readonly PortalTypeParams[],
  spawns: Spawn[],
  b: bigint,
): void {
  let slot = 0;
  while (portals[slot].status !== PortalStatus.Empty) slot++;

  const seed = seedFor(w, c, b);

  g.rngNonce = addChecked(g.rngNonce, 1n, 32);
  g.spawnCount = addChecked(g.spawnCount, 1n, 32);
  const spawnId = g.spawnCount;

  const portalType = Number(spawnDraw(seed, spawnId, SALT_TYPE) % 5n) as PortalType;
  const tp = types[portalType];

  const span = subChecked(tp.hoursMax, tp.hoursMin) + 1n;
  const htc = trunc(tp.hoursMin + (spawnDraw(seed, spawnId, SALT_HOURS) % span), 16);
  const nameIndex = trunc(spawnDraw(seed, spawnId, SALT_NAME) % NAME_POOL_SIZE, 8);

  const np = emptyPortal();
  np.id = trunc(spawnId, 16);
  np.portalType = portalType;
  np.nameIndex = nameIndex;
  np.narrowedOnce = false;
  np.status = PortalStatus.Open;
  np.hoursToCollapse = htc;
  np.spawnedAtHour = trunc(b, 32);
  np.snapshotAt = trunc(g.startedAt + b * w.sph, 40);
  np.energyLo = tp.energyMin;
  np.energyHi = tp.energyMax;
  np.stabilityLo = tp.stabilityMin;
  np.stabilityHi = tp.stabilityMax;
  np.creaturesLo = tp.creaturesMin;
  np.creaturesHi = tp.creaturesMax;
  portals[slot] = np;

  const ch = b + htc;
  colHour[slot] = ch;
  if (ch < w.colNext || (ch === w.colNext && BigInt(slot) < w.colSlot)) {
    w.colSlot = BigInt(slot);
    w.colNext = ch;
  }
  w.openCount += 1n;
  w.yieldSum += tp.powerYieldPerHour;
  w.births += 1n;

  spawns.push({ slot: BigInt(slot), portalType, nameIndex, atHour: trunc(b, 32) });
}

function ageAll(
  g: Game,
  portals: Portal[],
  c: Config,
  types: readonly PortalTypeParams[],
  sph: bigint,
  hTo: bigint,
  stampTs: bigint,
): void {
  for (const p of portals) {
    if (p.status !== PortalStatus.Empty) ageOne(p, g, c, types, sph, hTo, stampTs);
  }
}

/** The body of the mirror's `_ageAll` for one portal, in place. */
function ageOne(p: Portal, g: Game, c: Config, types: readonly PortalTypeParams[], sph: bigint, hTo: bigint, stampTs: bigint): void {
  const hSnap = subChecked(p.snapshotAt, g.startedAt) / sph;
  const e = subChecked(hTo, hSnap);
  if (p.surveyed) {
    const deg = types[p.portalType].degradePerHour * e;
    p.stability = p.stability > deg ? trunc(p.stability - deg, 8) : 0n;
  } else {
    const widen = c.rangeWidenPerHour * e;
    p.energyLo = p.energyLo > widen ? trunc(p.energyLo - widen, 8) : 0n;
    const eHi = p.energyHi + widen;
    p.energyHi = eHi > 100n ? 100n : trunc(eHi, 8);
    p.stabilityLo = p.stabilityLo > widen ? trunc(p.stabilityLo - widen, 8) : 0n;
    const sHi = p.stabilityHi + widen;
    p.stabilityHi = sHi > 100n ? 100n : trunc(sHi, 8);
  }
  p.hoursToCollapse = p.hoursToCollapse > e ? trunc(p.hoursToCollapse - e, 16) : 0n;
  p.snapshotAt = stampTs;
}
