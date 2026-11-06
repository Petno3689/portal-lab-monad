import { describe, expect, it } from 'vitest';
import { emptyPortal } from '@shared/effects';
import { PortalStatus, PortalType, type Portal } from '@shared/types';
import { resolve, startGame, sync, view, type EngineState, type LogEntry } from './engine';
import { dangerList, forecastBoard, forecastPortal } from './forecast';
import { LIVE_V2, type TypeTable } from './presets';
import { defaultVariants, type VariantSet } from './variant/variants';

/** mulberry32: a small seeded PRNG, so every run of the suite checks the same portals. */
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const int = (r: () => number, lo: number, hi: number): number => lo + Math.floor(r() * (hi - lo + 1));

const T0 = 1_700_000_000n;
const W = 0x0fed_cba9_8765_4321_0fed_cba9_8765_4321_0fed_cba9_8765_4321_0fed_cba9_8765_4321n;

/** Long epochs (one word covers the whole test), plenty of HP and no overflow drain. */
function configFor(r: () => number) {
  return { ...LIVE_V2.config, epochHours: 1000n, hpMax: 9000n, hpStart: 9000n, hpOverflowPerHour: 0n, rangeWidenPerHour: BigInt(int(r, 0, 2)) };
}

/** One portal in slot 0, every other slot empty, at hour 0 of a paid start. */
function lab(config: ReturnType<typeof configFor>, types: TypeTable, variants: VariantSet, p: Partial<Portal>): EngineState {
  const s = resolve(startGame(config, types, T0, { buyFirstWord: true, variants, forceVariantEngine: true }), W, T0 + 2n);
  const base = s.player.portals[0];
  const portals = s.player.portals.map((x, i) => (i === 0 ? { ...base, ...p } : emptyPortal()));
  return { ...s, player: { ...s.player, portals, game: { ...s.player.game, openPortals: 1n } } };
}

function randomPortal(r: () => number): Partial<Portal> {
  const creatures = BigInt(int(r, 0, 5));
  const common = {
    portalType: int(r, 0, 4) as PortalType,
    hoursToCollapse: BigInt(int(r, 1, 60)),
    observerInside: r() < 0.3,
    energy: 50n,
    energyLo: 40n,
    energyHi: 60n,
  };
  if (r() < 0.7) {
    const s = BigInt(int(r, 0, 100));
    return { ...common, surveyed: true, creaturesKnown: true, stability: s, stabilityLo: s, stabilityHi: s, creatures, creaturesLo: creatures, creaturesHi: creatures };
  }
  const lo = int(r, 0, 20);
  return {
    ...common,
    stabilityLo: 0n,
    stabilityHi: BigInt(r() < 0.3 ? 0 : lo + int(r, 0, 40)),
    creaturesLo: BigInt(lo % 3),
    creaturesHi: BigInt((lo % 3) + int(r, 0, 4)),
  };
}

const collapsesOfSlot0 = (log: readonly LogEntry[]) =>
  log.filter((e): e is Extract<LogEntry, { kind: 'portalCollapsed' }> => e.kind === 'portalCollapsed' && e.slot === '0');

describe('forecast agrees with the engine', () => {
  it('predicts the hour and the damage of the collapse when nobody acts (V2 with no jumps, V2b on or off)', () => {
    let early = 0;
    let crit = 0;
    let midCritical = 0;
    for (let i = 0; i < 300; i++) {
      const r = rng(4242 + i);
      const config = configFor(r);
      const types = LIVE_V2.types.map((t) => ({ ...t, degradePerHour: BigInt(int(r, 0, 10)) })) as unknown as TypeTable;
      const v = defaultVariants();
      v.stabilityHealth = { on: r() < 0.85, jumpChancePct: 0n, jumpMin: 10n, jumpMax: 30n };
      v.criticalPhase = { on: r() < 0.5, hours: BigInt(int(r, 1, 10)) };
      const s0 = lab(config, types, v, randomPortal(r));

      // The engine's answer: the first collapse in slot 0 (no one else can be there before it).
      const far = sync(s0, 0n, T0 + 200n * config.secPerHour);
      const col = collapsesOfSlot0(far.log)[0];
      expect(col, `state ${i}`).toBeDefined();
      const actual = BigInt(col.hour);
      if (col.earlyCollapse) early++;
      if (col.critical) crit++;

      // The forecast from any hour before it, on the engine's own view.
      const k0 = BigInt(int(r, 0, Number(actual) - 1));
      const vw = view(s0, T0 + k0 * config.secPerHour + 1n);
      expect(vw.game.hoursElapsed).toBe(k0);
      if ((vw.critical ?? []).length > 0) midCritical++;
      const f = forecastBoard(vw, config, types, v)[0];
      if (!f) throw new Error(`state ${i}: slot 0 empty at hour ${k0}`);
      expect(k0 + f.collapsesIn, `state ${i}, from hour ${k0}`).toBe(actual);
      expect(f.cause !== 'scheduled', `state ${i}`).toBe(col.earlyCollapse === true);
      expect(f.deaths.toString()).toBe(col.deaths);
      expect(f.hpLost.toString()).toBe(col.hpLost);
      expect(f.jumpsMaySpeed).toBe(false);
    }
    // The states must exercise every path.
    expect(early).toBeGreaterThan(30);
    expect(crit).toBeGreaterThan(10);
    expect(midCritical).toBeGreaterThan(3);
  }, 60_000);
});

describe('forecast details', () => {
  const v2 = (): VariantSet => {
    const v = defaultVariants();
    v.stabilityHealth.on = true;
    return v;
  };
  const surveyed = (stability: bigint, hoursToCollapse: bigint, creatures = 1n): Portal => ({
    ...emptyPortal(),
    id: 7n,
    status: PortalStatus.Open,
    portalType: PortalType.Flash, // degrade 6
    surveyed: true,
    creaturesKnown: true,
    stability,
    hoursToCollapse,
    creatures,
  });

  it('takes the sooner of the scheduled hour and stability 0 with V2, the scheduled one without', () => {
    const c = LIVE_V2.config;
    const f = forecastPortal(surveyed(13n, 10n), 0, 5n, 80n, c, LIVE_V2.types, v2());
    expect([f.collapsesIn, f.cause, f.zeroIn, f.jumpsMaySpeed]).toEqual([3n, 'stability', 3n, true]);
    const off = forecastPortal(surveyed(13n, 10n), 0, 5n, 80n, c, LIVE_V2.types, defaultVariants());
    expect([off.collapsesIn, off.cause, off.zeroIn]).toEqual([10n, 'scheduled', null]);
  });

  it('adds the critical hours with V2b and counts an existing mark down', () => {
    const v = v2();
    v.criticalPhase = { on: true, hours: 4n };
    const c = LIVE_V2.config;
    expect(forecastPortal(surveyed(13n, 20n), 0, 5n, 80n, c, LIVE_V2.types, v).collapsesIn).toBe(7n);
    const marked = forecastPortal(surveyed(0n, 20n), 0, 5n, 80n, c, LIVE_V2.types, v, [{ portalId: 7n, untilHour: 8n }]);
    expect([marked.collapsesIn, marked.level, marked.critical]).toEqual([3n, 'red', { untilHour: 8n, holds: true }]);
    // Saved by a Stabilize: the mark clears at the next step and a new phase would follow.
    const saved = forecastPortal(surveyed(13n, 20n), 0, 5n, 80n, c, LIVE_V2.types, v, [{ portalId: 7n, untilHour: 8n }]);
    expect([saved.collapsesIn, saved.critical]).toEqual([7n, { untilHour: 8n, holds: false }]);
  });

  it('colours by hours left and lists the red ones worst first', () => {
    const c = LIVE_V2.config;
    const v = defaultVariants();
    const at = (h: bigint, creatures = 1n) => forecastPortal(surveyed(80n, h, creatures), 0, 0n, 30n, c, LIVE_V2.types, v);
    expect([at(2n).level, at(3n).level, at(4n).level, at(5n).level]).toEqual(['red', 'amber', 'amber', 'none']);
    const fs = [at(2n, 1n), null, at(1n, 0n), at(2n, 3n), at(9n)].map((f, i) => (f ? { ...f, slot: i } : null));
    expect(dangerList(fs).map((f) => f.slot)).toEqual([2, 3, 0]);
    expect(at(2n, 3n).fatal).toBe(true); // 20 + 3 × 8 ≥ 30
    expect(at(2n, 0n).hpLost).toBe(c.hpEmptyCollapse);
  });
});
