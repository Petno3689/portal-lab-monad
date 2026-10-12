/**
 * TypeScript mirror of PortalLabTypes.sol — enums and structs.
 *
 * Source of truth is Solidity (contracts/src/PortalLabTypes.sol). Conventions,
 * same as risk.ts:
 *  - every numeric struct field is `bigint`, whatever its Solidity width
 *    (uint8 … uint64); booleans are `boolean`; enum fields use the enum types below;
 *  - enum members are repeated explicitly with their integer values. The order is
 *    part of the specification. test/types.enums.test.ts compares every member and
 *    value against enums.json, which GenRulesVectors.s.sol derives from the
 *    compiled Solidity enums — a drifted copy fails there, not in the game.
 *
 * PortalStatus and RiskLevel live HERE and are re-exported from risk.ts, so
 * existing `import { RiskLevel } from "./risk"` keeps working and there is one
 * definition of each enum.
 */

/** Maximum portals a game holds at once (constant MAX_OPEN_PORTALS). */
export const MAX_OPEN_PORTALS = 12n;
/** Upper bound on rescuers per game (constant MAX_RESCUERS). */
export const MAX_RESCUERS = 4n;

/** Must match PortalLabTypes.sol enum order exactly. */
export enum PortalType {
    Flash = 0,
    LongLived = 1,
    Deaf = 2,
    Resonant = 3,
    Energetic = 4,
}

/** Must match PortalLabTypes.sol enum order exactly. */
export enum RiskLevel {
    Unknown = 0,
    None = 1,
    Low = 2,
    Medium = 3,
    High = 4,
    Critical = 5,
}

/** Must match PortalLabTypes.sol enum order exactly. */
export enum Action {
    ToggleQuestioned = 0,
    Stabilize = 1,
    Destabilize = 2,
    SendObserver = 3,
    RecallObserver = 4,
    SendRescuer = 5,
    RecallRescuer = 6,
    Evacuate = 7,
    Close = 8,
}

/** Must match PortalLabTypes.sol enum order exactly. `None` means "allowed". */
export enum Refusal {
    None = 0,
    GameNotActive = 1,
    InvalidSlot = 2,
    PortalEmpty = 3,
    NotSurveyed = 4,
    SurveyPending = 5,
    ObserverAlreadyInside = 6,
    NoObserverInside = 7,
    NoObserverFree = 8,
    RescuerAlreadyInside = 9,
    NoRescuerInside = 10,
    NoRescuerFree = 11,
    NoCreatures = 12,
    RiskTooHigh = 13,
    NotUnstableEnough = 14,
    NotEnoughPower = 15,
    RandomnessTimeout = 16,
}

/** Must match PortalLabTypes.sol enum order exactly. */
export enum PortalStatus {
    Empty = 0,
    Open = 1,
    Questioned = 2,
}

export interface Portal {
    id: bigint;
    portalType: PortalType;
    nameIndex: bigint;
    status: PortalStatus;
    surveyed: boolean;
    observerInside: boolean;
    rescuerInside: boolean;
    surveyPending: boolean;
    rescuerPending: boolean;
    creaturesKnown: boolean;
    energy: bigint;
    stability: bigint;
    creatures: bigint;
    hoursToCollapse: bigint;
    spawnedAtHour: bigint;
    snapshotAt: bigint;
    energyLo: bigint;
    energyHi: bigint;
    stabilityLo: bigint;
    stabilityHi: bigint;
    creaturesLo: bigint;
    creaturesHi: bigint;
}

export interface Game {
    startedAt: bigint;
    lastTickAt: bigint;
    hoursElapsed: bigint;
    diedAtHour: bigint;
    hp: bigint;
    power: bigint;
    observersFree: bigint;
    rescuersFree: bigint;
    openPortals: bigint;
    finished: boolean;
    spawnDebt: bigint;
    spawnCount: bigint;
    rngNonce: bigint;
    rescuerReadyAt0: bigint;
    rescuerReadyAt1: bigint;
    rescuerReadyAt2: bigint;
    rescuerReadyAt3: bigint;
    creaturesRescued: bigint;
    settled: boolean;
}

export interface Pending {
    active: boolean;
    action: Action;
    slot: bigint;
    atHour: bigint;
    requestId: bigint;
    coveredEpochs: bigint;
    deferredWorld: boolean;
    syncOnly: boolean;
    committedAt: bigint;
}

export interface BestRun {
    hoursSurvived: bigint;
    creaturesRescued: bigint;
    settledAt: bigint;
    runsSettled: bigint;
}

export interface PortalTypeParams {
    hoursMin: bigint;
    hoursMax: bigint;
    degradePerHour: bigint;
    energyMin: bigint;
    energyMax: bigint;
    stabilityMin: bigint;
    stabilityMax: bigint;
    creaturesMin: bigint;
    creaturesMax: bigint;
    actionMultiplierPct: bigint;
    powerYieldPerHour: bigint;
    surveyPrecise: boolean;
}

export interface Config {
    // time
    secPerHour: bigint;
    longAbsenceHours: bigint;
    // HP
    hpMax: bigint;
    hpStart: bigint;
    hpCollapseBase: bigint;
    hpCollapsePerDeath: bigint;
    hpEmptyCollapse: bigint;
    hpOverflowPerHour: bigint;
    healPerCreature: bigint;
    // resource
    powerMax: bigint;
    powerRegenPerHour: bigint;
    // action costs
    costToggleQuestioned: bigint;
    costStabilize: bigint;
    costDestabilize: bigint;
    costSendObserver: bigint;
    costRecallObserver: bigint;
    costSendRescuer: bigint;
    costRecallRescuer: bigint;
    costEvacuate: bigint;
    costClose: bigint;
    // crew
    observersTotal: bigint;
    rescuersTotal: bigint;
    rescuerCooldownHours: bigint;
    // closing thresholds
    closeStabilityBelow: bigint;
    closeHoursAtMost: bigint;
    // spawns
    maxSpawnsPerTx: bigint;
    basePressurePerHour: bigint;
    pressureRampPerHour: bigint;
    spawnCostUnits: bigint;
    closePressureBonus: bigint;
    // survey / knowledge decay
    rangeWidenPerHour: bigint;
    deafNarrowThreshold: bigint;
    // spawn entropy
    epochHours: bigint;
    requestTimeoutHours: bigint;
}
