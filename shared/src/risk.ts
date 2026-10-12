/**
 * TypeScript mirror of RiskLib.sol — SPEC §4.1.
 *
 * All arithmetic uses bigint. Every intermediate value is in fixed point with
 * scale S = 1e18; every division rounds half up, matching the Solidity canon.
 * The TS mirror and the contract must agree bit-for-bit because level thresholds
 * are gates (critical risk forbids sending people) where a one-unit difference on
 * a boundary changes game behaviour, not just a display value.
 */

export const S = 10n ** 18n;

/** Non-negative division rounding half up: (a + c/2) / c. */
export function divHalfUp(a: bigint, c: bigint): bigint {
    return (a + c / 2n) / c;
}

import { PortalStatus, RiskLevel } from "./types";

// Single definition of these enums lives in types.ts; re-exported so existing
// imports from "./risk" keep working.
export { PortalStatus, RiskLevel };

/**
 * Risk score (0..100) for an already-aged portal snapshot.
 * Steps 1–8 from SPEC §4.1, same order and same roundings as RiskLib.score.
 * Throws on stability > 100, energy > 100, or any non-integer negative input.
 */
export function score(stability: number, energy: number, hours: number, lives: number): number {
    if (!Number.isInteger(stability) || stability < 0 || stability > 100) {
        throw new RangeError(`stability must be an integer in [0, 100], got ${stability}`);
    }
    if (!Number.isInteger(energy) || energy < 0 || energy > 100) {
        throw new RangeError(`energy must be an integer in [0, 100], got ${energy}`);
    }
    if (!Number.isInteger(hours) || hours < 0) {
        throw new RangeError(`hours must be a non-negative integer, got ${hours}`);
    }
    if (!Number.isInteger(lives) || lives < 0) {
        throw new RangeError(`lives must be a non-negative integer, got ${lives}`);
    }

    // Steps 1–3: three weighted base components.
    const inst = BigInt(100 - stability) * S;
    const en = BigInt(energy) * S;
    let tp: bigint;
    if (hours >= 48) {
        tp = 0n;
    } else {
        tp = 100n * S - divHalfUp(BigInt(hours) * 100n * S, 48n);
    }

    // Step 4: weighted base — instability 0.5, energy 0.3, time deficit 0.2.
    let r = divHalfUp(inst * 50n + en * 30n + tp * 20n, 100n);

    // Step 5: time factor — mutually exclusive branches.
    if (hours <= 2) {
        r = r + divHalfUp((100n * S - r) * 45n, 100n);
    } else if (hours <= 6) {
        r = r + divHalfUp((100n * S - r) * 20n, 100n);
    }

    // Step 6: critical instability factor.
    if (stability < 20) {
        r = r + divHalfUp((100n * S - r) * 35n, 100n);
    }

    // Step 7: lives factor.
    if (lives > 0) {
        let k = BigInt(8 + 4 * lives);
        if (k > 30n) k = 30n;
        r = r + divHalfUp((100n * S - r) * k, 100n);
    }

    // Step 8: back to integer, capped at 100.
    let result = divHalfUp(r, S);
    if (result > 100n) result = 100n;
    return Number(result);
}

/** Map a risk score to its level. Same thresholds as RiskLib.levelOf. */
export function levelOf(s: number): RiskLevel {
    if (s < 30) return RiskLevel.Low;
    if (s < 60) return RiskLevel.Medium;
    if (s < 85) return RiskLevel.High;
    return RiskLevel.Critical;
}

export interface PortalLike {
    status: PortalStatus;
    surveyed: boolean;
    stability: number;
    energy: number;
    hoursToCollapse: number;
    creatures: number;
    observerInside: boolean;
    rescuerInside: boolean;
}

/**
 * Risk of a portal, mirroring RiskLib.portalRisk.
 * Empty → (0, None). Unsurveyed → (0, Unknown). Otherwise computes score.
 */
export function portalRisk(p: PortalLike): { score: number; level: RiskLevel } {
    if (p.status === PortalStatus.Empty) return { score: 0, level: RiskLevel.None };
    if (!p.surveyed) return { score: 0, level: RiskLevel.Unknown };

    const lives = p.creatures + (p.observerInside ? 1 : 0) + (p.rescuerInside ? 1 : 0);
    assertUint8(lives, "lives");
    const s = score(p.stability, p.energy, p.hoursToCollapse, lives);
    return { score: s, level: levelOf(s) };
}

/** Solidity `uint8 lives` is checked arithmetic: past 255 the contract reverts. */
function assertUint8(v: number, what: string): void {
    if (v > 255) throw new RangeError(`${what} overflows uint8: ${v}`);
}

export interface CautiousPortalLike {
    status: PortalStatus;
    stabilityLo: number;
    energyHi: number;
    hoursToCollapse: number;
    creaturesHi: number;
    observerInside: boolean;
}

/**
 * Mirror of RiskLib.cautiousPortalRisk: risk of an UNSURVEYED portal read from the
 * worst corner of its ranges (stabilityLo, energyHi, creaturesHi), counting an
 * observer already inside plus the rescuer about to enter. Empty → (0, None).
 */
export function cautiousPortalRisk(p: CautiousPortalLike): { score: number; level: RiskLevel } {
    if (p.status === PortalStatus.Empty) return { score: 0, level: RiskLevel.None };

    let lives = p.creaturesHi;
    if (p.observerInside) lives += 1;
    lives += 1; // the rescuer we are about to send in
    assertUint8(lives, "lives");

    const s = score(p.stabilityLo, p.energyHi, p.hoursToCollapse, lives);
    return { score: s, level: levelOf(s) };
}

// ── Breakdown (UI only — not computed on-chain) ───────────────────────────────

export interface RiskPart {
    label: string;
    raw: bigint;
    weightPct: number;
    contribution: bigint;
}

export interface RiskStep {
    label: string;
    applied: boolean;
    sharePct: number;
    before: bigint;
    after: bigint;
    delta: bigint;
    note: string;
}

export interface RiskBreakdown {
    known: boolean;
    score: number;
    level: RiskLevel;
    parts: RiskPart[];
    base: bigint;
    steps: RiskStep[];
    dominant: { label: string; delta: bigint } | null;
}

/**
 * Per-factor breakdown for the UI panel "Как посчитан риск".
 *
 * Invariant: min(100, divHalfUp(steps[2].after, S)) === score(...).
 * The breakdown retraces the exact same steps as score() so both must agree.
 */
export function breakdown(p: PortalLike): RiskBreakdown {
    if (p.status === PortalStatus.Empty) {
        return { known: false, score: 0, level: RiskLevel.None, parts: [], base: 0n, steps: [], dominant: null };
    }
    if (!p.surveyed) {
        return { known: false, score: 0, level: RiskLevel.Unknown, parts: [], base: 0n, steps: [], dominant: null };
    }

    const lives = p.creatures + (p.observerInside ? 1 : 0) + (p.rescuerInside ? 1 : 0);
    const h = p.hoursToCollapse;
    const s = p.stability;

    // Recompute base components (steps 1–3).
    const inst = BigInt(100 - s) * S;
    const en = BigInt(p.energy) * S;
    let tp: bigint;
    if (h >= 48) {
        tp = 0n;
    } else {
        tp = 100n * S - divHalfUp(BigInt(h) * 100n * S, 48n);
    }

    const parts: RiskPart[] = [
        { label: "Нестабильность", raw: inst, weightPct: 50, contribution: divHalfUp(inst * 50n, 100n) },
        { label: "Энергетическая нагрузка", raw: en, weightPct: 30, contribution: divHalfUp(en * 30n, 100n) },
        { label: "Дефицит времени", raw: tp, weightPct: 20, contribution: divHalfUp(tp * 20n, 100n) },
    ];

    // Step 4: weighted base.
    const base = divHalfUp(inst * 50n + en * 30n + tp * 20n, 100n);

    // Steps 5–7: factors applied in order, always three entries.
    const steps: RiskStep[] = [];
    let r = base;

    // Step 5: time factor (one of three mutually exclusive states).
    if (h <= 2) {
        const before = r;
        const delta = divHalfUp((100n * S - r) * 45n, 100n);
        r = r + delta;
        steps.push({ label: "Портал вот-вот схлопнется", applied: true, sharePct: 45, before, after: r, delta, note: "До схлопывания не больше 2 часов" });
    } else if (h <= 6) {
        const before = r;
        const delta = divHalfUp((100n * S - r) * 20n, 100n);
        r = r + delta;
        steps.push({ label: "Осталось меньше 6 часов", applied: true, sharePct: 20, before, after: r, delta, note: "До схлопывания не больше 6 часов" });
    } else {
        steps.push({ label: "Запас времени", applied: false, sharePct: 0, before: r, after: r, delta: 0n, note: `До схлопывания ещё ${h} ч — фактор не сработал` });
    }

    // Step 6: critical instability factor.
    {
        const before = r;
        if (s < 20) {
            const delta = divHalfUp((100n * S - r) * 35n, 100n);
            r = r + delta;
            steps.push({ label: "Критическая нестабильность", applied: true, sharePct: 35, before, after: r, delta, note: `Стабильность ${s} ниже 20` });
        } else {
            steps.push({ label: "Критическая нестабильность", applied: false, sharePct: 0, before, after: r, delta: 0n, note: `Стабильность ${s} — не ниже 20` });
        }
    }

    // Step 7: lives factor.
    {
        const before = r;
        if (lives > 0) {
            let k = BigInt(8 + 4 * lives);
            if (k > 30n) k = 30n;
            const delta = divHalfUp((100n * S - r) * k, 100n);
            r = r + delta;
            steps.push({ label: "Внутри живые", applied: true, sharePct: Number(k), before, after: r, delta, note: `Внутри живых: ${lives}` });
        } else {
            steps.push({ label: "Внутри живые", applied: false, sharePct: 0, before, after: r, delta: 0n, note: "Внутри никого нет" });
        }
    }

    // Step 8: final score.
    let finalR = divHalfUp(r, S);
    if (finalR > 100n) finalR = 100n;
    const finalScore = Number(finalR);

    // Dominant: applied step with the largest delta; first on tie.
    let dominant: { label: string; delta: bigint } | null = null;
    for (const step of steps) {
        if (step.applied && (dominant === null || step.delta > dominant.delta)) {
            dominant = { label: step.label, delta: step.delta };
        }
    }

    return { known: true, score: finalScore, level: levelOf(finalScore), parts, base, steps, dominant };
}
