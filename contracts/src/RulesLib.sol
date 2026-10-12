// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Game, Portal, Config, PortalStatus, Action, Refusal, RiskLevel, MAX_OPEN_PORTALS} from "./PortalLabTypes.sol";
import {RiskLib} from "./RiskLib.sol";

/// @title RulesLib — action feasibility checks (SPEC §4.2–§4.3).
/// @notice Pure, stateless library. Returns the first applicable `Refusal`
/// code; `None` (0) means the action is allowed. The check order is part of
/// the specification: a player always sees the most meaningful reason when
/// multiple preconditions fail simultaneously.
library RulesLib {
    /// @notice Check whether `a` may be performed on portal `slot` in game `g`.
    /// @dev Steps in fixed order; first match wins.
    ///   1. Game must be active.
    ///   2. Slot index must be in range.
    ///   3. Slot must not be empty.
    ///   4. Action-specific state checks (see SPEC table).
    ///   5. Crew availability (SendObserver / SendRescuer only).
    ///   6. Power cost.
    ///   7. Return None.
    ///
    /// Power is checked last: the player needs to know FIRST whether the action
    /// is structurally possible, not whether they can afford it today.
    function check(Game memory g, Portal memory p, Config memory c, uint8 slot, Action a)
        internal
        pure
        returns (Refusal)
    {
        // 1. Active game.
        if (g.startedAt == 0 || g.finished) return Refusal.GameNotActive;

        // 2. Valid slot index.
        if (slot >= MAX_OPEN_PORTALS) return Refusal.InvalidSlot;

        // 3. Non-empty slot.
        if (p.status == PortalStatus.Empty) return Refusal.PortalEmpty;

        // 4. Action-specific state checks (table order is the spec).
        if (a == Action.Stabilize || a == Action.Destabilize) {
            if (!p.surveyed) return Refusal.NotSurveyed;
        } else if (a == Action.SendObserver) {
            if (p.observerInside) return Refusal.ObserverAlreadyInside;
            // Risk only checked when surveyed; sending an observer IS the survey.
            if (p.surveyed) {
                (, RiskLevel lvl) = RiskLib.portalRisk(p);
                if (lvl == RiskLevel.Critical) return Refusal.RiskTooHigh;
            }
        } else if (a == Action.RecallObserver) {
            if (!p.observerInside) return Refusal.NoObserverInside;
            // Recalling while a Pyth callback is in flight would orphan the result.
            if (p.surveyPending) return Refusal.SurveyPending;
        } else if (a == Action.SendRescuer) {
            // A rescuer may be sent into an UNSURVEYED portal — that is the risk
            // the keeper takes when time runs out before a survey can (ticket
            // 2.2). So no NotSurveyed gate here.
            if (p.rescuerInside) return Refusal.RescuerAlreadyInside;
            // "No creatures" can only be asserted once the count is KNOWN. While
            // it is unknown the emptiness is exactly the gamble we allow.
            if (p.creaturesKnown && p.creatures == 0) return Refusal.NoCreatures;
            // ANTI-DEADLOCK — WHY THE CAUTIOUS RISK GATE IS FOR THE RESCUER ONLY.
            // A surveyed portal is gated on its exact risk. An unsurveyed one is
            // gated on a cautious estimate from the worst corner of its ranges
            // (RiskLib.cautiousPortalRisk): sending a rescuer blind into what may
            // be a lethal portal must be forbidden when the worst case is Critical.
            //
            // This cautious gate MUST NOT be extended to SendObserver. Observing
            // IS surveying — looking is always allowed, and the risk of an
            // unsurveyed portal is checked only after it becomes surveyed (see the
            // SendObserver branch above). If we also gated the observer on the
            // cautious estimate, a dangerous unsurveyed portal would become a dead
            // end: no one could be sent in (rescuer AND observer both blocked), and
            // it could not be stabilised either, because Stabilize requires a
            // survey that can no longer happen. The portal would be permanently
            // unreachable and the player would have no move at all. Keeping the
            // observer ungated leaves survey — and therefore stabilise, and a real
            // reading of the true numbers — always open as the way out.
            RiskLevel lvl;
            if (p.surveyed) {
                (, lvl) = RiskLib.portalRisk(p);
            } else {
                (, lvl) = RiskLib.cautiousPortalRisk(p);
            }
            if (lvl == RiskLevel.Critical) return Refusal.RiskTooHigh;
        } else if (a == Action.RecallRescuer) {
            if (!p.rescuerInside) return Refusal.NoRescuerInside;
        } else if (a == Action.Evacuate) {
            // Blind evacuation is allowed too (ticket 2.2): no NotSurveyed gate.
            if (p.creaturesKnown && p.creatures == 0) return Refusal.NoCreatures;
            if (!p.rescuerInside) return Refusal.NoRescuerInside;
        } else if (a == Action.Close) {
            // Time threshold is always known (SPEC §3.1); stability is only
            // known after survey.
            bool allowed = p.hoursToCollapse <= c.closeHoursAtMost;
            if (!allowed && p.surveyed) {
                allowed = p.stability < c.closeStabilityBelow;
            }
            if (!allowed) return Refusal.NotUnstableEnough;
        }
        // ToggleQuestioned: no state checks.

        // 5. Crew availability.
        if (a == Action.SendObserver && g.observersFree == 0) return Refusal.NoObserverFree;
        if (a == Action.SendRescuer && g.rescuersFree == 0) return Refusal.NoRescuerFree;

        // 6. Power cost.
        if (g.power < cost(c, a)) return Refusal.NotEnoughPower;

        return Refusal.None;
    }

    /// @notice Power cost of action `a`.
    function cost(Config memory c, Action a) internal pure returns (uint16) {
        if (a == Action.ToggleQuestioned) return c.costToggleQuestioned;
        if (a == Action.Stabilize) return c.costStabilize;
        if (a == Action.Destabilize) return c.costDestabilize;
        if (a == Action.SendObserver) return c.costSendObserver;
        if (a == Action.RecallObserver) return c.costRecallObserver;
        if (a == Action.SendRescuer) return c.costSendRescuer;
        if (a == Action.RecallRescuer) return c.costRecallRescuer;
        if (a == Action.Evacuate) return c.costEvacuate;
        return c.costClose;
    }
}
