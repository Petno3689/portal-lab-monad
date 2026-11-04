/**
 * Parameters of the balance sandbox: field metadata and limits, validation,
 * persistence, JSON for copy/paste, and the game-log export.
 *
 * ── Export format (format: 1) ───────────────────────────────────────────────
 *
 * "Export game log" downloads `sandbox-game-<startedAt>.json`:
 *
 *   {
 *     "format": 1,
 *     "exportedAt": "2026-11-03T12:00:00.000Z",   // ISO-8601, real time of the export
 *     "preset": "Live v2" | "Energy ×2" | "Custom", // name selected when the game started
 *     "startedAt": "1793700000",                    // virtual nowTs of the start (decimal)
 *     "delays": true,                               // "Chain-like delays" was on at the start
 *     "config":  { "<Config field>": "<decimal>", ... },
 *     "types":   [ { "<PortalTypeParams field>": "<decimal>", "surveyPrecise": true }, ... ],  // 5, enum order
 *     "variants": { "<VariantId>": { "on": false, "<number>": "<decimal>", ... }, ... },  // rule variants
 *     "calls":   [ Call, ... ],                     // every engine call, in order — replayable
 *     "log":     [ LogEntry, ... ]                  // engine.ts state.log, verbatim
 *   }
 *
 *   Call = { "kind": "start",   "nowTs": "…", "buyFirstWord": true }
 *        | { "kind": "act",     "nowTs": "…", "slot": "3", "action": 8 }   // Action enum value
 *        | { "kind": "resolve", "nowTs": "…", "word": "<decimal, 256 bit>" }
 *        | { "kind": "sync",    "nowTs": "…", "word": "<decimal, 256 bit>" }
 *
 * Every bigint is a decimal string; enums are their integer values (numbers);
 * `surveyPrecise` stays a boolean. Replaying `calls` on the engine with the same
 * config/types/variants reproduces `log` exactly.
 *
 * "variants" (variant/variants.ts, `variantsToPlain`) was added without bumping the
 * format: an export WITHOUT the key — every export made before rule variants existed —
 * means every variant off, i.e. the mirror's rules. The page always writes it.
 *
 * The "Copy as JSON" parameter set uses the same encoding: { config, types, variants }
 * (a pasted set without "variants" turns every variant off).
 */

import type { Action, Config, PortalTypeParams } from '@shared/types';
import { InvalidConfigError, validateConfig, type LogEntry } from './engine';
import { ENERGY_X2, LIVE_V2, type Preset, type TypeTable } from './presets';
import { variantsFromPlain, variantsToPlain, type VariantSet } from './variant/variants';

// ── Parameter sets ───────────────────────────────────────────────────────────

export type ParamSet = Preset;

export const PRESET_NAMES = ['Live v2', 'Energy ×2', 'Custom'] as const;
export type PresetName = (typeof PRESET_NAMES)[number];

export function cloneParams(p: ParamSet): ParamSet {
  return {
    config: { ...p.config },
    types: p.types.map((t) => ({ ...t })) as unknown as TypeTable,
  };
}

/** The parameter set of a named preset; `Custom` has none of its own (returns Live v2). */
export function presetParams(name: PresetName): ParamSet {
  return cloneParams(name === 'Energy ×2' ? ENERGY_X2 : LIVE_V2);
}

// ── Field metadata ───────────────────────────────────────────────────────────

const U8 = 255n;
const U16 = 65_535n;
const U32 = 4_294_967_295n;

export interface FieldMeta<K extends string> {
  key: K;
  label: string;
  /** Hard limits: the Solidity type, tightened by validateConfig. */
  min: bigint;
  max: bigint;
  /** Slider range for the main parameters (defaults to min..max). */
  sliderMin?: bigint;
  sliderMax?: bigint;
  /** Shown on the main panel (otherwise under "Advanced"). */
  main?: boolean;
}

export type ConfigKey = keyof Config;
export type TypeKey = Exclude<keyof PortalTypeParams, 'surveyPrecise'>;

const cf = (
  key: ConfigKey,
  label: string,
  max: bigint,
  o: { min?: bigint; sliderMin?: bigint; sliderMax?: bigint; main?: boolean } = {},
): FieldMeta<ConfigKey> => ({ key, label, min: o.min ?? 0n, max, sliderMin: o.sliderMin, sliderMax: o.sliderMax, main: o.main });

/** Every Config field, in struct order, with the limits of its Solidity type (PortalLabTypes.sol). */
export const CONFIG_FIELDS: readonly FieldMeta<ConfigKey>[] = [
  cf('secPerHour', 'Seconds per game hour', U32, { min: 1n, sliderMax: 60n, main: true }),
  cf('longAbsenceHours', 'Long-absence hours', U16),
  cf('hpMax', 'HP max', U16, { min: 1n }),
  cf('hpStart', 'HP at start', U16, { min: 1n, sliderMax: 300n, main: true }),
  cf('hpCollapseBase', 'HP lost per collapse (base)', U16, { sliderMax: 100n, main: true }),
  cf('hpCollapsePerDeath', 'HP lost per creature lost', U16, { sliderMax: 50n, main: true }),
  cf('hpEmptyCollapse', 'HP lost, empty collapse', U16, { min: 1n }),
  cf('hpOverflowPerHour', 'HP lost per hour, 12 open', U16),
  cf('healPerCreature', 'HP healed per creature', U16),
  cf('powerMax', 'Power max', U16, { min: 1n, sliderMax: 500n, main: true }),
  cf('powerRegenPerHour', 'Power regen per hour', U16, { sliderMax: 50n, main: true }),
  cf('costToggleQuestioned', 'Cost: toggle question flag', U16, { sliderMax: 100n, main: true }),
  cf('costStabilize', 'Cost: stabilize', U16, { sliderMax: 100n, main: true }),
  cf('costDestabilize', 'Cost: destabilize', U16, { sliderMax: 100n, main: true }),
  cf('costSendObserver', 'Cost: send observer', U16, { sliderMax: 100n, main: true }),
  cf('costRecallObserver', 'Cost: recall observer', U16, { sliderMax: 100n, main: true }),
  cf('costSendRescuer', 'Cost: send rescuer', U16, { sliderMax: 100n, main: true }),
  cf('costRecallRescuer', 'Cost: recall rescuer', U16, { sliderMax: 100n, main: true }),
  cf('costEvacuate', 'Cost: evacuate', U16, { sliderMax: 100n, main: true }),
  cf('costClose', 'Cost: close', U16, { sliderMax: 100n, main: true }),
  cf('observersTotal', 'Observers', U8, { min: 1n, sliderMax: 10n, main: true }),
  cf('rescuersTotal', 'Rescuers', 4n, { min: 1n, main: true }), // MAX_RESCUERS
  cf('rescuerCooldownHours', 'Rescuer cooldown (hours)', U16, { min: 1n }),
  cf('closeStabilityBelow', 'Close allowed below stability', 100n),
  cf('closeHoursAtMost', 'Close allowed at ≤ hours left', U16),
  cf('basePressurePerHour', 'Spawn pressure per hour', U32, { sliderMax: 5000n, main: true }),
  cf('pressureRampPerHour', 'Pressure ramp per lived hour', U32, { sliderMax: 20n, main: true }),
  cf('spawnCostUnits', 'Pressure per portal', U32, { min: 1n, sliderMin: 1000n, sliderMax: 30_000n, main: true }),
  cf('closePressureBonus', 'Pressure bonus on close', U32),
  cf('rangeWidenPerHour', 'Range widening per hour', U8),
  cf('epochHours', 'Epoch length (hours)', U16, { min: 1n }),
  cf('requestTimeoutHours', 'Request timeout (hours)', U16, { min: 1n }),
  cf('outsiderTimeoutHours', 'Outsider timeout (hours)', U16, { min: 1n }),
];

const tf = (key: TypeKey, label: string, max: bigint, min = 0n): FieldMeta<TypeKey> => ({ key, label, min, max });

/** Every PortalTypeParams field except the flag, in struct order. */
export const TYPE_FIELDS: readonly FieldMeta<TypeKey>[] = [
  tf('hoursMin', 'Hours min', U16, 1n),
  tf('hoursMax', 'Hours max', U16),
  tf('degradePerHour', 'Degrade / h', U8),
  tf('energyMin', 'Energy min', 100n),
  tf('energyMax', 'Energy max', 100n),
  tf('stabilityMin', 'Stability min', 100n),
  tf('stabilityMax', 'Stability max', 100n),
  tf('creaturesMin', 'Creatures min', U8),
  tf('creaturesMax', 'Creatures max', U8),
  tf('actionMultiplierPct', 'Action mult. %', U16, 1n),
  tf('powerYieldPerHour', 'Power yield / h', U8),
];

export const TYPE_NAMES = ['Flash', 'Long-lived', 'Deaf', 'Resonant', 'Energetic'] as const;

// ── Clamping ─────────────────────────────────────────────────────────────────

export function clampTo(f: { min: bigint; max: bigint }, v: bigint): bigint {
  return v < f.min ? f.min : v > f.max ? f.max : v;
}

export type ParsedInput = { ok: true; value: bigint } | { ok: false; message: string };

/** Parse a typed integer and check it against the field's limits (no clamping). */
export function parseInput(f: { min: bigint; max: bigint }, text: string): ParsedInput {
  const t = text.trim();
  if (!/^\d+$/.test(t)) return { ok: false, message: 'whole number required' };
  const v = BigInt(t);
  if (v < f.min || v > f.max) return { ok: false, message: `must be ${f.min}–${f.max}` };
  return { ok: true, value: v };
}

// ── Validation ───────────────────────────────────────────────────────────────

/** Why the engine would refuse to start with this set (validateConfig), or null if it would not. */
export function configProblem(p: ParamSet): string | null {
  try {
    validateConfig(p.config, p.types);
    return null;
  } catch (e) {
    if (e instanceof InvalidConfigError) return e.reason;
    throw e;
  }
}

// ── JSON (bigints as decimal strings) ────────────────────────────────────────

/** JSON.stringify replacer: bigint → decimal string, everything else as is. */
const bigintReplacer = (_k: string, v: unknown): unknown => (typeof v === 'bigint' ? v.toString() : v);

export function toJson(value: unknown, space?: number): string {
  return JSON.stringify(value, bigintReplacer, space);
}

export function paramsToJson(p: ParamSet): string {
  return toJson({ config: p.config, types: p.types }, 2);
}

export type ParseResult = { ok: true; params: ParamSet } | { ok: false; error: string };

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

function readInt(v: unknown, f: FieldMeta<string>, where: string): bigint | string {
  let b: bigint;
  if (typeof v === 'string' && /^\d+$/.test(v)) b = BigInt(v);
  else if (typeof v === 'number' && Number.isInteger(v) && v >= 0) b = BigInt(v);
  else return `${where}${f.key}: expected a whole number`;
  if (b < f.min || b > f.max) return `${where}${f.key}: ${b} is outside ${f.min}–${f.max}`;
  return b;
}

/** Parse a pasted parameter set; every field must be present and inside its limits. */
export function paramsFromJson(text: string): ParseResult {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return { ok: false, error: 'not valid JSON' };
  }
  if (!isRecord(raw) || !isRecord(raw.config) || !Array.isArray(raw.types)) {
    return { ok: false, error: 'expected { "config": {...}, "types": [ ...5 entries ] }' };
  }
  const config = { ...LIVE_V2.config };
  for (const f of CONFIG_FIELDS) {
    if (!(f.key in raw.config)) return { ok: false, error: `config.${f.key}: missing` };
    const r = readInt(raw.config[f.key], f, 'config.');
    if (typeof r === 'string') return { ok: false, error: r };
    config[f.key] = r;
  }
  if (raw.types.length !== 5) return { ok: false, error: 'types: expected 5 entries' };
  const types: PortalTypeParams[] = [];
  for (let i = 0; i < 5; i++) {
    const rt: unknown = raw.types[i];
    if (!isRecord(rt)) return { ok: false, error: `types[${i}]: expected an object` };
    const t = { ...LIVE_V2.types[0] };
    for (const f of TYPE_FIELDS) {
      if (!(f.key in rt)) return { ok: false, error: `types[${i}].${f.key}: missing` };
      const r = readInt(rt[f.key], f, `types[${i}].`);
      if (typeof r === 'string') return { ok: false, error: r };
      t[f.key] = r;
    }
    if (typeof rt.surveyPrecise !== 'boolean') return { ok: false, error: `types[${i}].surveyPrecise: expected true/false` };
    t.surveyPrecise = rt.surveyPrecise;
    types.push(t);
  }
  return { ok: true, params: { config, types: types as unknown as TypeTable } };
}

/** "Copy as JSON": the parameter set and the rule variants. */
export function settingsToJson(p: ParamSet, v: VariantSet): string {
  return toJson({ config: p.config, types: p.types, variants: variantsToPlain(v) }, 2);
}

export type SettingsParse = { ok: true; params: ParamSet; variants: VariantSet } | { ok: false; error: string };

/** "Paste JSON": a parameter set with optional "variants" (absent: all off). */
export function settingsFromJson(text: string): SettingsParse {
  const r = paramsFromJson(text);
  if (!r.ok) return r;
  const raw: unknown = JSON.parse(text);
  const v = variantsFromPlain(isRecord(raw) ? raw.variants : undefined);
  if (!v.ok) return v;
  return { ok: true, params: r.params, variants: v.variants };
}

// ── Persistence (localStorage, never required) ───────────────────────────────

export const STORAGE_KEY = 'sandbox.customParams.v1';

type StorageLike = Pick<Storage, 'getItem' | 'setItem'>;

function defaultStorage(): StorageLike | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

/** The last saved custom set, or null if there is none, storage is unavailable or the data is bad. */
export function loadCustom(storage: StorageLike | null = defaultStorage()): ParamSet | null {
  try {
    const text = storage?.getItem(STORAGE_KEY);
    if (!text) return null;
    const r = paramsFromJson(text);
    return r.ok ? r.params : null;
  } catch {
    return null;
  }
}

export function saveCustom(p: ParamSet, storage: StorageLike | null = defaultStorage()): void {
  try {
    storage?.setItem(STORAGE_KEY, paramsToJson(p));
  } catch {
    // storage is optional
  }
}

// ── Game log ─────────────────────────────────────────────────────────────────

export type Call =
  | { kind: 'start'; nowTs: bigint; buyFirstWord: boolean }
  | { kind: 'act'; nowTs: bigint; slot: bigint; action: Action }
  | { kind: 'resolve'; nowTs: bigint; word: bigint }
  | { kind: 'sync'; nowTs: bigint; word: bigint };

export interface ExportInput {
  exportedAt: Date;
  preset: PresetName;
  startedAt: bigint;
  delays: boolean;
  params: ParamSet;
  calls: readonly Call[];
  log: readonly LogEntry[];
  /** The game's rule variants; omitted from the file when not given (= all off). */
  variants?: VariantSet;
}

export function exportFileName(startedAt: bigint): string {
  return `sandbox-game-${startedAt}.json`;
}

export function buildExport(i: ExportInput): string {
  return toJson(
    {
      format: 1,
      exportedAt: i.exportedAt.toISOString(),
      preset: i.preset,
      startedAt: i.startedAt,
      delays: i.delays,
      config: i.params.config,
      types: i.params.types,
      ...(i.variants ? { variants: variantsToPlain(i.variants) } : {}),
      calls: i.calls,
      log: i.log,
    },
    2,
  );
}
