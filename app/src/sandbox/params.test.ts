import { describe, expect, it } from 'vitest';
import { Action } from '@shared/types';
import { LIVE_V2 } from './presets';
import {
  CONFIG_FIELDS,
  STORAGE_KEY,
  TYPE_FIELDS,
  buildExport,
  clampTo,
  cloneParams,
  configProblem,
  exportFileName,
  loadCustom,
  paramsFromJson,
  paramsToJson,
  parseInput,
  presetParams,
  saveCustom,
  settingsFromJson,
  settingsToJson,
  toJson,
  type Call,
} from './params';
import { defaultVariants } from './variant/variants';

describe('field metadata', () => {
  it('covers every Config and PortalTypeParams field exactly once', () => {
    expect(CONFIG_FIELDS.map((f) => f.key).sort()).toEqual(Object.keys(LIVE_V2.config).sort());
    expect([...TYPE_FIELDS.map((f) => f.key), 'surveyPrecise'].sort()).toEqual(Object.keys(LIVE_V2.types[0]).sort());
  });

  it('keeps the Live v2 values inside the limits, and sliders inside the limits', () => {
    for (const f of CONFIG_FIELDS) {
      const v = LIVE_V2.config[f.key];
      expect(v >= f.min && v <= f.max, f.key).toBe(true);
      expect(f.min <= f.max).toBe(true);
      if (f.sliderMin !== undefined) expect(f.sliderMin >= f.min).toBe(true);
      if (f.sliderMax !== undefined) expect(f.sliderMax <= f.max).toBe(true);
    }
    for (const t of LIVE_V2.types) {
      for (const f of TYPE_FIELDS) expect(t[f.key] >= f.min && t[f.key] <= f.max, f.key).toBe(true);
    }
  });

  it('uses the width of the Solidity type for each field', () => {
    const max = (k: string) => CONFIG_FIELDS.find((f) => f.key === k)!.max;
    expect(max('secPerHour')).toBe(2n ** 32n - 1n); // uint32
    expect(max('powerMax')).toBe(2n ** 16n - 1n); // uint16
    expect(max('observersTotal')).toBe(255n); // uint8
    expect(max('rescuersTotal')).toBe(4n); // MAX_RESCUERS
    expect(max('closeStabilityBelow')).toBe(100n);
    expect(TYPE_FIELDS.find((f) => f.key === 'energyMax')!.max).toBe(100n);
    expect(TYPE_FIELDS.find((f) => f.key === 'degradePerHour')!.max).toBe(255n);
  });
});

describe('clamping and parsing', () => {
  const f = { min: 1n, max: 10n };
  it('clamps to the limits', () => {
    expect(clampTo(f, 0n)).toBe(1n);
    expect(clampTo(f, 11n)).toBe(10n);
    expect(clampTo(f, 5n)).toBe(5n);
  });
  it('rejects non-numbers and out-of-range input with a message', () => {
    expect(parseInput(f, '5')).toEqual({ ok: true, value: 5n });
    expect(parseInput(f, ' 7 ')).toEqual({ ok: true, value: 7n });
    expect(parseInput(f, '')).toMatchObject({ ok: false });
    expect(parseInput(f, '-1')).toMatchObject({ ok: false });
    expect(parseInput(f, '1.5')).toMatchObject({ ok: false });
    expect(parseInput(f, '0')).toEqual({ ok: false, message: 'must be 1–10' });
    expect(parseInput(f, '99999999999999999999')).toEqual({ ok: false, message: 'must be 1–10' });
  });
});

describe('configProblem', () => {
  it('accepts both presets', () => {
    expect(configProblem(presetParams('Live v2'))).toBeNull();
    expect(configProblem(presetParams('Energy ×2'))).toBeNull();
  });
  it('reports the engine reason', () => {
    const p = cloneParams(LIVE_V2);
    p.config.hpStart = 200n; // > hpMax
    expect(configProblem(p)).toBe('hpStart');
    const q = cloneParams(LIVE_V2);
    q.config.healPerCreature = q.config.hpCollapsePerDeath;
    expect(configProblem(q)).toBe('healPerCreature');
    const r = cloneParams(LIVE_V2);
    r.types[3].hoursMin = 99n;
    expect(configProblem(r)).toBe('hoursMin>hoursMax');
  });
  it('presetParams returns independent copies', () => {
    const a = presetParams('Live v2');
    a.config.powerMax = 1n;
    a.types[0].hoursMin = 9n;
    expect(LIVE_V2.config.powerMax).toBe(100n);
    expect(LIVE_V2.types[0].hoursMin).toBe(5n);
    expect(presetParams('Energy ×2').config.powerRegenPerHour).toBe(10n);
  });
});

describe('parameter JSON', () => {
  it('round-trips a set, bigints as decimal strings', () => {
    const p = cloneParams(LIVE_V2);
    p.config.costClose = 40n;
    p.types[2].surveyPrecise = true;
    const text = paramsToJson(p);
    expect(JSON.parse(text).config.costClose).toBe('40');
    const r = paramsFromJson(text);
    expect(r).toEqual({ ok: true, params: p });
  });

  it('rejects bad input with a reason', () => {
    expect(paramsFromJson('nope')).toEqual({ ok: false, error: 'not valid JSON' });
    expect(paramsFromJson('[]')).toMatchObject({ ok: false });
    const ok = JSON.parse(paramsToJson(LIVE_V2));
    const missing = structuredClone(ok);
    delete missing.config.costClose;
    expect(paramsFromJson(JSON.stringify(missing))).toEqual({ ok: false, error: 'config.costClose: missing' });
    const wide = structuredClone(ok);
    wide.config.observersTotal = '256'; // uint8
    expect(paramsFromJson(JSON.stringify(wide))).toMatchObject({ ok: false, error: expect.stringContaining('observersTotal') });
    const badType = structuredClone(ok);
    badType.types[1].energyMax = '101';
    expect(paramsFromJson(JSON.stringify(badType))).toMatchObject({ ok: false, error: expect.stringContaining('types[1].energyMax') });
    const short = structuredClone(ok);
    short.types.pop();
    expect(paramsFromJson(JSON.stringify(short))).toEqual({ ok: false, error: 'types: expected 5 entries' });
    const flag = structuredClone(ok);
    flag.types[0].surveyPrecise = 'yes';
    expect(paramsFromJson(JSON.stringify(flag))).toMatchObject({ ok: false });
  });

  it('accepts plain numbers as well as strings', () => {
    const ok = JSON.parse(paramsToJson(LIVE_V2));
    ok.config.costClose = 30;
    const r = paramsFromJson(JSON.stringify(ok));
    expect(r.ok && r.params.config.costClose).toBe(30n);
  });
});

describe('persistence', () => {
  const memory = () => {
    const m = new Map<string, string>();
    return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), m };
  };

  it('saves and loads the custom set', () => {
    const s = memory();
    const p = cloneParams(LIVE_V2);
    p.config.powerRegenPerHour = 17n;
    saveCustom(p, s);
    expect(s.m.has(STORAGE_KEY)).toBe(true);
    expect(loadCustom(s)).toEqual(p);
  });

  it('works without storage, with throwing storage and with garbage', () => {
    expect(loadCustom(null)).toBeNull();
    expect(() => saveCustom(LIVE_V2, null)).not.toThrow();
    const broken = {
      getItem: () => {
        throw new Error('blocked');
      },
      setItem: () => {
        throw new Error('quota');
      },
    };
    expect(loadCustom(broken)).toBeNull();
    expect(() => saveCustom(LIVE_V2, broken)).not.toThrow();
    const junk = memory();
    junk.setItem(STORAGE_KEY, '{"config":1}');
    expect(loadCustom(junk)).toBeNull();
  });
});

describe('export', () => {
  const calls: Call[] = [
    { kind: 'start', nowTs: 1_793_700_000n, buyFirstWord: true },
    { kind: 'resolve', nowTs: 1_793_700_002n, word: 2n ** 255n + 7n },
    { kind: 'act', nowTs: 1_793_700_020n, slot: 3n, action: Action.Close },
    { kind: 'sync', nowTs: 1_793_700_900n, word: 5n },
  ];

  it('writes format 1 with every bigint as a decimal string', () => {
    const text = buildExport({
      exportedAt: new Date('2026-11-03T12:00:00.000Z'),
      preset: 'Custom',
      startedAt: 1_793_700_000n,
      delays: true,
      params: LIVE_V2,
      calls,
      log: [{ kind: 'gameStarted', ts: '1793700000', startedAt: '1793700000' }],
    });
    const j = JSON.parse(text);
    expect(Object.keys(j)).toEqual(['format', 'exportedAt', 'preset', 'startedAt', 'delays', 'config', 'types', 'calls', 'log']);
    expect(j.format).toBe(1);
    expect(j.exportedAt).toBe('2026-11-03T12:00:00.000Z');
    expect(j.preset).toBe('Custom');
    expect(j.startedAt).toBe('1793700000');
    expect(j.config.secPerHour).toBe('15');
    expect(j.types).toHaveLength(5);
    expect(j.types[0].hoursMin).toBe('5');
    expect(j.types[0].surveyPrecise).toBe(true);
    expect(j.calls[1]).toEqual({ kind: 'resolve', nowTs: '1793700002', word: (2n ** 255n + 7n).toString() });
    expect(j.calls[2]).toEqual({ kind: 'act', nowTs: '1793700020', slot: '3', action: Action.Close });
    expect(j.log).toHaveLength(1);
  });

  it('names the file after the start time', () => {
    expect(exportFileName(1_793_700_000n)).toBe('sandbox-game-1793700000.json');
  });

  it('toJson never throws on bigints', () => {
    expect(toJson({ a: 1n, b: [2n] })).toBe('{"a":"1","b":["2"]}');
  });
});

describe('settings JSON and export with rule variants', () => {
  it('rejects bad parameter JSON through the settings path too', () => {
    expect(settingsFromJson('nope')).toEqual({ ok: false, error: 'not valid JSON' });
    const ok = JSON.parse(settingsToJson(LIVE_V2, defaultVariants()));
    ok.variants.stabilizeExtends.hours = '256';
    expect(settingsFromJson(JSON.stringify(ok))).toMatchObject({ ok: false, error: expect.stringContaining('stabilizeExtends.hours') });
  });

  it('writes "variants" after "types" when the game has them', () => {
    const v = defaultVariants();
    v.pressurePerAction = { on: true, value: 50n };
    const j = JSON.parse(
      buildExport({ exportedAt: new Date(0), preset: 'Custom', startedAt: 1n, delays: false, params: LIVE_V2, variants: v, calls: [], log: [] }),
    );
    expect(Object.keys(j)).toEqual(['format', 'exportedAt', 'preset', 'startedAt', 'delays', 'config', 'types', 'variants', 'calls', 'log']);
    expect(j.format).toBe(1);
    expect(j.variants.pressurePerAction).toEqual({ on: true, value: '50' });
  });
});
