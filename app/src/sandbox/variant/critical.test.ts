import { describe, expect, it } from 'vitest';
import { emptyPortal } from '@shared/effects';
import { Action, PortalStatus, PortalType, type Game, type Portal } from '@shared/types';
import { act, resolve, startGame, sync, view, type EngineState, type LogEntry } from '../engine';
import { logText } from '../format';
import { buildExport, cloneParams, paramsFromJson, presetParams, presetVariants } from '../params';
import { BEST_4_NOV, ENERGY_X2, LIVE_V2, type TypeTable } from '../presets';
import { Session } from '../session';
import { VirtualClock } from '../clock';
import { best4NovVariants, defaultVariants, variantsFromPlain, variantsToPlain, type VariantSet } from './variants';

const T0 = 1_700_000_000n;
const SPH = LIVE_V2.config.secPerHour;
const at = (hour: bigint): bigint => T0 + hour * SPH;
const W = 0x1234_5678_9abc_def0_1234_5678_9abc_def0_1234_5678_9abc_def0_1234_5678_9abc_def0n;

function withV(edit: (v: VariantSet) => void): VariantSet {
  const v = defaultVariants();
  edit(v);
  return v;
}

/** V2 with no jumps (only the degrade moves stability) and V2b for `hours`. */
const critical = (hours: bigint, v2b = true) =>
  withV((x) => {
    x.stabilityHealth = { on: true, jumpChancePct: 0n, jumpMin: 10n, jumpMax: 30n };
    x.criticalPhase = { on: v2b, hours };
  });

/** A paid start whose hand stands at hour 0, then slot 0 replaced by `p` and every other slot emptied. */
function lab(variants: VariantSet, p: Partial<Portal>, g: Partial<Game> = {}, types: TypeTable = LIVE_V2.types): EngineState {
  const s = resolve(startGame(LIVE_V2.config, types, T0, { buyFirstWord: true, variants }), W, T0 + 2n);
  const base = s.player.portals[0];
  const portals = s.player.portals.map((x, i) => (i === 0 ? { ...base, hoursToCollapse: 60n, ...p } : emptyPortal()));
  return { ...s, player: { ...s.player, portals, game: { ...s.player.game, openPortals: 1n, ...g } } };
}

/** A surveyed Flash portal (degrade 6 per hour): stability 10 → 4 → 0 at hour 2. */
const flash10: Partial<Portal> = {
  portalType: PortalType.Flash,
  surveyed: true,
  creaturesKnown: true,
  stability: 10n,
  stabilityLo: 10n,
  stabilityHi: 10n,
  energy: 50n,
  energyLo: 50n,
  energyHi: 50n,
  creatures: 2n,
  creaturesLo: 2n,
  creaturesHi: 2n,
};

const newEntries = (before: EngineState, after: EngineState): LogEntry[] => after.log.slice(before.log.length);
const ofKind = <K extends LogEntry['kind']>(es: LogEntry[], kind: K) => es.filter((e): e is Extract<LogEntry, { kind: K }> => e.kind === kind);

describe('V2b critical phase', () => {
  it('turns a portal at stability 0 critical instead of collapsing it', () => {
    const s0 = lab(critical(3n), flash10);
    const id = s0.player.portals[0].id;
    const s1 = sync(s0, 0n, at(3n));
    expect(s1.player.portals[0].status).toBe(PortalStatus.Open);
    const es = newEntries(s0, s1);
    expect(ofKind(es, 'portalCollapsed')).toEqual([]);
    expect(ofKind(es, 'portalCritical')).toEqual([{ kind: 'portalCritical', ts: at(3n).toString(), slot: '0', untilHour: '5', hour: '2' }]);
    expect(s1.player.critical).toEqual([{ portalId: id, untilHour: 5n }]);
    expect(view(s0, at(3n)).critical).toEqual([{ portalId: id, untilHour: 5n }]);
    expect(logText(ofKind(es, 'portalCritical')[0])).toContain('CRITICAL');
  });

  it('collapses exactly as a V2 early collapse once the hours run out, flagged critical', () => {
    const s0 = lab(critical(3n), flash10);
    const s1 = sync(s0, 0n, at(6n));
    const hpLost = LIVE_V2.config.hpCollapseBase + 2n * LIVE_V2.config.hpCollapsePerDeath;
    const col = ofKind(newEntries(s0, s1), 'portalCollapsed');
    expect(col).toEqual([
      { kind: 'portalCollapsed', ts: at(6n).toString(), slot: '0', deaths: '2', hpLost: hpLost.toString(), hour: '5', earlyCollapse: true, critical: true },
    ]);
    expect(s1.player.portals[0].status).toBe(PortalStatus.Empty);
    expect(s1.player.critical).toEqual([]);
    expect(s1.player.game.hp).toBe(LIVE_V2.config.hpStart - hpLost);
    expect(logText(col[0])).toContain('critical phase');
  });

  it('a Stabilize during the critical phase saves the portal', () => {
    const s1 = sync(lab(critical(3n), flash10), 0n, at(3n));
    const r = act(s1, 0n, Action.Stabilize, at(3n) + 1n);
    expect(r.result).toEqual({ kind: 'done' });
    // Stabilized to 25 at hour 3; the hour-4 step sees 19 > 0 and drops the mark.
    const s2 = sync(r.state, 0n, at(7n));
    const es = newEntries(r.state, s2);
    expect(ofKind(es, 'portalStabilized')).toEqual([{ kind: 'portalStabilized', ts: at(7n).toString(), slot: '0', hour: '4' }]);
    expect(ofKind(es, 'portalCollapsed')).toEqual([]);
    expect(s2.player.portals[0].status).toBe(PortalStatus.Open);
    expect(s2.player.critical).toEqual([]);
    // 25 − 6k reaches 0 at hour 3 + 5 = 8: a new critical phase starts there.
    const s3 = sync(s2, 0n, at(9n));
    expect(ofKind(newEntries(s2, s3), 'portalCritical')).toMatchObject([{ hour: '8', untilHour: '11' }]);
    expect(logText(ofKind(es, 'portalStabilized')[0])).toContain('left the critical phase');
  });

  it('a Close of a critical portal follows the normal rules and drops the mark', () => {
    const s1 = sync(lab(critical(3n), flash10), 0n, at(3n));
    expect(s1.player.critical).toHaveLength(1);
    const r = act(s1, 0n, Action.Close, at(3n) + 1n);
    expect(r.result).toEqual({ kind: 'done' });
    expect(r.state.player.portals[0].status).toBe(PortalStatus.Empty);
    expect(r.state.player.critical).toEqual([]);
  });

  it('a refused action keeps the marks as they were', () => {
    const s1 = sync(lab(critical(3n), flash10), 0n, at(3n));
    const r = act(s1, 7n, Action.Stabilize, at(3n) + 1n);
    expect(r.result.kind).toBe('refused');
    expect(r.state.player.critical).toEqual(s1.player.critical);
  });

  it('does nothing while V2 is off', () => {
    const only = withV((x) => (x.criticalPhase = { on: true, hours: 3n }));
    const s0 = lab(only, flash10);
    const plain = lab(defaultVariants(), flash10);
    const a = sync(s0, 0n, at(8n));
    const b = sync(plain, 0n, at(8n));
    expect(a.player.game).toEqual(b.player.game);
    expect(a.player.portals).toEqual(b.player.portals);
    expect(a.log).toEqual(b.log);
    expect(a.player.critical).toEqual([]);
  });

  it('with V2b off the V2 collapse is unchanged and no marks are kept', () => {
    const s0 = lab(critical(3n, false), flash10);
    const s1 = sync(s0, 0n, at(3n));
    expect(ofKind(newEntries(s0, s1), 'portalCollapsed')).toMatchObject([{ hour: '2', earlyCollapse: true }]);
    expect(ofKind(newEntries(s0, s1), 'portalCollapsed')[0]).not.toHaveProperty('critical');
    expect(s1.player.critical).toBeUndefined();
  });
});

describe('V2b replay', () => {
  it('an exported game with V2b on replays to the same log', () => {
    let t = 5_000_000;
    const clock = new VirtualClock(1_800_000_000n, () => t);
    let n = 0;
    const randomWord = () => BigInt.asUintN(256, BigInt(++n) * 0x9e3779b97f4a7c15f39cc0605cedc834n);
    const variants = withV((x) => {
      x.creatureArrivals = { on: true, chancePct: 30n, maxPerPortal: 6n };
      x.stabilityHealth = { on: true, jumpChancePct: 40n, jumpMin: 10n, jumpMax: 40n };
      x.criticalPhase = { on: true, hours: 3n };
      x.stabilizeExtends.on = true;
    });
    const s = new Session(cloneParams(LIVE_V2), 'Custom', false, { clock, randomWord }, variants);
    const actions = [Action.SendObserver, Action.Stabilize, Action.Stabilize, Action.Destabilize, Action.Close];
    for (let i = 0; i < 150 && !s.over; i++) {
      t += 4000;
      s.tick();
      s.requestAction(BigInt(i % 5), actions[i % actions.length]);
    }
    expect(s.log.some((e) => e.kind === 'portalCritical')).toBe(true);
    expect(s.log.some((e) => e.kind === 'portalStabilized' || (e.kind === 'portalCollapsed' && e.critical))).toBe(true);

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
    expect(j.variants.criticalPhase).toEqual({ on: true, hours: '3' });
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
    expect(st.player).toEqual(s.state.player);
  });

  it('a variants object without V2b reads as V2b off', () => {
    const plain = variantsToPlain(withV((x) => (x.stabilityHealth.on = true)));
    delete plain.criticalPhase;
    const r = variantsFromPlain(plain);
    expect(r).toEqual({ ok: true, variants: withV((x) => (x.stabilityHealth.on = true)) });
  });
});

describe('preset "Best 4 Nov"', () => {
  it('is LIVE_V2 with regen 15 and 3500 pressure per portal, and sets its variants', () => {
    expect(BEST_4_NOV.config).toEqual({ ...LIVE_V2.config, powerRegenPerHour: 15n, spawnCostUnits: 3500n });
    expect(BEST_4_NOV.types).toEqual(LIVE_V2.types);
    expect(presetParams('Best 4 Nov')).toEqual(BEST_4_NOV);
    expect(presetVariants('Best 4 Nov')).toEqual(best4NovVariants());
    const v = best4NovVariants();
    expect(v).toEqual({
      creatureArrivals: { on: true, chancePct: 15n, maxPerPortal: 6n },
      stabilityHealth: { on: true, jumpChancePct: 10n, jumpMin: 10n, jumpMax: 30n },
      criticalPhase: { on: false, hours: 2n },
      stabilizeExtends: { on: true, hours: 2n },
      rescuerTakesObserver: { on: true },
      rescuerRestAfterEvac: { on: true, hours: 2n },
      pressurePerAction: { on: true, value: 250n },
    });
    expect(presetVariants('Live v2')).toEqual(defaultVariants());
    expect(presetVariants('Energy ×2')).toEqual(defaultVariants());
    expect(presetParams('Energy ×2')).toEqual(ENERGY_X2);
  });
});
