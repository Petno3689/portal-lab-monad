import { describe, expect, it } from 'vitest';
import { validateConfig } from './engine';
import { presetParams, presetVariants } from './params';
import { BEST_8_NOV, LIVE_V2 } from './presets';
import { best8NovVariants } from './variant/variants';

describe('preset "Best 8 Nov"', () => {
  it('passes validateConfig', () => {
    expect(() => validateConfig(BEST_8_NOV.config, BEST_8_NOV.types)).not.toThrow();
  });

  it('differs from LIVE_V2 in exactly the listed config fields', () => {
    const changed: Record<string, bigint> = {
      hpCollapseBase: 15n,
      hpCollapsePerDeath: 5n,
      healPerCreature: 4n,
      powerRegenPerHour: 15n,
      costSendRescuer: 15n,
      costClose: 15n,
      spawnCostUnits: 4000n,
    };
    for (const key of Object.keys(LIVE_V2.config) as (keyof typeof LIVE_V2.config)[]) {
      expect(BEST_8_NOV.config[key], key).toBe(key in changed ? changed[key] : LIVE_V2.config[key]);
    }
    expect(Object.keys(BEST_8_NOV.config)).toEqual(Object.keys(LIVE_V2.config));
  });

  it('differs from LIVE_V2 in exactly the listed type fields', () => {
    const changed: Record<number, Record<string, bigint>> = {
      0: { hoursMin: 6n, hoursMax: 12n },
      4: { powerYieldPerHour: 8n },
    };
    expect(BEST_8_NOV.types).toHaveLength(5);
    BEST_8_NOV.types.forEach((t, i) => {
      expect(t).toEqual({ ...LIVE_V2.types[i], ...changed[i] });
    });
  });

  it('has the listed rule variants', () => {
    expect(best8NovVariants()).toEqual({
      creatureArrivals: { on: true, chancePct: 10n, maxPerPortal: 3n },
      stabilityHealth: { on: true, jumpChancePct: 10n, jumpMin: 10n, jumpMax: 30n },
      criticalPhase: { on: true, hours: 2n },
      stabilizeExtends: { on: true, hours: 2n },
      rescuerTakesObserver: { on: true },
      rescuerRestAfterEvac: { on: true, hours: 2n },
      pressurePerAction: { on: true, value: 250n },
    });
  });

  it('is what the preset selector returns', () => {
    expect(presetParams('Best 8 Nov')).toEqual(BEST_8_NOV);
    expect(presetVariants('Best 8 Nov')).toEqual(best8NovVariants());
  });
});
