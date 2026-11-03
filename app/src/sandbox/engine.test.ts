import { describe, expect, it } from 'vitest';
import { portalRisk } from '@shared/risk';
import { check } from '@shared/rules';
import { Action, PortalStatus, PortalType, Refusal, RiskLevel, type Game, type Portal } from '@shared/types';
import {
  InvalidConfigError,
  act,
  needsWord,
  resolve,
  startGame,
  sync,
  view,
  type EngineRefusal,
  type EngineState,
} from './engine';
import { ENERGY_X2, LIVE_V2, type Preset } from './presets';

const T0 = 1_700_000_000n;
const SPH = LIVE_V2.config.secPerHour;
const at = (hour: bigint): bigint => T0 + hour * SPH;
const FREE = { buyFirstWord: false } as const;
const PAID = { buyFirstWord: true } as const;
/** The live callback lands 2–3 s after a paid start. */
const CALLBACK = T0 + 2n;

/** A deterministic stream of 256-bit words; the engine hashes them anyway. */
const wordOf = (i: number): bigint => BigInt.asUintN(256, (BigInt(i) + 1n) * 0x9e3779b97f4a7c15f39cc0605cedc834n + 0x5bd1e995n);

/** A game on `preset` with epoch 0 pinned to `word` at hour 1. */
function synced(preset: Preset, word: bigint): EngineState {
  return sync(startGame(preset.config, preset.types, T0, FREE), word, at(1n));
}

/** A paid start on `preset` whose first word, `word`, arrives at CALLBACK (hour 0). */
function paidStart(preset: Preset, word: bigint): EngineState {
  return resolve(startGame(preset.config, preset.types, T0, PAID), word, CALLBACK);
}

/** The first word index for which `ok` holds on a fresh LIVE_V2 game (synced by default). */
function findWord(ok: (s: EngineState) => boolean, build: (preset: Preset, word: bigint) => EngineState = synced): bigint {
  for (let i = 0; i < 500; i++) {
    if (ok(build(LIVE_V2, wordOf(i)))) return wordOf(i);
  }
  throw new Error('no suitable word in the first 500');
}

function patch(s: EngineState, slot: number, p: Partial<Portal>, g: Partial<Game> = {}): EngineState {
  return {
    ...s,
    player: {
      ...s.player,
      game: { ...s.player.game, ...g },
      portals: s.player.portals.map((x, i) => (i === slot ? { ...x, ...p } : x)),
    },
  };
}

const openCount = (ps: Portal[]): number => ps.filter((p) => p.status !== PortalStatus.Empty).length;

describe('startGame', () => {
  it('rejects a configuration the constructor would reject', () => {
    expect(() => startGame({ ...LIVE_V2.config, secPerHour: 0n }, LIVE_V2.types, T0, FREE)).toThrow(InvalidConfigError);
    expect(() => startGame({ ...LIVE_V2.config, healPerCreature: 8n }, LIVE_V2.types, T0, FREE)).toThrow(/healPerCreature/);
    const badTypes = LIVE_V2.types.map((t, i) => (i === 2 ? { ...t, hoursMin: 0n } : t)) as unknown as Preset['types'];
    expect(() => startGame(LIVE_V2.config, badTypes, T0, FREE)).toThrow(/hoursMin/);
  });

  it('without buyFirstWord a fresh game is capped until a word arrives, then holds the starting hand at hour 0', () => {
    const s0 = startGame(LIVE_V2.config, LIVE_V2.types, T0, FREE);
    expect(s0.log).toEqual([{ kind: 'gameStarted', ts: T0.toString(), startedAt: T0.toString() }]);

    expect(view(s0, at(1n)).cappedShort).toBe(true);
    expect(needsWord(s0, at(1n))).toBe(true);
    expect(openCount(view(s0, at(1n)).portals)).toBe(0);

    const s1 = sync(s0, wordOf(0), at(1n));
    expect(needsWord(s1, at(1n))).toBe(false);
    const v = view(s1, at(1n));
    expect(v.cappedShort).toBe(false);
    const open = v.portals.filter((p) => p.status !== PortalStatus.Empty);
    expect(open).toHaveLength(3);
    for (const p of open) expect(p.spawnedAtHour).toBe(0n);
    expect(v.game.power).toBe(100n);
    expect(v.game.hp).toBe(80n);
    expect(v.game.observersFree).toBe(3n);
    expect(v.game.rescuersFree).toBe(2n);

    const spawned = s1.log.filter((e) => e.kind === 'portalSpawned');
    expect(spawned.map((e) => e.hour)).toEqual(['0', '0', '0']);
    expect(s1.log.find((e) => e.kind === 'wordPinned')).toEqual({ kind: 'wordPinned', ts: at(1n).toString(), fromEpoch: '0', toEpoch: '1' });
  });

  it('with buyFirstWord the start commits a deferral and its word births the hand at hour 0', () => {
    const s0 = startGame(LIVE_V2.config, LIVE_V2.types, T0, PAID);
    expect(s0.player.pending).toEqual({
      active: true,
      action: Action.ToggleQuestioned,
      slot: 0n,
      portalId: 0n,
      atHour: 0n,
      requestId: 1n,
      coveredEpochs: 0n,
      deferredWorld: true,
      syncOnly: true,
      committedAt: T0,
    });
    expect(s0.nextRequestId).toBe(2n);
    expect(s0.log).toEqual([
      { kind: 'gameStarted', ts: T0.toString(), startedAt: T0.toString() },
      { kind: 'deferralRequested', ts: T0.toString(), slot: '0', action: Action.ToggleQuestioned, requestId: '1', hour: '0', crossing: true },
    ]);

    // Before the callback: nothing is open, a word is needed, every act is refused.
    expect(openCount(view(s0, CALLBACK).portals)).toBe(0);
    expect(needsWord(s0, CALLBACK)).toBe(true);
    const pendingRefusal: EngineRefusal = 'ActionPending';
    for (const [slot, a] of [
      [0n, Action.SendObserver],
      [3n, Action.Close],
      [11n, Action.ToggleQuestioned],
    ] as const) {
      const r = act(s0, slot, a, CALLBACK);
      expect(r.result).toEqual({ kind: 'refused', reason: pendingRefusal });
      expect(r.state.player).toEqual(s0.player);
    }

    // The callback, 2 s later.
    const s1 = resolve(s0, wordOf(0), CALLBACK);
    expect(s1.player.pending.active).toBe(false);
    expect(s1.player.pending.coveredEpochs).toBe(1n);
    expect(needsWord(s1, CALLBACK)).toBe(false);
    const v = view(s1, CALLBACK);
    expect(v.game.hoursElapsed).toBe(0n);
    const open = v.portals.filter((p) => p.status !== PortalStatus.Empty);
    expect(open).toHaveLength(3);
    for (const p of open) expect(p.spawnedAtHour).toBe(0n);
    expect(v.game.power).toBe(100n);
    expect(v.game.hp).toBe(80n);
    expect(v.game.observersFree).toBe(3n);
    expect(v.game.rescuersFree).toBe(2n);

    const spawned = s1.log.filter((e) => e.kind === 'portalSpawned');
    expect(spawned.map((e) => e.hour)).toEqual(['0', '0', '0']);
    expect(s1.log.find((e) => e.kind === 'wordPinned')).toEqual({ kind: 'wordPinned', ts: CALLBACK.toString(), fromEpoch: '0', toEpoch: '1' });
  });
});

describe('power regen', () => {
  // No energetic portal may be open in the first ten hours, or its yield would add in.
  const word = findWord(
    (s) => view(s, at(10n)).portals.every((p) => p.status === PortalStatus.Empty || p.portalType !== PortalType.Energetic),
    paidStart,
  );

  for (const [name, preset] of [
    ['LIVE_V2', LIVE_V2],
    ['ENERGY_X2', ENERGY_X2],
  ] as const) {
    it(`power at hour h is min(powerMax, start − spent + h·regen) on ${name}`, () => {
      let s = paidStart(preset, word);
      // Spend 30 at hour 0, right after the callback: an observer into each of the three portals.
      for (const slot of [0n, 1n, 2n]) {
        const r = act(s, slot, Action.SendObserver, CALLBACK);
        expect(r.result).toEqual({ kind: 'deferred' });
        s = resolve(r.state, wordOf(100 + Number(slot)), CALLBACK);
      }
      const { powerMax, powerRegenPerHour } = preset.config;
      const spent = 30n;
      for (let h = 1n; h <= 10n; h++) {
        const expected = powerMax - spent + h * powerRegenPerHour;
        expect(view(s, at(h)).game.power).toBe(expected < powerMax ? expected : powerMax);
      }
    });
  }
});

describe('refusals', () => {
  const word = wordOf(0);
  const base = synced(LIVE_V2, word);
  const now = at(1n);
  const SAFE: Partial<Portal> = {
    surveyed: true,
    creaturesKnown: true,
    stability: 90n,
    energy: 20n,
    creatures: 2n,
    creaturesLo: 2n,
    creaturesHi: 2n,
    hoursToCollapse: 30n,
  };
  const CRITICAL: Partial<Portal> = { ...SAFE, stability: 0n, energy: 100n, creatures: 5n, hoursToCollapse: 1n };

  it('the crafted portals have the risk levels the cases rely on', () => {
    const level = (p: Portal) =>
      portalRisk({
        status: p.status,
        surveyed: p.surveyed,
        stability: Number(p.stability),
        energy: Number(p.energy),
        hoursToCollapse: Number(p.hoursToCollapse),
        creatures: Number(p.creatures),
        observerInside: p.observerInside,
        rescuerInside: p.rescuerInside,
      }).level;
    expect(level(patch(base, 0, SAFE).player.portals[0])).not.toBe(RiskLevel.Critical);
    expect(level(patch(base, 0, CRITICAL).player.portals[0])).toBe(RiskLevel.Critical);
  });

  const cases: [string, EngineState, bigint, Action, Refusal][] = [
    ['GameNotActive', patch(base, 0, {}, { finished: true, hp: 0n }), 0n, Action.Stabilize, Refusal.GameNotActive],
    ['InvalidSlot', base, 12n, Action.Stabilize, Refusal.InvalidSlot],
    ['PortalEmpty', base, 5n, Action.Stabilize, Refusal.PortalEmpty],
    ['NotSurveyed', base, 0n, Action.Stabilize, Refusal.NotSurveyed],
    ['SurveyPending', patch(base, 0, { observerInside: true, surveyPending: true }), 0n, Action.RecallObserver, Refusal.SurveyPending],
    ['ObserverAlreadyInside', patch(base, 0, { observerInside: true }), 0n, Action.SendObserver, Refusal.ObserverAlreadyInside],
    ['NoObserverInside', base, 0n, Action.RecallObserver, Refusal.NoObserverInside],
    ['NoObserverFree', patch(base, 0, {}, { observersFree: 0n }), 0n, Action.SendObserver, Refusal.NoObserverFree],
    ['RescuerAlreadyInside', patch(base, 0, { ...SAFE, rescuerInside: true }), 0n, Action.SendRescuer, Refusal.RescuerAlreadyInside],
    ['NoRescuerInside', base, 0n, Action.RecallRescuer, Refusal.NoRescuerInside],
    ['NoRescuerFree', patch(base, 0, SAFE, { rescuersFree: 0n }), 0n, Action.SendRescuer, Refusal.NoRescuerFree],
    ['NoCreatures', patch(base, 0, { ...SAFE, creatures: 0n, creaturesLo: 0n, creaturesHi: 0n }), 0n, Action.Evacuate, Refusal.NoCreatures],
    ['RiskTooHigh', patch(base, 0, CRITICAL), 0n, Action.SendObserver, Refusal.RiskTooHigh],
    ['NotUnstableEnough', patch(base, 0, SAFE), 0n, Action.Close, Refusal.NotUnstableEnough],
    ['NotEnoughPower', patch(base, 0, SAFE, { power: 0n }), 0n, Action.Stabilize, Refusal.NotEnoughPower],
  ];

  for (const [name, s, slot, action, reason] of cases) {
    it(`${name} is returned, not thrown, and leaves the record untouched`, () => {
      const { state, result } = act(s, slot, action, now);
      expect(result).toEqual({ kind: 'refused', reason });
      expect(state.player).toEqual(s.player);
      expect(state.nextRequestId).toBe(s.nextRequestId);
      expect(state.log).toHaveLength(s.log.length + 1);
      expect(state.log.at(-1)).toEqual({
        kind: 'actionRefused',
        ts: now.toString(),
        slot: slot.toString(),
        action,
        reason,
        hour: '1',
      });
    });
  }

  it('covers every Refusal check() can return', () => {
    const covered = new Set(cases.map((c) => c[4]));
    const fromCheck = Object.values(Refusal).filter(
      (v): v is Refusal => typeof v === 'number' && v !== Refusal.None && v !== Refusal.RandomnessTimeout,
    );
    expect(fromCheck.filter((r) => !covered.has(r))).toEqual([]);
  });
});

describe('survey', () => {
  it('SendObserver into an unsurveyed portal defers; a second act is ActionPending; resolve surveys', () => {
    const word = findWord((s) => s.player.portals.some((p) => p.status !== PortalStatus.Empty && p.portalType !== PortalType.Deaf));
    const s0 = synced(LIVE_V2, word);
    const slot = BigInt(s0.player.portals.findIndex((p) => p.status !== PortalStatus.Empty && p.portalType !== PortalType.Deaf));

    const r1 = act(s0, slot, Action.SendObserver, at(1n));
    expect(r1.result).toEqual({ kind: 'deferred' });
    const s1 = r1.state;
    expect(s1.player.pending.active).toBe(true);
    expect(s1.player.game.power).toBe(90n);
    expect(s1.player.portals[Number(slot)].surveyPending).toBe(true);
    expect(needsWord(s1, at(1n))).toBe(true);

    const pendingRefusal: EngineRefusal = 'ActionPending';
    for (const [sl, a] of [
      [slot, Action.ToggleQuestioned],
      [(slot + 1n) % 3n, Action.SendObserver],
      [11n, Action.Close],
    ] as const) {
      const r = act(s1, sl, a, at(2n));
      expect(r.result).toEqual({ kind: 'refused', reason: pendingRefusal });
      expect(r.state.player).toEqual(s1.player);
    }

    const s2 = resolve(s1, wordOf(42), at(1n));
    const p = s2.player.portals[Number(slot)];
    expect(s2.player.pending.active).toBe(false);
    expect(p.surveyed).toBe(true);
    expect(p.surveyPending).toBe(false);
    expect(p.observerInside).toBe(true);
    expect(p.energyLo).toBe(p.energyHi);
    expect(s2.log.slice(-2).map((e) => e.kind)).toEqual(['portalSurveyed', 'deferralResolved']);
    // The record's coverage outlives the deferral.
    expect(s2.player.pending.coveredEpochs).toBe(1n);
  });
});

/** A fixed script touching every call shape, including an epoch-crossing deferral. */
function scripted(preset: Preset, firstWord: bigint): EngineState {
  let s = startGame(preset.config, preset.types, T0, FREE);
  s = sync(s, firstWord, at(1n));
  s = act(s, 0n, Action.SendObserver, at(2n)).state;
  s = resolve(s, wordOf(2), at(2n));
  s = act(s, 1n, Action.SendRescuer, at(3n)).state;
  if (s.player.pending.active) s = resolve(s, wordOf(3), at(3n));
  s = act(s, 0n, Action.Stabilize, at(4n)).state;
  s = act(s, 2n, Action.Close, at(5n)).state; // likely refused: logged either way
  // Hour 40 lies in epoch 1, beyond the pinned edge: the whole action defers.
  const crossing = act(s, 0n, Action.ToggleQuestioned, at(40n));
  s = crossing.state;
  if (s.player.pending.active) s = resolve(s, wordOf(4), at(40n));
  s = sync(s, wordOf(5), at(80n));
  return s;
}

describe('determinism', () => {
  // Many starting hands die before hour 36; take the first word whose run lives to
  // the edge, so the script exercises the epoch-crossing deferral.
  const crosses = (s: EngineState) => s.log.some((e) => e.kind === 'deferralRequested' && e.crossing);
  let first = -1;
  for (let i = 0; i < 500 && first < 0; i++) if (crosses(scripted(LIVE_V2, wordOf(i)))) first = i;

  it('the same calls on the same preset give an identical log', () => {
    expect(first).toBeGreaterThanOrEqual(0);
    const a = scripted(LIVE_V2, wordOf(first));
    const b = scripted(LIVE_V2, wordOf(first));
    expect(JSON.stringify(a.log)).toBe(JSON.stringify(b.log));
    expect(a.player).toEqual(b.player);
    // The script did reach across the pinned edge, and the reveal pinned epoch 1.
    expect(crosses(a)).toBe(true);
    expect(a.log.some((e) => e.kind === 'wordPinned' && e.fromEpoch === '1')).toBe(true);
    expect(a.player.pending.active).toBe(false);
  });

  it('the log is plain JSON', () => {
    const log = scripted(ENERGY_X2, wordOf(Math.max(first, 0))).log;
    expect(JSON.parse(JSON.stringify(log))).toEqual(log);
  });
});

describe('a whole game', () => {
  it('a close-what-you-can policy plays until game over and the log ends with it', () => {
    let s = startGame(LIVE_V2.config, LIVE_V2.types, T0, FREE);
    let words = 0;
    let hour = 1n;
    const MAX_HOURS = 5000n;

    for (; hour <= MAX_HOURS && !s.player.game.finished; hour++) {
      const now = at(hour);
      if (s.player.pending.active) s = resolve(s, wordOf(words++), now);
      if (needsWord(s, now) || view(s, now).game.finished) s = sync(s, wordOf(words++), now);
      if (s.player.game.finished) break;
      const v = view(s, now);
      for (let slot = 0n; slot < 12n; slot++) {
        if (check(v.game, v.portals[Number(slot)], s.config, slot, Action.Close) === Refusal.None) {
          s = act(s, slot, Action.Close, now).state;
          break; // one action per hour; the next hour sees the new world
        }
      }
    }

    expect(s.player.game.finished).toBe(true);
    expect(hour).toBeLessThanOrEqual(MAX_HOURS);
    const last = s.log.at(-1)!;
    expect(last.kind).toBe('gameOver');
    expect(s.log.filter((e) => e.kind === 'gameOver')).toHaveLength(1);
    if (last.kind === 'gameOver') expect(last.hour).toBe(s.player.game.diedAtHour.toString());
    expect(s.log.some((e) => e.kind === 'portalClosed')).toBe(true);
  });
});
