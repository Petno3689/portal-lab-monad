/**
 * TypeScript mirror of RulesLib.sol — action feasibility (SPEC §4.2–§4.3).
 *
 * `check` returns the FIRST applicable Refusal; the order of the checks is part of
 * the specification (the player sees the most meaningful reason), so it is kept
 * line for line with the Solidity. Do not reorder or "simplify".
 *
 * Arithmetic is bigint. Risk goes through risk.ts, whose API is number-based; the
 * Number(...) conversions below are exact (every field is ≤ uint16) and happen only
 * at that boundary.
 */

import { cautiousPortalRisk, portalRisk, PortalStatus, RiskLevel } from "./risk";
import { Action, Config, Game, MAX_OPEN_PORTALS, Portal, Refusal } from "./types";

/** Mirror of RulesLib.check. `slot` is uint8 in Solidity. */
export function check(g: Game, p: Portal, c: Config, slot: bigint, a: Action): Refusal {
    // 1. Active game.
    if (g.startedAt === 0n || g.finished) return Refusal.GameNotActive;

    // 2. Valid slot index.
    if (slot >= MAX_OPEN_PORTALS) return Refusal.InvalidSlot;

    // 3. Non-empty slot.
    if (p.status === PortalStatus.Empty) return Refusal.PortalEmpty;

    // 4. Action-specific state checks (table order is the spec).
    if (a === Action.Stabilize || a === Action.Destabilize) {
        if (!p.surveyed) return Refusal.NotSurveyed;
    } else if (a === Action.SendObserver) {
        if (p.observerInside) return Refusal.ObserverAlreadyInside;
        // Risk only checked when surveyed; sending an observer IS the survey.
        if (p.surveyed) {
            if (exactLevel(p) === RiskLevel.Critical) return Refusal.RiskTooHigh;
        }
    } else if (a === Action.RecallObserver) {
        if (!p.observerInside) return Refusal.NoObserverInside;
        // Recalling while a Pyth callback is in flight would orphan the result.
        if (p.surveyPending) return Refusal.SurveyPending;
    } else if (a === Action.SendRescuer) {
        // No NotSurveyed gate: a rescuer may go into an unsurveyed portal.
        if (p.rescuerInside) return Refusal.RescuerAlreadyInside;
        // "No creatures" can only be asserted once the count is KNOWN.
        if (p.creaturesKnown && p.creatures === 0n) return Refusal.NoCreatures;
        // The cautious (worst-corner) gate is for the rescuer ONLY — never extend it
        // to SendObserver (see the anti-deadlock note in RulesLib.check).
        const lvl = p.surveyed ? exactLevel(p) : cautiousLevel(p);
        if (lvl === RiskLevel.Critical) return Refusal.RiskTooHigh;
    } else if (a === Action.RecallRescuer) {
        if (!p.rescuerInside) return Refusal.NoRescuerInside;
    } else if (a === Action.Evacuate) {
        // Blind evacuation is allowed too: no NotSurveyed gate.
        if (p.creaturesKnown && p.creatures === 0n) return Refusal.NoCreatures;
        if (!p.rescuerInside) return Refusal.NoRescuerInside;
    } else if (a === Action.Close) {
        // Time threshold is always known; stability is only known after survey.
        let allowed = p.hoursToCollapse <= c.closeHoursAtMost;
        if (!allowed && p.surveyed) {
            allowed = p.stability < c.closeStabilityBelow;
        }
        if (!allowed) return Refusal.NotUnstableEnough;
    }
    // ToggleQuestioned: no state checks.

    // 5. Crew availability.
    if (a === Action.SendObserver && g.observersFree === 0n) return Refusal.NoObserverFree;
    if (a === Action.SendRescuer && g.rescuersFree === 0n) return Refusal.NoRescuerFree;

    // 6. Power cost.
    if (g.power < cost(c, a)) return Refusal.NotEnoughPower;

    return Refusal.None;
}

/** Mirror of RulesLib.cost: power cost of action `a`. */
export function cost(c: Config, a: Action): bigint {
    if (a === Action.ToggleQuestioned) return c.costToggleQuestioned;
    if (a === Action.Stabilize) return c.costStabilize;
    if (a === Action.Destabilize) return c.costDestabilize;
    if (a === Action.SendObserver) return c.costSendObserver;
    if (a === Action.RecallObserver) return c.costRecallObserver;
    if (a === Action.SendRescuer) return c.costSendRescuer;
    if (a === Action.RecallRescuer) return c.costRecallRescuer;
    if (a === Action.Evacuate) return c.costEvacuate;
    return c.costClose;
}

function exactLevel(p: Portal): RiskLevel {
    return portalRisk({
        status: p.status,
        surveyed: p.surveyed,
        stability: Number(p.stability),
        energy: Number(p.energy),
        hoursToCollapse: Number(p.hoursToCollapse),
        creatures: Number(p.creatures),
        observerInside: p.observerInside,
        rescuerInside: p.rescuerInside,
    }).level;
}

function cautiousLevel(p: Portal): RiskLevel {
    return cautiousPortalRisk({
        status: p.status,
        stabilityLo: Number(p.stabilityLo),
        energyHi: Number(p.energyHi),
        hoursToCollapse: Number(p.hoursToCollapse),
        creaturesHi: Number(p.creaturesHi),
        observerInside: p.observerInside,
    }).level;
}
