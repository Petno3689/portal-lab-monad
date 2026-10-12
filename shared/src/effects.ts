/**
 * TypeScript mirror of EffectsLib.sol — what an already-allowed action does to
 * game state (SPEC §4.2, §4.4).
 *
 * Source of truth is contracts/src/EffectsLib.sol and nothing else. Order of
 * operations inside every branch is kept line for line with the Solidity: where
 * the order is visible in the result (spend before effect, clamps, truncation)
 * it must not be rearranged or "simplified".
 *
 * Arithmetic is bigint throughout. Division TRUNCATES — deliberately, as in the
 * contract (RiskLib rounds half up; this library does not). For the non-negative
 * operands used here bigint `/` is exactly Solidity's truncating division.
 *
 * Reverts. Solidity 0.8 checked arithmetic reverts with Panic(0x11) on
 * over/underflow of a typed variable, and the library has one explicit custom
 * error. A mirror that returned a value where the contract reverts would be a
 * silent divergence, so every checked operation below throws `ContractRevert`
 * with the same name the golden vectors record. Explicit narrowing casts
 * (`uint8(x)`, `uint16(x)`, …) do NOT revert in 0.8 — they truncate — and are
 * mirrored by `trunc`.
 *
 * Purity. Solidity mutates its memory structs in place; this mirror never
 * touches its arguments and returns fresh objects.
 *
 * `player` (the last parameter of Solidity `applyAction`) is unused by the
 * contract and therefore omitted here.
 */

import { keccak256 } from "./keccak";
import {
    Action,
    Config,
    Game,
    MAX_RESCUERS,
    Portal,
    PortalStatus,
    PortalType,
    PortalTypeParams,
} from "./types";

/** Mirror of PortalLabTypes.SPAWN_DEBT_MAX. */
export const SPAWN_DEBT_MAX = 1_000_000_000n;

const STABILITY_STEP = 25n;
const ENERGY_STEP = 10n;
const BLIND_RESCUE_SALT = 3n;

/** Name recorded in the vectors for a checked-arithmetic panic. */
export const PANIC_ARITHMETIC = "Panic(0x11)";
/** Name of EffectsLib's custom error. */
export const NO_FREE_RESCUER_CELL = "NoFreeRescuerCell";

/** Thrown exactly where the Solidity library reverts. `error` is the vector's error name. */
export class ContractRevert extends Error {
    constructor(public readonly error: string) {
        super(`contract revert: ${error}`);
        this.name = "ContractRevert";
    }
}

/** Mirror of EffectsLib.Outcome; every field is zero unless the action fills it. */
export interface Outcome {
    rescued: bigint;
    hpGained: bigint;
    deaths: bigint;
    hpLost: bigint;
    surveyDone: boolean;
    surveyPrecise: boolean;
    rescuerBlindMiss: boolean;
    rescuerReadyAtHour: bigint;
    leftBehind: bigint;
}

export function emptyOutcome(): Outcome {
    return {
        rescued: 0n,
        hpGained: 0n,
        deaths: 0n,
        hpLost: 0n,
        surveyDone: false,
        surveyPrecise: false,
        rescuerBlindMiss: false,
        rescuerReadyAtHour: 0n,
        leftBehind: 0n,
    };
}

// ── Solidity integer semantics ───────────────────────────────────────────────

const max = (bits: number): bigint => (1n << BigInt(bits)) - 1n;

/**
 * Explicit cast `uintN(x)`: keeps the low N bits, never reverts.
 * Exported for the other mirrors (time.ts): one definition of Solidity's
 * narrowing, not one per file.
 */
export const trunc = (x: bigint, bits: number): bigint => x & max(bits);

/** `a - b` on a typed uintN variable: Panic(0x11) if the result is negative. */
export function subChecked(a: bigint, b: bigint): bigint {
    if (a < b) throw new ContractRevert(PANIC_ARITHMETIC);
    return a - b;
}

/**
 * `a + b` stored in a uintN variable: Panic(0x11) if it does not fit.
 * Exported for the other mirrors (time.ts), like `trunc` and `subChecked`: one
 * definition of Solidity's checked addition, not one per file.
 */
export function addChecked(a: bigint, b: bigint, bits: number): bigint {
    const r = a + b;
    if (r > max(bits)) throw new ContractRevert(PANIC_ARITHMETIC);
    return r;
}

// ── applyAction ──────────────────────────────────────────────────────────────

/** Mirror of EffectsLib.applyAction. Feasibility is NOT re-checked, as in the contract. */
export function applyAction(
    g0: Game,
    p0: Portal,
    c: Config,
    tp: PortalTypeParams,
    a: Action,
): { game: Game; portal: Portal; outcome: Outcome } {
    const g: Game = { ...g0 };
    const p: Portal = { ...p0 };
    const outcome = emptyOutcome();

    if (a === Action.ToggleQuestioned) {
        p.status = p.status === PortalStatus.Open ? PortalStatus.Questioned : PortalStatus.Open;
    } else if (a === Action.Stabilize) {
        // stability += 25 × mult / 100 (truncated), capped at 100; energy -= 10, floored at 0.
        const step = (STABILITY_STEP * tp.actionMultiplierPct) / 100n;
        const s = p.stability + step;
        p.stability = s > 100n ? 100n : trunc(s, 8);
        p.energy = p.energy >= ENERGY_STEP ? p.energy - ENERGY_STEP : 0n;
    } else if (a === Action.Destabilize) {
        // stability -= 25 × mult / 100 (truncated), floored at 0; energy += 10, capped at 100.
        const step = (STABILITY_STEP * tp.actionMultiplierPct) / 100n;
        p.stability = p.stability > step ? trunc(p.stability - step, 8) : 0n;
        const e = p.energy + ENERGY_STEP;
        p.energy = e > 100n ? 100n : trunc(e, 8);
    } else if (a === Action.SendObserver) {
        p.observerInside = true;
        g.observersFree = subChecked(g.observersFree, 1n);
    } else if (a === Action.RecallObserver) {
        p.observerInside = false;
        g.observersFree = addChecked(g.observersFree, 1n, 8);
    } else if (a === Action.SendRescuer) {
        p.rescuerInside = true;
        g.rescuersFree = subChecked(g.rescuersFree, 1n);
    } else if (a === Action.RecallRescuer) {
        p.rescuerInside = false;
        g.rescuersFree = addChecked(g.rescuersFree, 1n, 8);
    } else if (a === Action.Evacuate) {
        // A surveyed portal is emptied; a blind one always leaves one behind.
        const saved = p.surveyed ? p.creatures : p.creatures > 0n ? p.creatures - 1n : 0n;
        p.creatures = subChecked(p.creatures, saved);
        p.rescuerInside = false;
        g.rescuersFree = addChecked(g.rescuersFree, 1n, 8);
        const healed = c.healPerCreature * saved;
        let newHp = g.hp + healed;
        if (newHp > c.hpMax) newHp = c.hpMax;
        outcome.rescued = saved;
        outcome.hpGained = trunc(subChecked(newHp, g.hp), 16); // actual gain after the cap
        outcome.leftBehind = p.creatures;
        g.hp = trunc(newHp, 16);
        g.creaturesRescued = addChecked(g.creaturesRescued, saved, 32);
    } else {
        // Action.Close.
        // Known count: exact creatures. Unknown: creaturesHi (worst case), and no
        // hpCollapseBase — deliberately unlike a collapse in TimeLib.
        const deathsCreatures = p.creaturesKnown ? p.creatures : p.creaturesHi;
        let deaths = deathsCreatures;
        if (p.observerInside) deaths += 1n;
        if (p.rescuerInside) deaths += 1n;

        let hpLost = 0n;
        if (deaths > 0n) {
            const loss = c.hpCollapsePerDeath * deaths;
            const hpBefore = g.hp;
            const actual = hpBefore > loss ? loss : hpBefore; // min(loss, hp before the hit)
            g.hp = trunc(hpBefore - actual, 16);
            hpLost = trunc(actual, 16);
        }
        outcome.deaths = trunc(deaths, 8);
        outcome.hpLost = hpLost;

        const debt = g.spawnDebt + c.closePressureBonus;
        g.spawnDebt = debt > SPAWN_DEBT_MAX ? SPAWN_DEBT_MAX : trunc(debt, 32);

        g.openPortals = subChecked(g.openPortals, 1n);

        // The slot is freed: a fresh, zeroed portal (status == Empty).
        return { game: g, portal: emptyPortal(), outcome };
    }

    return { game: g, portal: p, outcome };
}

// ── applyBlindRescuerReveal ──────────────────────────────────────────────────

/** Mirror of EffectsLib.applyBlindRescuerReveal. */
export function applyBlindRescuerReveal(
    g0: Game,
    p0: Portal,
    c: Config,
    word: bigint,
): { game: Game; portal: Portal; outcome: Outcome } {
    const g: Game = { ...g0 };
    const p: Portal = { ...p0 };
    const outcome = emptyOutcome();

    const n = inRange(fromWord(word, BLIND_RESCUE_SALT), p.creaturesLo, p.creaturesHi);
    p.creatures = n;
    p.creaturesLo = n;
    p.creaturesHi = n;
    p.creaturesKnown = true;

    if (n === 0n) {
        const readyAt = trunc(g.hoursElapsed + c.rescuerCooldownHours, 32);
        let placed = false;
        for (let cell = 0n; cell < MAX_RESCUERS; cell++) {
            if (rescuerReadyAt(g, cell) === 0n) {
                setRescuerReadyAt(g, cell, readyAt);
                placed = true;
                break;
            }
        }
        if (!placed) throw new ContractRevert(NO_FREE_RESCUER_CELL);
        outcome.rescuerBlindMiss = true;
        outcome.rescuerReadyAtHour = readyAt;
    } else {
        p.rescuerInside = true;
    }
    return { game: g, portal: p, outcome };
}

// ── survey ───────────────────────────────────────────────────────────────────

/**
 * Mirror of EffectsLib.survey. `precise` is true when the survey produced exact
 * values, false when a deaf portal's ranges were only narrowed.
 *
 * The `exact` condition is evaluated with the same short-circuit order as the
 * contract: `_width` panics on an inverted range, so which widths get evaluated
 * decides whether a vector reverts.
 */
export function survey(
    p0: Portal,
    c: Config,
    tp: PortalTypeParams,
    word: bigint,
): { portal: Portal; precise: boolean } {
    const p: Portal = { ...p0 };

    const exact =
        tp.surveyPrecise ||
        (width(p.energyLo, p.energyHi) <= c.deafNarrowThreshold &&
            width(p.stabilityLo, p.stabilityHi) <= c.deafNarrowThreshold &&
            width(p.creaturesLo, p.creaturesHi) <= c.deafNarrowThreshold);

    if (exact) {
        const energy = inRange(fromWord(word, 0n), p.energyLo, p.energyHi);
        const stability = inRange(fromWord(word, 1n), p.stabilityLo, p.stabilityHi);
        const creatures = inRange(fromWord(word, 2n), p.creaturesLo, p.creaturesHi);
        p.energy = energy;
        p.energyLo = energy;
        p.energyHi = energy;
        p.stability = stability;
        p.stabilityLo = stability;
        p.stabilityHi = stability;
        p.creatures = creatures;
        p.creaturesLo = creatures;
        p.creaturesHi = creatures;
        p.surveyed = true;
        p.creaturesKnown = true;
        return { portal: p, precise: true };
    }

    // Deaf and still too wide: halve each range around a random centre.
    [p.energyLo, p.energyHi] = narrow(p.energyLo, p.energyHi, fromWord(word, 0n));
    [p.stabilityLo, p.stabilityHi] = narrow(p.stabilityLo, p.stabilityHi, fromWord(word, 1n));
    [p.creaturesLo, p.creaturesHi] = narrow(p.creaturesLo, p.creaturesHi, fromWord(word, 2n));
    return { portal: p, precise: false };
}

// ── internals ────────────────────────────────────────────────────────────────

/** keccak256(abi.encode(word, salt)): two 32-byte big-endian words. */
export function fromWord(word: bigint, salt: bigint): bigint {
    const buf = new Uint8Array(64);
    for (let i = 0; i < 32; i++) {
        buf[31 - i] = Number((word >> BigInt(8 * i)) & 0xffn);
        buf[63 - i] = Number((salt >> BigInt(8 * i)) & 0xffn);
    }
    return keccak256(buf);
}

/**
 * Mirror of RandomStub.inRange. `hi - lo` in the span is a uint256 expression, so
 * an inverted range (lo > hi, lo != hi) underflows and panics.
 */
function inRange(rnd: bigint, lo: bigint, hi: bigint): bigint {
    if (lo === hi) return lo;
    const span = subChecked(hi, lo) + 1n;
    return trunc(lo + (rnd % span), 8);
}

/** `_width`: `hi - lo` on uint8 operands — panics on an inverted range. */
function width(lo: bigint, hi: bigint): bigint {
    return subChecked(hi, lo);
}

/** `_narrow`: truncating division like the rest of the library. */
function narrow(lo: bigint, hi: bigint, rnd: bigint): [bigint, bigint] {
    const centre = inRange(rnd, lo, hi);
    const w = (hi - lo + 1n) / 4n;
    const lowCand = centre > w ? centre - w : 0n;
    const newLo = lowCand < lo ? lo : lowCand;
    const highCand = centre + w;
    const newHi = highCand > hi ? hi : highCand;
    return [newLo, newHi];
}

/** Mirror of PortalLabTypes.rescuerReadyAt. Also used by the TimeLib mirror. */
export function rescuerReadyAt(g: Game, i: bigint): bigint {
    if (i === 0n) return g.rescuerReadyAt0;
    if (i === 1n) return g.rescuerReadyAt1;
    if (i === 2n) return g.rescuerReadyAt2;
    if (i === 3n) return g.rescuerReadyAt3;
    throw new ContractRevert("RescuerIndexOutOfRange");
}

/** Mirror of PortalLabTypes.setRescuerReadyAt. Also used by the TimeLib mirror. */
export function setRescuerReadyAt(g: Game, i: bigint, v: bigint): void {
    if (i === 0n) g.rescuerReadyAt0 = v;
    else if (i === 1n) g.rescuerReadyAt1 = v;
    else if (i === 2n) g.rescuerReadyAt2 = v;
    else if (i === 3n) g.rescuerReadyAt3 = v;
    else throw new ContractRevert("RescuerIndexOutOfRange");
}

/** A zero-initialised Portal, as Solidity's `Portal memory cleared;`. */
export function emptyPortal(): Portal {
    return {
        id: 0n,
        portalType: PortalType.Flash,
        nameIndex: 0n,
        status: PortalStatus.Empty,
        surveyed: false,
        observerInside: false,
        rescuerInside: false,
        surveyPending: false,
        rescuerPending: false,
        creaturesKnown: false,
        energy: 0n,
        stability: 0n,
        creatures: 0n,
        hoursToCollapse: 0n,
        spawnedAtHour: 0n,
        snapshotAt: 0n,
        energyLo: 0n,
        energyHi: 0n,
        stabilityLo: 0n,
        stabilityHi: 0n,
        creaturesLo: 0n,
        creaturesHi: 0n,
    };
}
