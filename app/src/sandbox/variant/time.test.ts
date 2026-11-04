import { describe, expect, it } from 'vitest';
import { check } from '@shared/rules';
import { catchUp } from '@shared/time';
import { Action, PortalStatus, Refusal } from '@shared/types';
import { act, needsWord, resolve, startGame, sync, view, type EngineState } from '../engine';
import { ENERGY_X2, LIVE_V2, type Preset } from '../presets';
import { catchUpVariant, type VCatchUpResult } from './time';
import { defaultVariants, type VariantSet } from './variants';

/** mulberry32: a small seeded PRNG, so every run of the suite plays the same games. */
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

function word(r: () => number): bigint {
  let w = 0n;
  for (let i = 0; i < 8; i++) w = (w << 32n) | BigInt(Math.floor(r() * 4294967296));
  return w;
}

const T0 = 1_700_000_000n;
const ACTIONS = [
  Action.ToggleQuestioned,
  Action.Stabilize,
  Action.Destabilize,
  Action.SendObserver,
  Action.RecallObserver,
  Action.SendRescuer,
  Action.RecallRescuer,
  Action.Evacuate,
  Action.Close,
];

/** A few configurations: the live one, more energy, short epochs and dense spawns (crossings, fuses). */
function presetFor(i: number): Preset {
  const k = i % 4;
  if (k === 0) return LIVE_V2;
  if (k === 1) return ENERGY_X2;
  if (k === 2) return { config: { ...LIVE_V2.config, epochHours: 3n, secPerHour: 5n, hpStart: 100n }, types: LIVE_V2.types };
  // Dense spawns and no overflow drain: a full lab churns, so long windows blow the fuse.
  return {
    config: { ...LIVE_V2.config, spawnCostUnits: 1000n, hpMax: 5000n, hpStart: 5000n, hpCollapseBase: 1n, hpCollapsePerDeath: 4n, hpEmptyCollapse: 1n, hpOverflowPerHour: 0n },
    types: LIVE_V2.types,
  };
}

type Call =
  | { kind: 'act'; nowTs: bigint; slot: bigint; action: Action }
  | { kind: 'resolve'; nowTs: bigint; word: bigint }
  | { kind: 'sync'; nowTs: bigint; word: bigint };

/**
 * The scripted policy: time moves on by a few seconds (sometimes by a long absence);
 * an outstanding deferral is resolved, a capped world is synced, otherwise mostly an
 * allowed action on an open portal, sometimes any action on any slot.
 */
function nextCall(s: EngineState, r: () => number, nowTs: bigint): Call {
  if (s.player.pending.active) return { kind: 'resolve', nowTs, word: word(r) };
  if (needsWord(s, nowTs)) return { kind: 'sync', nowTs, word: word(r) };
  if (r() < 0.75) {
    const v = view(s, nowTs);
    const options: [bigint, Action][] = [];
    v.portals.forEach((p, i) => {
      if (p.status === PortalStatus.Empty) return;
      for (const a of ACTIONS) if (check(v.game, p, s.config, BigInt(i), a) === Refusal.None) options.push([BigInt(i), a]);
    });
    if (options.length > 0) {
      const [slot, action] = options[int(r, 0, options.length - 1)];
      return { kind: 'act', nowTs, slot, action };
    }
  }
  return { kind: 'act', nowTs, slot: BigInt(int(r, 0, 12)), action: ACTIONS[int(r, 0, 8)] };
}

function apply(s: EngineState, c: Call): EngineState {
  if (c.kind === 'act') return act(s, c.slot, c.action, c.nowTs).state;
  if (c.kind === 'resolve') return resolve(s, c.word, c.nowTs);
  return sync(s, c.word, c.nowTs);
}

function advanceTime(r: () => number, ts: bigint, sph: bigint): bigint {
  const x = r();
  if (x < 0.05) return ts + BigInt(int(r, 20, 120)) * sph; // a long absence
  if (x < 0.2) return ts + BigInt(int(r, 1, 6)) * sph;
  return ts + BigInt(int(r, 0, Number(sph) * 2));
}

describe('variant fork with every variant off', () => {
  it('plays 200 random games exactly like the mirror engine', () => {
    let unfinished = 0;
    for (let g = 0; g < 200; g++) {
      const r = rng(1000 + g);
      const preset = presetFor(g);
      let mirror = startGame(preset.config, preset.types, T0, { buyFirstWord: true });
      let fork = startGame(preset.config, preset.types, T0, { buyFirstWord: true, variants: defaultVariants(), forceVariantEngine: true });
      expect(mirror.variants).toBeUndefined();
      expect(fork.variants).toBeDefined();
      let ts = T0 + 2n;
      for (let step = 0; step < 80 && !mirror.player.game.finished; step++) {
        const call = nextCall(mirror, r, ts);
        mirror = apply(mirror, call);
        fork = apply(fork, call);
        expect(fork.player).toEqual(mirror.player);
        if (step % 8 === 0) expect(view(fork, ts)).toEqual(view(mirror, ts));
        ts = advanceTime(r, ts, preset.config.secPerHour);
      }
      if (!mirror.player.game.finished) unfinished++;
      expect(fork.log).toEqual(mirror.log);
    }
    expect(unfinished).toBeLessThan(200); // some games are played to the death
  }, 120_000);

  it('equals the mirror catch-up on random states, including blown fuses', () => {
    let fuses = 0;
    for (let i = 0; i < 60; i++) {
      const r = rng(5000 + i);
      const preset = presetFor(3); // dense spawns
      let s = startGame(preset.config, preset.types, T0, { buyFirstWord: true });
      let ts = T0 + 2n;
      for (let step = 0; step < int(r, 2, 40) && !s.player.game.finished; step++) {
        s = apply(s, nextCall(s, r, ts));
        ts = advanceTime(r, ts, preset.config.secPerHour);
      }
      const p = s.player;
      const far = ts + BigInt(int(r, 0, 400)) * preset.config.secPerHour;
      const args = [p.epochWord, word(r), p.pending.coveredEpochs, p.pending.coveredEpochs + BigInt(int(r, 0, 6)), far] as const;
      const m = catchUp(p.game, p.portals, preset.config, preset.types, ...args);
      const f = catchUpVariant(p.game, p.portals, preset.config, preset.types, defaultVariants(), ...args);
      expect(f.game).toEqual(m.game);
      expect(f.portals).toEqual(m.portals);
      expect(f.cappedShort).toBe(m.cappedShort);
      expect(f.events.map(({ early, ...e }) => (expect(early).toBe(false), e))).toEqual(m.events);
      expect(f.spawns).toEqual(m.spawns);
      expect(f.hourly).toEqual([]);
      if (m.events.length + m.spawns.length === 64) fuses++;
    }
    expect(fuses).toBeGreaterThan(0);
  }, 60_000);
});

// ── Composition with variants on ─────────────────────────────────────────────

function randomVariants(r: () => number): VariantSet {
  const v = defaultVariants();
  v.creatureArrivals = { on: true, chancePct: BigInt(int(r, 10, 100)), maxPerPortal: BigInt(int(r, 1, 8)) };
  const lo = int(r, 0, 40);
  v.stabilityHealth = { on: true, jumpChancePct: BigInt(int(r, 10, 80)), jumpMin: BigInt(lo), jumpMax: BigInt(lo + int(r, 0, 40)) };
  v.stabilizeExtends = { on: r() < 0.5, hours: BigInt(int(r, 0, 10)) };
  v.rescuerTakesObserver = { on: r() < 0.5 };
  v.rescuerRestAfterEvac = { on: r() < 0.5, hours: BigInt(int(r, 0, 10)) };
  v.pressurePerAction = { on: r() < 0.5, value: BigInt(int(r, 0, 5000)) };
  return v;
}

function concat(a: VCatchUpResult, b: VCatchUpResult) {
  return { events: [...a.events, ...b.events], spawns: [...a.spawns, ...b.spawns], hourly: [...a.hourly, ...b.hourly] };
}

describe('variant catch-up composes', () => {
  it('catch-up to b then to c equals catch-up to c, on 80 random states with variants on', () => {
    let withHourly = 0;
    let withEarly = 0;
    for (let i = 0; i < 80; i++) {
      const r = rng(9000 + i);
      const preset = presetFor(i);
      const variants = randomVariants(r);
      let s = startGame(preset.config, preset.types, T0, { buyFirstWord: true, variants });
      let ts = T0 + 2n;
      for (let step = 0; step < int(r, 1, 30) && !s.player.game.finished; step++) {
        s = apply(s, nextCall(s, r, ts));
        ts = advanceTime(r, ts, preset.config.secPerHour);
      }
      const p = s.player;
      const sph = preset.config.secPerHour;
      const b = p.game.lastTickAt + BigInt(int(r, 0, 30)) * sph + BigInt(int(r, 0, Number(sph) - 1));
      const c = b + BigInt(int(r, 0, 30)) * sph + BigInt(int(r, 0, Number(sph) - 1));
      // Free projection (one word), and a crossing (old word below the split, new beyond).
      const crossing = r() < 0.5;
      const w = crossing ? word(r) : p.epochWord;
      const maxCov = crossing ? p.pending.coveredEpochs + BigInt(int(r, 1, 3)) : p.pending.coveredEpochs;
      const run = (g: typeof p.game, ps: typeof p.portals, now: bigint) =>
        catchUpVariant(g, ps, preset.config, preset.types, variants, p.epochWord, w, p.pending.coveredEpochs, maxCov, now);

      const whole = run(p.game, p.portals, c);
      const first = run(p.game, p.portals, b);
      const second = run(first.game, first.portals, c);
      expect(second.game, `state ${i}`).toEqual(whole.game);
      expect(second.portals, `state ${i}`).toEqual(whole.portals);
      const both = concat(first, second);
      expect(both.events).toEqual(whole.events);
      expect(both.spawns).toEqual(whole.spawns);
      expect(both.hourly).toEqual(whole.hourly);
      if (whole.hourly.length > 0) withHourly++;
      if (whole.events.some((e) => e.early)) withEarly++;
    }
    // The states must actually exercise the hourly variants.
    expect(withHourly).toBeGreaterThan(40);
    expect(withEarly).toBeGreaterThan(0);
  }, 60_000);
});
