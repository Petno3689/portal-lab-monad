/**
 * Rule variants of the balance sandbox — candidate rule changes the owner can
 * play-test BEFORE any contract change. SANDBOX ONLY: nothing here exists on chain,
 * in contracts/ or in shared/. The live game is not affected.
 *
 * Every variant is OFF by default. With all of them off the engine runs on the plain
 * mirror in shared/ and is the contract, step for step; with any of them on it runs
 * on the forks in this folder (time.ts, effects.ts).
 *
 *   V1 creatureArrivals      each whole game hour every open portal may gain a creature
 *   V2 stabilityHealth       each whole game hour every open portal may lose stability;
 *                            a portal whose stability reaches 0 collapses early
 *   V2b criticalPhase        (only with V2) a portal at the V2 collapse condition turns
 *                            critical for some hours first; it collapses only if the
 *                            condition still holds when they run out
 *   V3 stabilizeExtends      Stabilize also adds hours to hoursToCollapse
 *   V4 rescuerTakesObserver  Evacuate also brings the observer back
 *   V5 rescuerRestAfterEvac  after an Evacuate the rescuer rests for some hours
 *   V6 pressurePerAction     every performed action adds spawn pressure
 *
 * Randomness: every draw is keccak-based, from the seed of the epoch covering that
 * hour — `epochSeed(word, epoch)`, the seed births use, so it exists only for hours
 * covered by a pinned word — the portal id, the hour and a variant salt. No
 * Math.random: replaying a game's calls with the same config, types and variants
 * reproduces its log exactly.
 */

import { spawnDraw } from '@shared/time';
import type { FieldMeta } from '../params';

// ── The set ──────────────────────────────────────────────────────────────────

export interface VariantSet {
  creatureArrivals: { on: boolean; chancePct: bigint; maxPerPortal: bigint };
  stabilityHealth: { on: boolean; jumpChancePct: bigint; jumpMin: bigint; jumpMax: bigint };
  /** V2b: meaningful only with V2 on; with V2 off it changes nothing. */
  criticalPhase: { on: boolean; hours: bigint };
  stabilizeExtends: { on: boolean; hours: bigint };
  rescuerTakesObserver: { on: boolean };
  rescuerRestAfterEvac: { on: boolean; hours: bigint };
  /** The ticket gives V6 only a value; it gets an on flag too, like every other variant. */
  pressurePerAction: { on: boolean; value: bigint };
}

export type VariantId = keyof VariantSet;

export const VARIANT_IDS: readonly VariantId[] = [
  'creatureArrivals',
  'stabilityHealth',
  'criticalPhase',
  'stabilizeExtends',
  'rescuerTakesObserver',
  'rescuerRestAfterEvac',
  'pressurePerAction',
];

/** All variants off, with their default numbers. */
export function defaultVariants(): VariantSet {
  return {
    creatureArrivals: { on: false, chancePct: 15n, maxPerPortal: 6n },
    stabilityHealth: { on: false, jumpChancePct: 10n, jumpMin: 10n, jumpMax: 30n },
    criticalPhase: { on: false, hours: 2n },
    stabilizeExtends: { on: false, hours: 3n },
    rescuerTakesObserver: { on: false },
    rescuerRestAfterEvac: { on: false, hours: 4n },
    pressurePerAction: { on: false, value: 0n },
  };
}

export const DEFAULT_VARIANTS: VariantSet = defaultVariants();

/**
 * The variants of the "Best 4 Nov" preset: the owner's best settings after the
 * play-test of 4 November 2026 (V1–V6 on, V2b off).
 */
export function best4NovVariants(): VariantSet {
  return {
    creatureArrivals: { on: true, chancePct: 15n, maxPerPortal: 6n },
    stabilityHealth: { on: true, jumpChancePct: 10n, jumpMin: 10n, jumpMax: 30n },
    criticalPhase: { on: false, hours: 2n },
    stabilizeExtends: { on: true, hours: 2n },
    rescuerTakesObserver: { on: true },
    rescuerRestAfterEvac: { on: true, hours: 2n },
    pressurePerAction: { on: true, value: 250n },
  };
}

export function cloneVariants(v: VariantSet): VariantSet {
  return {
    creatureArrivals: { ...v.creatureArrivals },
    stabilityHealth: { ...v.stabilityHealth },
    criticalPhase: { ...v.criticalPhase },
    stabilizeExtends: { ...v.stabilizeExtends },
    rescuerTakesObserver: { ...v.rescuerTakesObserver },
    rescuerRestAfterEvac: { ...v.rescuerRestAfterEvac },
    pressurePerAction: { ...v.pressurePerAction },
  };
}

export function anyVariantOn(v: VariantSet): boolean {
  return VARIANT_IDS.some((id) => v[id].on);
}

/** Whether the catch-up walk needs a step at every whole hour (V1 or V2). */
export function hourlyOn(v: VariantSet): boolean {
  return v.creatureArrivals.on || v.stabilityHealth.on;
}

// ── Metadata (UI, validation, JSON) ──────────────────────────────────────────

export interface VariantMeta {
  id: VariantId;
  label: string;
  description: string;
  /** Every number of the variant, with its hard limits. */
  fields: readonly FieldMeta<string>[];
}

const num = (key: string, label: string, min: bigint, max: bigint): FieldMeta<string> => ({ key, label, min, max, main: true });

export const VARIANT_META: readonly VariantMeta[] = [
  {
    id: 'creatureArrivals',
    label: 'V1 · Creature arrivals',
    description: 'Each game hour every open portal may gain a creature (unsurveyed: the upper bound grows).',
    fields: [num('chancePct', 'Chance per hour, %', 0n, 100n), num('maxPerPortal', 'Max per portal', 1n, 255n)],
  },
  {
    id: 'stabilityHealth',
    label: 'V2 · Stability as health',
    description: 'Each game hour every open portal may lose stability; at 0 it collapses early.',
    fields: [num('jumpChancePct', 'Jump chance per hour, %', 0n, 100n), num('jumpMin', 'Jump min', 0n, 100n), num('jumpMax', 'Jump max', 0n, 100n)],
  },
  {
    id: 'criticalPhase',
    label: 'V2b · Critical phase',
    description: 'With V2: a portal at stability 0 turns critical instead of collapsing; Stabilize in time saves it, otherwise it collapses when the hours run out.',
    fields: [num('hours', 'Critical hours', 1n, 10n)],
  },
  {
    id: 'stabilizeExtends',
    label: 'V3 · Stabilize extends life',
    description: 'Stabilize also adds hours to the time left before collapse.',
    fields: [num('hours', 'Hours added', 0n, 255n)],
  },
  {
    id: 'rescuerTakesObserver',
    label: 'V4 · Rescuer brings the observer',
    description: 'Evacuate also brings back an observer who is inside.',
    fields: [],
  },
  {
    id: 'rescuerRestAfterEvac',
    label: 'V5 · Rescuer rests after evacuation',
    description: 'After every Evacuate the rescuer is not free for some hours.',
    fields: [num('hours', 'Rest hours', 0n, 255n)],
  },
  {
    id: 'pressurePerAction',
    label: 'V6 · Pressure per action',
    description: 'Every performed action adds spawn pressure (capped like the close bonus).',
    fields: [num('value', 'Pressure per action', 0n, 100_000n)],
  },
];

type Numbers = Record<string, bigint | boolean>;

export function variantNumber(v: VariantSet, id: VariantId, key: string): bigint {
  return (v[id] as Numbers)[key] as bigint;
}

/** A copy of `v` with one number or the on flag of one variant replaced. */
export function withVariant(v: VariantSet, id: VariantId, key: string, value: bigint | boolean): VariantSet {
  const next = cloneVariants(v);
  (next[id] as Numbers)[key] = value;
  return next;
}

/** Why the set cannot start a game, or null. Ranges are checked only for a variant that is on. */
export function variantProblem(v: VariantSet): string | null {
  for (const m of VARIANT_META) {
    for (const f of m.fields) {
      const x = variantNumber(v, m.id, f.key);
      if (x < f.min || x > f.max) return `${m.label}: ${f.label} must be ${f.min}–${f.max}`;
    }
  }
  const sh = v.stabilityHealth;
  if (sh.on && sh.jumpMin > sh.jumpMax) return 'V2 · Stability as health: jump min must not exceed jump max';
  return null;
}

// ── JSON ─────────────────────────────────────────────────────────────────────

/** Plain JSON object: bigints as decimal strings, flags as booleans. */
export function variantsToPlain(v: VariantSet): Record<string, Record<string, string | boolean>> {
  const out: Record<string, Record<string, string | boolean>> = {};
  for (const id of VARIANT_IDS) {
    const o: Record<string, string | boolean> = {};
    for (const [k, x] of Object.entries(v[id])) o[k] = typeof x === 'bigint' ? x.toString() : (x as boolean);
    out[id] = o;
  }
  return out;
}

export type VariantParse = { ok: true; variants: VariantSet } | { ok: false; error: string };

const isRecord = (x: unknown): x is Record<string, unknown> => typeof x === 'object' && x !== null && !Array.isArray(x);

/**
 * Read a `variants` object. `undefined` (absent) means all off. A listed variant may
 * omit fields (they keep their defaults); a present field must be well-formed and
 * inside its limits.
 */
export function variantsFromPlain(raw: unknown): VariantParse {
  const v = defaultVariants();
  if (raw === undefined) return { ok: true, variants: v };
  if (!isRecord(raw)) return { ok: false, error: 'variants: expected an object' };
  for (const m of VARIANT_META) {
    const r = raw[m.id];
    if (r === undefined) continue;
    if (!isRecord(r)) return { ok: false, error: `variants.${m.id}: expected an object` };
    if (r.on !== undefined) {
      if (typeof r.on !== 'boolean') return { ok: false, error: `variants.${m.id}.on: expected true/false` };
      (v[m.id] as Numbers).on = r.on;
    }
    for (const f of m.fields) {
      const x = r[f.key];
      if (x === undefined) continue;
      let b: bigint;
      if (typeof x === 'string' && /^\d+$/.test(x)) b = BigInt(x);
      else if (typeof x === 'number' && Number.isInteger(x) && x >= 0) b = BigInt(x);
      else return { ok: false, error: `variants.${m.id}.${f.key}: expected a whole number` };
      if (b < f.min || b > f.max) return { ok: false, error: `variants.${m.id}.${f.key}: ${b} is outside ${f.min}–${f.max}` };
      (v[m.id] as Numbers)[f.key] = b;
    }
  }
  return { ok: true, variants: v };
}

// ── Persistence (localStorage, never required) ───────────────────────────────

export const VARIANTS_STORAGE_KEY = 'sandbox.variants.v1';

type StorageLike = Pick<Storage, 'getItem' | 'setItem'>;

function defaultStorage(): StorageLike | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function loadVariants(storage: StorageLike | null = defaultStorage()): VariantSet | null {
  try {
    const text = storage?.getItem(VARIANTS_STORAGE_KEY);
    if (!text) return null;
    const r = variantsFromPlain(JSON.parse(text));
    return r.ok ? r.variants : null;
  } catch {
    return null;
  }
}

export function saveVariants(v: VariantSet, storage: StorageLike | null = defaultStorage()): void {
  try {
    storage?.setItem(VARIANTS_STORAGE_KEY, JSON.stringify(variantsToPlain(v)));
  } catch {
    // storage is optional
  }
}

// ── Deterministic draws ──────────────────────────────────────────────────────

/** Variant salts; the survey uses 0/1/2, the blind rescue 3 and the spawn draws 3/4/5. */
export const SALT_JUMP = 16n;
export const SALT_ARRIVAL = 17n;

const drawCache = new Map<string, bigint>();
const DRAW_CACHE_MAX = 200_000;

/**
 * One variant draw: `spawnDraw(seed, portalId << 32 | hour, salt)`, i.e.
 * keccak256(abi.encode(seed, portalId << 32 | hour, salt)) with `seed` the epoch seed
 * of `hour`. Memoised: the page re-projects the same hours several times a second.
 */
export function variantDraw(seed: bigint, portalId: bigint, hour: bigint, salt: bigint): bigint {
  const key = `${seed}:${portalId}:${hour}:${salt}`;
  const hit = drawCache.get(key);
  if (hit !== undefined) return hit;
  const d = spawnDraw(seed, (portalId << 32n) | hour, salt);
  if (drawCache.size >= DRAW_CACHE_MAX) drawCache.clear();
  drawCache.set(key, d);
  return d;
}

/** A percentage roll: true with probability pct / 100. */
export const rolled = (d: bigint, pct: bigint): boolean => d % 100n < pct;

/** A value in [lo, hi] from the upper half of the draw (the lower half decided the roll). */
export const amountIn = (d: bigint, lo: bigint, hi: bigint): bigint => lo + ((d >> 128n) % (hi - lo + 1n));
