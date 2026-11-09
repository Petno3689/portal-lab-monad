import type { Config, PortalTypeParams } from '@shared/types';

/**
 * One PortalTypeParams per PortalType, in enum order (Flash, LongLived, Deaf, Resonant,
 * Energetic) — the contract's PortalTypeParams[5].
 */
export type TypeTable = readonly [PortalTypeParams, PortalTypeParams, PortalTypeParams, PortalTypeParams, PortalTypeParams];

/** A deployable parameter set: what PortalLab's constructor takes, minus the random source. */
export interface Preset {
  config: Config;
  types: TypeTable;
}

/**
 * The live configuration, transcribed field by field from contracts/src/GameConfig.sol
 * (GameConfig.config() and GameConfig.portalTypeParams()). That file is the source of
 * truth; if it changes, this copy must be re-transcribed.
 */
export const LIVE_V2: Preset = {
  config: {
    // time
    secPerHour: 15n,
    longAbsenceHours: 20n,
    // HP
    hpMax: 100n,
    hpStart: 80n,
    hpCollapseBase: 20n,
    hpCollapsePerDeath: 8n,
    hpEmptyCollapse: 3n,
    hpOverflowPerHour: 5n,
    healPerCreature: 3n,
    // resource
    powerMax: 100n,
    powerRegenPerHour: 5n,
    // action costs
    costToggleQuestioned: 0n,
    costStabilize: 5n,
    costDestabilize: 5n,
    costSendObserver: 10n,
    costRecallObserver: 5n,
    costSendRescuer: 20n,
    costRecallRescuer: 10n,
    costEvacuate: 10n,
    costClose: 25n,
    // crew
    observersTotal: 3n,
    rescuersTotal: 2n,
    rescuerCooldownHours: 10n,
    // closing thresholds
    closeStabilityBelow: 40n,
    closeHoursAtMost: 6n,
    // spawns
    basePressurePerHour: 1000n,
    pressureRampPerHour: 2n,
    spawnCostUnits: 10_000n,
    closePressureBonus: 2500n,
    // survey / knowledge decay
    rangeWidenPerHour: 1n,
    // spawn entropy
    epochHours: 36n,
    requestTimeoutHours: 1n,
    outsiderTimeoutHours: 40n,
  },
  types: [
    // PortalType.Flash = 0
    {
      hoursMin: 5n,
      hoursMax: 10n,
      degradePerHour: 6n,
      energyMin: 60n,
      energyMax: 100n,
      stabilityMin: 20n,
      stabilityMax: 60n,
      creaturesMin: 1n,
      creaturesMax: 3n,
      actionMultiplierPct: 100n,
      powerYieldPerHour: 0n,
      surveyPrecise: true,
    },
    // PortalType.LongLived = 1
    {
      hoursMin: 30n,
      hoursMax: 60n,
      degradePerHour: 2n,
      energyMin: 20n,
      energyMax: 60n,
      stabilityMin: 40n,
      stabilityMax: 90n,
      creaturesMin: 1n,
      creaturesMax: 5n,
      actionMultiplierPct: 100n,
      powerYieldPerHour: 0n,
      surveyPrecise: true,
    },
    // PortalType.Deaf = 2
    {
      hoursMin: 10n,
      hoursMax: 30n,
      degradePerHour: 3n,
      energyMin: 20n,
      energyMax: 100n,
      stabilityMin: 10n,
      stabilityMax: 90n,
      creaturesMin: 0n,
      creaturesMax: 4n,
      actionMultiplierPct: 100n,
      powerYieldPerHour: 0n,
      surveyPrecise: false,
    },
    // PortalType.Resonant = 3
    {
      hoursMin: 10n,
      hoursMax: 30n,
      degradePerHour: 5n,
      energyMin: 30n,
      energyMax: 80n,
      stabilityMin: 20n,
      stabilityMax: 80n,
      creaturesMin: 0n,
      creaturesMax: 3n,
      actionMultiplierPct: 200n,
      powerYieldPerHour: 0n,
      surveyPrecise: true,
    },
    // PortalType.Energetic = 4
    {
      hoursMin: 10n,
      hoursMax: 30n,
      degradePerHour: 3n,
      energyMin: 60n,
      energyMax: 100n,
      stabilityMin: 20n,
      stabilityMax: 70n,
      creaturesMin: 0n,
      creaturesMax: 2n,
      actionMultiplierPct: 100n,
      powerYieldPerHour: 4n,
      surveyPrecise: true,
    },
  ],
};

/** LIVE_V2 with the reactor's regeneration doubled (5 → 10 per hour); nothing else differs. */
export const ENERGY_X2: Preset = {
  config: { ...LIVE_V2.config, powerRegenPerHour: LIVE_V2.config.powerRegenPerHour * 2n },
  types: LIVE_V2.types.map((t) => ({ ...t })) as unknown as TypeTable,
};

/**
 * "Best 4 Nov": the owner's best settings after the play-test of 4 November 2026 —
 * LIVE_V2 with power regeneration 15 per hour and 10 000 → 3 500 pressure per portal.
 * Its rule variants are `best4NovVariants()` (variant/variants.ts).
 */
export const BEST_4_NOV: Preset = {
  config: { ...LIVE_V2.config, powerRegenPerHour: 15n, spawnCostUnits: 3500n },
  types: LIVE_V2.types.map((t) => ({ ...t })) as unknown as TypeTable,
};

/**
 * "Best 8 Nov": the owner's settings from the play-test of 8 November 2026
 * (sandbox-game-1794123632) — LIVE_V2 with the collapse/heal/regen/cost/spawn changes
 * below, Flash lasting 6–12 hours and the Energetic portal yielding 8 power per hour.
 * Its rule variants are `best8NovVariants()` (variant/variants.ts).
 */
export const BEST_8_NOV: Preset = {
  config: {
    ...LIVE_V2.config,
    hpCollapseBase: 15n,
    hpCollapsePerDeath: 5n,
    healPerCreature: 4n,
    powerRegenPerHour: 15n,
    costSendRescuer: 15n,
    costClose: 15n,
    spawnCostUnits: 4000n,
  },
  types: [
    { ...LIVE_V2.types[0], hoursMin: 6n, hoursMax: 12n },
    { ...LIVE_V2.types[1] },
    { ...LIVE_V2.types[2] },
    { ...LIVE_V2.types[3] },
    { ...LIVE_V2.types[4], powerYieldPerHour: 8n },
  ],
};
