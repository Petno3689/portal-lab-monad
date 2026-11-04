import { describe, expect, it } from 'vitest';
import { emptyPortal } from '@shared/effects';
import { Action, PortalStatus, PortalType, type Game, type Portal } from '@shared/types';
import { act, resolve, startGame, sync, view, type EngineState, type LogEntry } from '../engine';
import { energyOf, logText, stabilityOf } from '../format';
import { buildExport, cloneParams, paramsFromJson, settingsFromJson, settingsToJson } from '../params';
import { LIVE_V2, type TypeTable } from '../presets';
import { Session } from '../session';
import { VirtualClock } from '../clock';
import {
  VARIANTS_STORAGE_KEY,
  anyVariantOn,
  defaultVariants,
  loadVariants,
  saveVariants,
  variantProblem,
  variantsFromPlain,
  variantsToPlain,
  type VariantSet,
} from './variants';

const T0 = 1_700_000_000n;
const SPH = LIVE_V2.config.secPerHour;
const at = (hour: bigint): bigint => T0 + hour * SPH;
const W = 0x1234_5678_9abc_def0_1234_5678_9abc_def0_1234_5678_9abc_def0_1234_5678_9abc_def0n;

/** Types with no degrade and no range widening, so only the variant moves stability. */
const STILL: TypeTable = LIVE_V2.types.map((t) => ({ ...t, degradePerHour: 0n })) as unknown as TypeTable;
const STILL_CONFIG = { ...LIVE_V2.config, rangeWidenPerHour: 0n };

function withV(edit: (v: VariantSet) => void): VariantSet {
  const v = defaultVariants();
  edit(v);
  return v;
}

/**
 * A paid start whose hand stands at hour 0, then slot 0 replaced by `p` and every other
 * slot emptied — one portal to watch. Births resume only around hour 10.
 */
function lab(variants: VariantSet, p: Partial<Portal>, g: Partial<Game> = {}, types: TypeTable = STILL, config = STILL_CONFIG): EngineState {
  const s = resolve(startGame(config, types, T0, { buyFirstWord: true, variants }), W, T0 + 2n);
  const base = s.player.portals[0];
  const portals = s.player.portals.map((x, i) => (i === 0 ? { ...base, hoursToCollapse: 60n, ...p } : emptyPortal()));
  return { ...s, player: { ...s.player, portals, game: { ...s.player.game, openPortals: 1n, ...g } } };
}

const surveyed = (stability: bigint, creatures: bigint): Partial<Portal> => ({
  surveyed: true,
  creaturesKnown: true,
  stability,
  stabilityLo: stability,
  stabilityHi: stability,
  energy: 50n,
  energyLo: 50n,
  energyHi: 50n,
  creatures,
  creaturesLo: creatures,
  creaturesHi: creatures,
});

const newEntries = (before: EngineState, after: EngineState): LogEntry[] => after.log.slice(before.log.length);
const ofKind = <K extends LogEntry['kind']>(es: LogEntry[], kind: K) => es.filter((e): e is Extract<LogEntry, { kind: K }> => e.kind === kind);

describe('routing', () => {
  it('runs on the mirror unless a variant is on', () => {
    expect(startGame(LIVE_V2.config, LIVE_V2.types, T0, { buyFirstWord: false }).variants).toBeUndefined();
    expect(startGame(LIVE_V2.config, LIVE_V2.types, T0, { buyFirstWord: false, variants: defaultVariants() }).variants).toBeUndefined();
    const v = withV((x) => (x.rescuerTakesObserver.on = true));
    expect(startGame(LIVE_V2.config, LIVE_V2.types, T0, { buyFirstWord: false, variants: v }).variants).toEqual(v);
    expect(anyVariantOn(defaultVariants())).toBe(false);
  });
});

describe('V1 creature arrivals', () => {
  it('adds one creature per hour to a known count, up to the cap, and logs each', () => {
    const v = withV((x) => (x.creatureArrivals = { on: true, chancePct: 100n, maxPerPortal: 5n }));
    const s0 = lab(v, surveyed(60n, 2n));
    expect(view(s0, at(2n)).portals[0].creatures).toBe(4n);
    const s1 = sync(s0, 0n, at(6n));
    const p = s1.player.portals[0];
    expect(p.creatures).toBe(5n); // 2 + 3, capped at 5
    expect(p.creaturesKnown).toBe(true);
    expect(ofKind(newEntries(s0, s1), 'creatureArrived').map((e) => [e.slot, e.hour])).toEqual([
      ['0', '1'],
      ['0', '2'],
      ['0', '3'],
    ]);
  });

  it('raises only the upper bound of an unknown count; chance 0 does nothing', () => {
    const v = withV((x) => (x.creatureArrivals = { on: true, chancePct: 100n, maxPerPortal: 6n }));
    const s0 = lab(v, { creaturesLo: 1n, creaturesHi: 3n });
    const p = view(s0, at(2n)).portals[0];
    expect([p.creaturesLo, p.creaturesHi, p.creaturesKnown]).toEqual([1n, 5n, false]);
    expect(view(s0, at(9n)).portals[0].creaturesHi).toBe(6n);

    const off = withV((x) => (x.creatureArrivals = { on: true, chancePct: 0n, maxPerPortal: 6n }));
    const q = lab(off, { creaturesLo: 1n, creaturesHi: 3n });
    expect(view(q, at(9n)).portals[0].creaturesHi).toBe(3n);
  });
});

describe('V2 stability as health', () => {
  const v = withV((x) => (x.stabilityHealth = { on: true, jumpChancePct: 100n, jumpMin: 10n, jumpMax: 10n }));

  it('drops a surveyed portal by the jump each hour and collapses it early at 0', () => {
    const s0 = lab(v, surveyed(35n, 2n));
    expect(view(s0, at(1n)).portals[0].stability).toBe(25n);
    expect(view(s0, at(3n)).portals[0].stability).toBe(5n);
    const s1 = sync(s0, 0n, at(5n));
    expect(s1.player.portals[0].status).toBe(PortalStatus.Empty);
    const es = newEntries(s0, s1);
    expect(ofKind(es, 'stabilityJump').map((e) => [e.hour, e.amount])).toEqual([
      ['1', '10'],
      ['2', '10'],
      ['3', '10'],
      ['4', '10'],
    ]);
    // Damage exactly as a scheduled collapse: base + perDeath × deaths.
    const hpLost = LIVE_V2.config.hpCollapseBase + 2n * LIVE_V2.config.hpCollapsePerDeath;
    expect(ofKind(es, 'portalCollapsed')).toEqual([
      { kind: 'portalCollapsed', ts: at(5n).toString(), slot: '0', deaths: '2', hpLost: hpLost.toString(), hour: '4', earlyCollapse: true },
    ]);
    expect(s1.player.game.hp).toBe(LIVE_V2.config.hpStart - hpLost);
    expect(logText(ofKind(es, 'portalCollapsed')[0])).toContain('EARLY');
  });

  it('drops both bounds of an unsurveyed portal, which collapses when the upper bound reaches 0', () => {
    const s0 = lab(v, { stabilityLo: 15n, stabilityHi: 25n, creaturesLo: 0n, creaturesHi: 2n });
    const p1 = view(s0, at(1n)).portals[0];
    expect([p1.stabilityLo, p1.stabilityHi]).toEqual([5n, 15n]);
    const p2 = view(s0, at(2n)).portals[0];
    expect([p2.stabilityLo, p2.stabilityHi]).toEqual([0n, 5n]);
    const s1 = sync(s0, 0n, at(3n));
    const col = ofKind(newEntries(s0, s1), 'portalCollapsed');
    expect(col).toHaveLength(1);
    expect(col[0]).toMatchObject({ hour: '3', deaths: '1', earlyCollapse: true }); // (0 + 2) / 2 deaths
  });

  it('collapses a surveyed portal that degrades to 0 even with no jumps; off, it lives on', () => {
    const noJumps = withV((x) => (x.stabilityHealth = { on: true, jumpChancePct: 0n, jumpMin: 10n, jumpMax: 30n }));
    // Flash degrades 6 per hour: 10 → 4 → 0 at hour 2.
    const s0 = lab(noJumps, { ...surveyed(10n, 1n), portalType: PortalType.Flash }, {}, LIVE_V2.types, LIVE_V2.config);
    const s1 = sync(s0, 0n, at(3n));
    expect(ofKind(newEntries(s0, s1), 'portalCollapsed')).toMatchObject([{ hour: '2', earlyCollapse: true }]);
    expect(ofKind(newEntries(s0, s1), 'stabilityJump')).toEqual([]);

    const plain = lab(defaultVariants(), { ...surveyed(10n, 1n), portalType: PortalType.Flash }, {}, LIVE_V2.types, LIVE_V2.config);
    expect(plain.variants).toBeUndefined();
    expect(view(plain, at(3n)).portals[0].status).toBe(PortalStatus.Open);
  });
});

describe('V3 stabilize extends', () => {
  it('adds the hours to hoursToCollapse', () => {
    const v = withV((x) => (x.stabilizeExtends = { on: true, hours: 3n }));
    const s0 = lab(v, { ...surveyed(50n, 1n), hoursToCollapse: 20n });
    const r = act(s0, 0n, Action.Stabilize, at(0n) + 3n);
    expect(r.result).toEqual({ kind: 'done' });
    expect(r.state.player.portals[0].hoursToCollapse).toBe(23n);
    expect(r.state.player.portals[0].stability).toBe(75n);
  });
});

describe('V4 rescuer takes the observer', () => {
  it('Evacuate brings the observer back too', () => {
    const v = withV((x) => (x.rescuerTakesObserver.on = true));
    const s0 = lab(v, { ...surveyed(50n, 2n), observerInside: true, rescuerInside: true }, { observersFree: 2n, rescuersFree: 1n });
    const r = act(s0, 0n, Action.Evacuate, at(0n) + 3n);
    expect(r.result).toEqual({ kind: 'done' });
    const p = r.state.player.portals[0];
    expect([p.observerInside, p.rescuerInside, p.creatures]).toEqual([false, false, 0n]);
    expect(r.state.player.game.observersFree).toBe(3n);
    expect(r.state.player.game.rescuersFree).toBe(2n);
  });
});

describe('V5 rescuer rests after an evacuation', () => {
  it('keeps the rescuer out of the pool for the rest hours, then frees it', () => {
    const v = withV((x) => (x.rescuerRestAfterEvac = { on: true, hours: 4n }));
    const s0 = lab(v, { ...surveyed(50n, 2n), rescuerInside: true }, { rescuersFree: 1n });
    const s1 = sync(s0, 0n, at(1n));
    const r = act(s1, 0n, Action.Evacuate, at(1n) + 1n);
    expect(r.result).toEqual({ kind: 'done' });
    const g = r.state.player.game;
    expect(g.rescuersFree).toBe(1n);
    expect(g.rescuerReadyAt0).toBe(5n);
    const es = newEntries(s1, r.state);
    expect(es.map((e) => e.kind)).toEqual(['actionPerformed', 'creaturesRescued', 'rescuerRecovering']);
    expect(ofKind(es, 'rescuerRecovering')[0]).toMatchObject({ slot: '0', readyAtHour: '5' });
    expect(view(r.state, at(4n)).game.rescuersFree).toBe(1n);
    expect(view(r.state, at(5n)).game.rescuersFree).toBe(2n);
  });
});

describe('V6 pressure per action', () => {
  it('every performed action adds the value to spawnDebt; a refusal adds nothing', () => {
    const v = withV((x) => (x.pressurePerAction = { on: true, value: 700n }));
    const s0 = lab(v, surveyed(50n, 1n));
    const debt0 = s0.player.game.spawnDebt;
    const r = act(s0, 0n, Action.ToggleQuestioned, at(0n) + 3n);
    expect(r.state.player.game.spawnDebt).toBe(debt0 + 700n);
    const refused = act(r.state, 5n, Action.ToggleQuestioned, at(0n) + 4n);
    expect(refused.result.kind).toBe('refused');
    expect(refused.state.player.game.spawnDebt).toBe(debt0 + 700n);
    // The two-phase survey commit is a performed action too.
    const fresh = lab(v, {});
    const c = act(fresh, 0n, Action.SendObserver, at(0n) + 3n);
    expect(c.result).toEqual({ kind: 'deferred' });
    expect(c.state.player.game.spawnDebt).toBe(fresh.player.game.spawnDebt + 700n);
  });
});

describe('determinism and replay', () => {
  it('an exported game with variants on replays to the same log', () => {
    let t = 5_000_000;
    const clock = new VirtualClock(1_800_000_000n, () => t);
    let n = 0;
    const randomWord = () => BigInt.asUintN(256, BigInt(++n) * 0x9e3779b97f4a7c15f39cc0605cedc834n);
    const variants = withV((x) => {
      x.creatureArrivals = { on: true, chancePct: 40n, maxPerPortal: 6n };
      x.stabilityHealth = { on: true, jumpChancePct: 30n, jumpMin: 5n, jumpMax: 25n };
      x.stabilizeExtends.on = true;
      x.rescuerTakesObserver.on = true;
      x.rescuerRestAfterEvac.on = true;
      x.pressurePerAction = { on: true, value: 300n };
    });
    const s = new Session(cloneParams(LIVE_V2), 'Custom', false, { clock, randomWord }, variants);
    const actions = [Action.SendObserver, Action.Stabilize, Action.SendRescuer, Action.Evacuate, Action.Destabilize, Action.Close];
    for (let i = 0; i < 120 && !s.over; i++) {
      t += 4000;
      s.tick();
      s.requestAction(BigInt(i % 4), actions[i % actions.length]);
    }
    expect(s.log.some((e) => e.kind === 'creatureArrived')).toBe(true);
    expect(s.log.some((e) => e.kind === 'stabilityJump')).toBe(true);

    const text = buildExport({
      exportedAt: new Date(0),
      preset: s.preset,
      startedAt: s.startedAt,
      delays: false,
      params: s.params,
      variants: s.variants,
      calls: s.calls,
      log: s.log,
    });
    const j = JSON.parse(text);
    expect(Object.keys(j)).toEqual(['format', 'exportedAt', 'preset', 'startedAt', 'delays', 'config', 'types', 'variants', 'calls', 'log']);
    expect(j.format).toBe(1);

    const params = paramsFromJson(JSON.stringify({ config: j.config, types: j.types }));
    const vs = variantsFromPlain(j.variants);
    if (!params.ok || !vs.ok) throw new Error('export does not parse');
    expect(vs.variants).toEqual(variants);
    type RawCall = { kind: string; nowTs: string; buyFirstWord?: boolean; slot?: string; action?: Action; word?: string };
    const calls = j.calls as RawCall[];
    let st = startGame(params.params.config, params.params.types, BigInt(calls[0].nowTs), { buyFirstWord: calls[0].buyFirstWord === true, variants: vs.variants });
    for (const c of calls.slice(1)) {
      const ts = BigInt(c.nowTs);
      if (c.kind === 'act') st = act(st, BigInt(c.slot!), c.action!, ts).state;
      else if (c.kind === 'resolve') st = resolve(st, BigInt(c.word!), ts);
      else st = sync(st, BigInt(c.word!), ts);
    }
    expect(JSON.parse(JSON.stringify(st.log))).toEqual(j.log);
  });

  it('an export without "variants" reads as all off', () => {
    expect(variantsFromPlain(undefined)).toEqual({ ok: true, variants: defaultVariants() });
  });
});

describe('variant settings', () => {
  it('round-trips through "Copy as JSON" and reads a set without variants as all off', () => {
    const p = cloneParams(LIVE_V2);
    p.config.costClose = 30n;
    const v = withV((x) => (x.stabilityHealth = { on: true, jumpChancePct: 25n, jumpMin: 3n, jumpMax: 9n }));
    const r = settingsFromJson(settingsToJson(p, v));
    expect(r).toEqual({ ok: true, params: p, variants: v });
    const bare = JSON.parse(settingsToJson(p, v));
    delete bare.variants;
    expect(settingsFromJson(JSON.stringify(bare))).toEqual({ ok: true, params: p, variants: defaultVariants() });
    const bad = JSON.parse(settingsToJson(p, v));
    bad.variants.creatureArrivals.chancePct = '101';
    expect(settingsFromJson(JSON.stringify(bad))).toMatchObject({ ok: false, error: expect.stringContaining('chancePct') });
  });

  it('flags jumpMin > jumpMax only for a variant that is on, and out-of-range numbers', () => {
    expect(variantProblem(defaultVariants())).toBeNull();
    const v = withV((x) => (x.stabilityHealth = { on: false, jumpChancePct: 10n, jumpMin: 40n, jumpMax: 20n }));
    expect(variantProblem(v)).toBeNull();
    v.stabilityHealth.on = true;
    expect(variantProblem(v)).toMatch(/jump min/);
    expect(variantProblem(withV((x) => (x.creatureArrivals.maxPerPortal = 0n)))).toMatch(/Max per portal/);
  });

  it('persists, and survives missing, throwing or garbage storage', () => {
    const m = new Map<string, string>();
    const mem = { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, x: string) => void m.set(k, x) };
    const v = withV((x) => (x.rescuerRestAfterEvac = { on: true, hours: 7n }));
    saveVariants(v, mem);
    expect(m.has(VARIANTS_STORAGE_KEY)).toBe(true);
    expect(loadVariants(mem)).toEqual(v);
    expect(loadVariants(null)).toBeNull();
    const broken = {
      getItem: () => {
        throw new Error('blocked');
      },
      setItem: () => {
        throw new Error('quota');
      },
    };
    expect(loadVariants(broken)).toBeNull();
    expect(() => saveVariants(v, broken)).not.toThrow();
    m.set(VARIANTS_STORAGE_KEY, '{"creatureArrivals":{"on":"yes"}}');
    expect(loadVariants(mem)).toBeNull();
    expect(variantsToPlain(v).rescuerRestAfterEvac).toEqual({ on: true, hours: '7' });
  });
});

describe('display', () => {
  it('shows the live exact stability and energy of a surveyed portal, ranges otherwise', () => {
    const p: Portal = { ...emptyPortal(), surveyed: true, stability: 12n, stabilityLo: 40n, stabilityHi: 40n, energy: 70n, energyLo: 60n, energyHi: 60n };
    expect(stabilityOf(p)).toBe('12');
    expect(energyOf(p)).toBe('70');
    const q: Portal = { ...emptyPortal(), stabilityLo: 10n, stabilityHi: 30n, energyLo: 5n, energyHi: 5n };
    expect(stabilityOf(q)).toBe('10–30');
    expect(energyOf(q)).toBe('5');
  });
});
