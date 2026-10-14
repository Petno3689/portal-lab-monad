/**
 * GOLDEN-VECTOR FILE FORMAT — shared by the four mirror tickets (RulesLib,
 * EffectsLib, TimeLib, preview). Decided once; change it only with all four in mind.
 *
 * Generators are Solidity scripts in contracts/script/ (they run the real library
 * and record what it returned); the files land in shared/test/vectors/. One Solidity
 * golden test (contracts/test/*Golden.t.sol) and one TS test read the SAME file.
 *
 * ── File shape ───────────────────────────────────────────────────────────────
 *
 *   {
 *     "configs": [ <Config>, ... ],          // a handful, shared by reference
 *     "vectors": [                           // ONE VECTOR PER LINE (diff-friendly)
 *       { "label": "...",
 *         "game": <Game>, "portal": <Portal>,
 *         "config": <index into configs>,
 *         "slot": 0, "action": 3,
 *         "expected": { "refusal": 0, "cost": 10 } },
 *       ...
 *     ]
 *   }
 *
 * Rules:
 *  1. Vectors are an ARRAY OF OBJECTS, not parallel arrays. Inputs are full structs
 *     with every field of the Solidity struct under its Solidity name (so a mirror
 *     that ignores a field is proven to ignore it, not assumed to). Later mirrors
 *     add their own input/expected members next to these; the struct objects stay.
 *  2. Config is large and nearly constant, so it is stored once in `configs` and a
 *     vector points at it by index. Without this the file passes 2 MB.
 *  3. Enums are plain integers (the Solidity ordinal). Their names live in
 *     enums.json, written by the same generator from the compiled enums.
 *  4. Numbers: every field up to uint40 is a JSON number. A field wider than 48
 *     bits (uint64 Pending.requestId, uint256 words) MUST be written as a decimal
 *     STRING, since JSON.parse would round it. Loaders below turn all of it to bigint.
 *  5. `label` is a human note ("random" for generated rows). Never asserted on.
 *  6. The Solidity side reads COLUMN-wise (VectorCodec.read*), the TS side
 *     row-wise; both rely on the same field names.
 *
 * ── Extension 1 (EffectsLib mirror): reverts ─────────────────────────────────
 *
 * Some library calls REVERT, and a mirror that returns a value where the contract
 * reverts is a silent divergence. A vector may therefore say "this call reverts":
 *
 *     "expected": { "reverted": true,  "error": "NoFreeRescuerCell", ... }
 *     "expected": { "reverted": false, "error": "",                  ... }
 *
 *  - `reverted` is a boolean; ABSENT MEANS false, so rules-vectors.json (written
 *    before this extension, no such member) stays valid as it is. Files that use
 *    the extension (effects-vectors.json) write it on EVERY row, because the
 *    Solidity side reads columns and a column must be rectangular.
 *  - `error` is the error NAME, "" when the call does not revert. Names in use:
 *      "NoFreeRescuerCell"   the library's custom error
 *      "Panic(0x11)"         checked-arithmetic over/underflow (Solidity 0.8)
 *    The generator aborts on any other revert, so a new kind must be named here.
 *  - On a reverted row the result members of `expected` (game, portal, outcome,
 *    precise, ...) are written as ALL-ZERO placeholders, only to keep columns
 *    rectangular. They are meaningless; consumers MUST read `reverted` first and
 *    never compare against them.
 *  - The TS mirror signals a revert by throwing `ContractRevert` (src/effects.ts)
 *    whose `.error` is that same name.
 *
 * ── Extension 2 (EffectsLib mirror): several functions in one file ───────────
 *
 * effects-vectors.json holds three arrays, one per library function, each an array
 * of objects like `vectors` above. Besides `configs` it carries `typeParams`
 * (PortalTypeParams, referenced by index from a row's `tp`, same reasoning as
 * configs). Random words are uint256 and are written as decimal STRINGS (rule 4).
 *
 *   { "configs": [...], "typeParams": [...],
 *     "applyAction": [ { label, game, portal, config, tp, action,
 *                        expected: { reverted, error, game, portal, outcome } } ],
 *     "survey":      [ { label, portal, config, tp, word,
 *                        expected: { reverted, error, portal, precise } } ],
 *     "blindReveal": [ { label, game, portal, config, word,
 *                        expected: { reverted, error, game, portal, outcome } } ] }
 *
 * Expected state is the FULL state after the call, never a delta: a field that
 * should have changed and did not must be visible.
 */

import { Outcome } from "../../src/effects";
import { Collapse, Spawn } from "../../src/time";
import {
    Config,
    Game,
    Portal,
    PortalStatus,
    PortalType,
    PortalTypeParams,
} from "../../src/types";

type Json = Record<string, number | boolean>;

const big = (o: Json, k: string): bigint => {
    const v = o[k];
    if (typeof v !== "number") throw new Error(`vector field ${k}: expected number, got ${typeof v}`);
    return BigInt(v);
};
const bool = (o: Json, k: string): boolean => {
    const v = o[k];
    if (typeof v !== "boolean") throw new Error(`vector field ${k}: expected boolean, got ${typeof v}`);
    return v;
};

export function gameFromJson(o: Json): Game {
    return {
        startedAt: big(o, "startedAt"),
        lastTickAt: big(o, "lastTickAt"),
        hoursElapsed: big(o, "hoursElapsed"),
        diedAtHour: big(o, "diedAtHour"),
        hp: big(o, "hp"),
        power: big(o, "power"),
        observersFree: big(o, "observersFree"),
        rescuersFree: big(o, "rescuersFree"),
        openPortals: big(o, "openPortals"),
        finished: bool(o, "finished"),
        spawnDebt: big(o, "spawnDebt"),
        spawnCount: big(o, "spawnCount"),
        rngNonce: big(o, "rngNonce"),
        rescuerReadyAt0: big(o, "rescuerReadyAt0"),
        rescuerReadyAt1: big(o, "rescuerReadyAt1"),
        rescuerReadyAt2: big(o, "rescuerReadyAt2"),
        rescuerReadyAt3: big(o, "rescuerReadyAt3"),
        creaturesRescued: big(o, "creaturesRescued"),
        settled: bool(o, "settled"),
    };
}

export function portalFromJson(o: Json): Portal {
    return {
        id: big(o, "id"),
        portalType: Number(big(o, "portalType")) as PortalType,
        nameIndex: big(o, "nameIndex"),
        status: Number(big(o, "status")) as PortalStatus,
        surveyed: bool(o, "surveyed"),
        narrowedOnce: bool(o, "narrowedOnce"),
        observerInside: bool(o, "observerInside"),
        rescuerInside: bool(o, "rescuerInside"),
        surveyPending: bool(o, "surveyPending"),
        rescuerPending: bool(o, "rescuerPending"),
        creaturesKnown: bool(o, "creaturesKnown"),
        energy: big(o, "energy"),
        stability: big(o, "stability"),
        creatures: big(o, "creatures"),
        hoursToCollapse: big(o, "hoursToCollapse"),
        spawnedAtHour: big(o, "spawnedAtHour"),
        snapshotAt: big(o, "snapshotAt"),
        energyLo: big(o, "energyLo"),
        energyHi: big(o, "energyHi"),
        stabilityLo: big(o, "stabilityLo"),
        stabilityHi: big(o, "stabilityHi"),
        creaturesLo: big(o, "creaturesLo"),
        creaturesHi: big(o, "creaturesHi"),
    };
}

export function configFromJson(o: Json): Config {
    return {
        secPerHour: big(o, "secPerHour"),
        longAbsenceHours: big(o, "longAbsenceHours"),
        hpMax: big(o, "hpMax"),
        hpStart: big(o, "hpStart"),
        hpCollapseBase: big(o, "hpCollapseBase"),
        hpCollapsePerDeath: big(o, "hpCollapsePerDeath"),
        hpEmptyCollapse: big(o, "hpEmptyCollapse"),
        hpOverflowPerHour: big(o, "hpOverflowPerHour"),
        healPerCreature: big(o, "healPerCreature"),
        powerMax: big(o, "powerMax"),
        powerRegenPerHour: big(o, "powerRegenPerHour"),
        costToggleQuestioned: big(o, "costToggleQuestioned"),
        costStabilize: big(o, "costStabilize"),
        costDestabilize: big(o, "costDestabilize"),
        costSendObserver: big(o, "costSendObserver"),
        costRecallObserver: big(o, "costRecallObserver"),
        costSendRescuer: big(o, "costSendRescuer"),
        costRecallRescuer: big(o, "costRecallRescuer"),
        costEvacuate: big(o, "costEvacuate"),
        costClose: big(o, "costClose"),
        observersTotal: big(o, "observersTotal"),
        rescuersTotal: big(o, "rescuersTotal"),
        rescuerCooldownHours: big(o, "rescuerCooldownHours"),
        closeStabilityBelow: big(o, "closeStabilityBelow"),
        closeHoursAtMost: big(o, "closeHoursAtMost"),
        basePressurePerHour: big(o, "basePressurePerHour"),
        pressureRampPerHour: big(o, "pressureRampPerHour"),
        spawnCostUnits: big(o, "spawnCostUnits"),
        closePressureBonus: big(o, "closePressureBonus"),
        rangeWidenPerHour: big(o, "rangeWidenPerHour"),
        epochHours: big(o, "epochHours"),
        requestTimeoutHours: big(o, "requestTimeoutHours"),
    };
}

/** One row of rules-vectors.json, as it sits in the file. */
export interface RulesVectorJson {
    label: string;
    game: Json;
    portal: Json;
    config: number;
    slot: number;
    action: number;
    expected: { refusal: number; cost: number };
}

export interface RulesVectorFile {
    configs: Json[];
    vectors: RulesVectorJson[];
}

export function typeParamsFromJson(o: Json): PortalTypeParams {
    return {
        hoursMin: big(o, "hoursMin"),
        hoursMax: big(o, "hoursMax"),
        degradePerHour: big(o, "degradePerHour"),
        energyMin: big(o, "energyMin"),
        energyMax: big(o, "energyMax"),
        stabilityMin: big(o, "stabilityMin"),
        stabilityMax: big(o, "stabilityMax"),
        creaturesMin: big(o, "creaturesMin"),
        creaturesMax: big(o, "creaturesMax"),
        actionMultiplierPct: big(o, "actionMultiplierPct"),
        powerYieldPerHour: big(o, "powerYieldPerHour"),
        surveyPrecise: bool(o, "surveyPrecise"),
    };
}

export function outcomeFromJson(o: Json): Outcome {
    return {
        rescued: big(o, "rescued"),
        hpGained: big(o, "hpGained"),
        deaths: big(o, "deaths"),
        hpLost: big(o, "hpLost"),
        surveyDone: bool(o, "surveyDone"),
        surveyPrecise: bool(o, "surveyPrecise"),
        rescuerBlindMiss: bool(o, "rescuerBlindMiss"),
        rescuerReadyAtHour: big(o, "rescuerReadyAtHour"),
        leftBehind: big(o, "leftBehind"),
    };
}

/** Members shared by every `expected` of an extension-1 file. */
export interface RevertFields {
    reverted: boolean;
    error: string;
}

export interface ApplyActionVectorJson {
    label: string;
    game: Json;
    portal: Json;
    config: number;
    tp: number;
    action: number;
    expected: RevertFields & { game: Json; portal: Json; outcome: Json };
}

export interface SurveyVectorJson {
    label: string;
    portal: Json;
    config: number;
    tp: number;
    word: string;
    expected: RevertFields & { portal: Json; precise: boolean };
}

export interface BlindRevealVectorJson {
    label: string;
    game: Json;
    portal: Json;
    config: number;
    word: string;
    expected: RevertFields & { game: Json; portal: Json; outcome: Json };
}

export interface EffectsVectorFile {
    configs: Json[];
    typeParams: Json[];
    applyAction: ApplyActionVectorJson[];
    survey: SurveyVectorJson[];
    blindReveal: BlindRevealVectorJson[];
}

/**
 * ── Extension 3 (TimeLib mirror): time-vectors.json ──────────────────────────
 *
 * Two pure helpers, two arrays. Wide values (word, epoch, seed, pressure) are
 * decimal STRINGS (rule 4); `a`, `b` are game hours (uint32) and plain numbers.
 * No reverts: neither function can revert, so there is no `reverted` member.
 *
 *   { "configs": [...],
 *     "epochSeed":     [ { label, word, epoch, expected: { seed } } ],
 *     "spawnPressure": [ { label, a, b, config, expected: { pressure } } ] }
 */
export interface EpochSeedVectorJson {
    label: string;
    word: string;
    epoch: string;
    expected: { seed: string };
}

export interface SpawnPressureVectorJson {
    label: string;
    a: number;
    b: number;
    config: number;
    expected: { pressure: string };
}

export interface TimeVectorFile {
    configs: Json[];
    epochSeed: EpochSeedVectorJson[];
    spawnPressure: SpawnPressureVectorJson[];
}

/**
 * ── Extension 4 (TimeLib mirror): catchup-vectors.json ───────────────────────
 *
 * `catchUp` takes a whole world, so a vector carries a Game plus TWELVE portals
 * and gives back the same shape. Two things are new:
 *
 *  - Portal arrays are written out IN FULL, twelve per vector, nested in the
 *    vector object. The Solidity side reads them with a two-wildcard path
 *    (`.vectors[*].portalsIn[*]`), which flattens them in vector order, so the
 *    existing `VectorCodec.readPortals` works unchanged; the TS side reads them
 *    row-wise, as it reads everything.
 *  - `typeParams` is a flat list of FIVE-entry sets (one per `PortalType`, in
 *    enum order). A vector's `types` is the SET index: its params live at
 *    `5·types … 5·types+4`. `config` keeps pointing into `configs` as before.
 *
 * `events` and `spawns` hold EXACTLY the records that happened — `eventCount` and
 * `spawnCount` entries, no padding. The library returns fixed-size arrays with a
 * separate count and the tail is uninitialised memory; recording it would make the
 * tests compare rubbish and go green or red depending on what was left over.
 *
 * `oldWord` / `newWord` are uint256 and are therefore decimal STRINGS (rule 4);
 * `storedCoveredEpochs`, `maxCoveredEpochs` and `nowTs` fit in uint40 and are
 * plain numbers. No `reverted` member: every vector is built from a state a real
 * game can reach, and none of them reverts.
 *
 *   { "configs": [...], "typeParams": [...],
 *     "vectors": [ { label, game, portalsIn, config, types, oldWord, newWord,
 *                    storedCoveredEpochs, maxCoveredEpochs, nowTs,
 *                    expected: { game, portalsOut, events, spawns, cappedShort } } ] }
 */
export interface CatchUpVectorJson {
    label: string;
    game: Json;
    portalsIn: Json[];
    config: number;
    types: number;
    oldWord: string;
    newWord: string;
    storedCoveredEpochs: number;
    maxCoveredEpochs: number;
    nowTs: number;
    expected: {
        game: Json;
        portalsOut: Json[];
        events: Json[];
        spawns: Json[];
        cappedShort: boolean;
    };
}

export interface CatchUpVectorFile {
    configs: Json[];
    typeParams: Json[];
    vectors: CatchUpVectorJson[];
}

/**
 * ── Extension 5 (TimeLib mirror): spawn-vectors.json ─────────────────────────
 *
 * Step 5 of `catchUp` — spawn pressure, the deterministic long-absence overflow
 * death, and the spawns both branches pay for. The rows of `vectors` are exactly
 * extension 4's rows (`CatchUpVectorJson`), and are reused verbatim; the only
 * difference in the data is that `expected.spawns` is usually NOT empty, because
 * every config here carries real pressure. catchup-vectors.json stays as it is:
 * built on zero-pressure configs, it remains the witness that step 5 is inert
 * when no pressure can accrue.
 *
 * What IS new is a second array:
 *
 *   "refusals": [ { <the same inputs>, expected: { reverted, error } } ]
 *
 * `catchUp` is a public path and is not total. Called with a `lastTickAt` ahead
 * of `nowTs` — a caller holding a stale timestamp — it computes
 * `hNow - windowStart` inside the fill-hour search and underflows; a spawn with
 * `rngNonce` or `spawnCount` at the uint32 ceiling cannot take its increment.
 * Those rows carry NO expected state, only the revert: there is no state to
 * compare, and all-zero placeholders (extension 1's device, needed there because
 * reverting and non-reverting rows share one array) would just be noise. Both
 * replayers must assert that the call falls over AND that it is the same kind of
 * revert; `error` uses extension 1's names, so "Panic(0x11)" is the TS mirror's
 * `ContractRevert` with `PANIC_ARITHMETIC`.
 */
export interface RefusalVectorJson {
    label: string;
    game: Json;
    portalsIn: Json[];
    config: number;
    types: number;
    oldWord: string;
    newWord: string;
    storedCoveredEpochs: number;
    maxCoveredEpochs: number;
    nowTs: number;
    expected: RevertFields;
}

export interface SpawnVectorFile {
    configs: Json[];
    typeParams: Json[];
    vectors: CatchUpVectorJson[];
    refusals: RefusalVectorJson[];
}

/**
 * ── Extension 6 (preview mirror): preview-vectors.json ───────────────────────
 *
 * `preview` takes a whole stored PLAYER rather than a loose world, so the input
 * side is extension 4's `game` + twelve `portalsIn` plus the two fields the
 * projection reads out of the rest of the record: `epochWord` (uint256, hence a
 * decimal STRING by rule 4) and `coveredEpochs`. There is no `oldWord` /
 * `newWord` / `maxCoveredEpochs` triple, and that absence is the point —
 * `preview` passes the ONE stored word in both of `catchUp`'s word slots and the
 * ONE stored coverage in both of its limits, which is what makes it a free
 * projection that stops at the pinned edge.
 *
 * `expected` carries the three on-chain returns and nothing else: `game`,
 * `portalsOut` (twelve) and `cappedShort`. No `events` / `spawns` — a projection
 * emits nothing, and the on-chain function returns no log.
 *
 * `configs` holds ONE entry and `typeParams` ONE five-entry set, both read out of
 * the deployed harness the states were produced on; every vector's `config` and
 * `types` are therefore 0. No `reverted` member: every state in the file was
 * produced by driving the real contract, and `preview` is a view that cannot fail
 * on one.
 *
 * WHERE THE STATES COME FROM — the thing that distinguishes this file from every
 * other one here. Extensions 1–5 build their inputs field by field, which is fine
 * for a pure library but says nothing about whether the fields can occur
 * together. These states were WORKED OUT BY THE CONTRACT: games started with
 * `startGame` and moved with `act`, `sync`, delivered words and `settle`, with the
 * clock wound forward in between, and the whole stored record read back after
 * each step (contracts/script/GenPreviewVectors.s.sol). Several moments are
 * projected off each state — the stored mark itself, an hour on, the pinned edge,
 * one hour past it, and far beyond.
 *
 *   { "configs": [<Config>], "typeParams": [<PortalTypeParams> x5],
 *     "vectors": [ { label, game, portalsIn, config, types, epochWord,
 *                    coveredEpochs, nowTs,
 *                    expected: { game, portalsOut, cappedShort } } ] }
 */
export interface PreviewVectorJson {
    label: string;
    game: Json;
    portalsIn: Json[];
    config: number;
    types: number;
    epochWord: string;
    coveredEpochs: number;
    nowTs: number;
    expected: {
        game: Json;
        portalsOut: Json[];
        cappedShort: boolean;
    };
}

export interface PreviewVectorFile {
    configs: Json[];
    typeParams: Json[];
    vectors: PreviewVectorJson[];
}

export function collapseFromJson(o: Json): Collapse {
    return {
        slot: big(o, "slot"),
        deaths: big(o, "deaths"),
        hpLost: big(o, "hpLost"),
        atHour: big(o, "atHour"),
    };
}

export function spawnFromJson(o: Json): Spawn {
    return {
        slot: big(o, "slot"),
        portalType: Number(big(o, "portalType")) as PortalType,
        nameIndex: big(o, "nameIndex"),
        atHour: big(o, "atHour"),
    };
}

/** The five `PortalTypeParams` of set `index`, as `catchUp` wants them. */
export function typeSetFromJson(typeParams: Json[], index: number): PortalTypeParams[] {
    const set = typeParams.slice(index * 5, index * 5 + 5);
    if (set.length !== 5) throw new Error(`typeParams has no complete set at index ${index}`);
    return set.map(typeParamsFromJson);
}
