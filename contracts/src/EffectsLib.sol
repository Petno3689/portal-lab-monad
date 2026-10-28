// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    Game,
    Portal,
    Config,
    PortalTypeParams,
    PortalStatus,
    Action,
    SPAWN_DEBT_MAX,
    MAX_RESCUERS,
    rescuerReadyAt,
    setRescuerReadyAt
} from "./PortalLabTypes.sol";
import {RandomStub} from "./RandomStub.sol";

/// @dev Raised if a blind-empty rescuer finds no free cooldown cell. This cannot
/// happen while live cells never outnumber `rescuersTotal <= MAX_RESCUERS`, so it
/// signals a broken invariant — reverting is correct, silently dropping the
/// rescuer's recovery is not.
error NoFreeRescuerCell();

/// @title EffectsLib — applies an already-allowed action to game state (SPEC §4.2, §4.4).
/// @notice Pure, stateless library. Each call takes the current `Game` and
/// `Portal` (plus config and the acting portal's type parameters), mutates them
/// and returns the new values together with an `Outcome` describing the
/// event-relevant results (creatures rescued, deaths, HP moved). It never reads
/// or writes storage — `PortalLab.act` reads from storage, calls this, and
/// writes the result back.
///
/// @dev Feasibility is NOT re-checked here: the caller runs `RulesLib.check`
/// first and only invokes this when the action is allowed.
///
/// IMPORTANT: all divisions in this library truncate (round toward zero). This
/// is deliberate and different from the risk arithmetic (`RiskLib`, half-up):
/// action strength does not need bit-exact precision, and truncation is simpler
/// and cheaper. Do NOT "fix" these to round.
library EffectsLib {
    /// @dev Base stability shift of Stabilize/Destabilize before the per-type
    /// multiplier. 25 × multiplierPct / 100 (truncated).
    uint256 private constant STABILITY_STEP = 25;
    /// @dev Fixed energy shift of Stabilize/Destabilize (no multiplier).
    uint8 private constant ENERGY_STEP = 10;

    /// @dev Salt for the creature-count draw in a blind rescue reveal.
    /// Survey (this library) uses salts 0, 1, 2 for energy, stability, creatures.
    /// Salt 3 keeps the blind-rescue draw uncorrelated with survey draws.
    /// TimeLib also uses 3/4/5 for spawn draws, but through `epochSeed()` with a
    /// domain tag — the byte layout of `abi.encode(epochSeed, salt)` differs from
    /// `abi.encode(word, salt)` used here, so there is no collision between the two.
    uint8 private constant BLIND_RESCUE_SALT = 3;

    /// @notice Event-relevant results of an action, filled only for the action
    /// that produces them (zero otherwise).
    struct Outcome {
        uint8 rescued; // Evacuate: creatures pulled out
        uint16 hpGained; // Evacuate: HP actually healed (after the cap)
        uint8 deaths; // Close: beings lost (creatures + crew inside)
        uint16 hpLost; // Close: HP actually lost
        bool surveyDone; // SendObserver: a survey was performed this call
        bool surveyPrecise; // SendObserver: it produced an exact value (true) or only narrowed (false)
        bool rescuerBlindMiss; // SendRescuer: a blind entry found an empty portal; the rescuer did not enter
        uint32 rescuerReadyAtHour; // SendRescuer blind miss: game hour the rescuer rejoins the pool
        uint8 leftBehind; // Evacuate: creatures still inside after a blind evacuation (SPEC §4.4)
    }

    /// @notice Apply `a` to game `g` and portal `p`.
    /// @param g Current game (aged to now by the caller in ticket 1.6).
    /// @param p Current portal.
    /// @param c Immutable game configuration.
    /// @param tp Type parameters of `p` (drives action strength via
    ///   `actionMultiplierPct`: 100 normal, 200 resonant).
    /// @param a The action to apply (already allowed).
    /// @param player The acting player, seed for the survey RNG stub.
    /// @return The updated game, the updated portal, and the outcome.
    function applyAction(
        Game memory g,
        Portal memory p,
        Config memory c,
        PortalTypeParams memory tp,
        Action a,
        address player
    ) internal pure returns (Game memory, Portal memory, Outcome memory outcome) {
        if (a == Action.ToggleQuestioned) {
            p.status = p.status == PortalStatus.Open ? PortalStatus.Questioned : PortalStatus.Open;
        } else if (a == Action.Stabilize) {
            // stability += 25 × mult / 100 (truncated), capped at 100; energy -= 10, floored at 0.
            uint256 step = (STABILITY_STEP * tp.actionMultiplierPct) / 100;
            uint256 s = uint256(p.stability) + step;
            p.stability = s > 100 ? 100 : uint8(s);
            p.energy = p.energy >= ENERGY_STEP ? p.energy - ENERGY_STEP : 0;
        } else if (a == Action.Destabilize) {
            // stability -= 25 × mult / 100 (truncated), floored at 0; energy += 10, capped at 100.
            uint256 step = (STABILITY_STEP * tp.actionMultiplierPct) / 100;
            p.stability = uint256(p.stability) > step ? uint8(uint256(p.stability) - step) : 0;
            uint256 e = uint256(p.energy) + ENERGY_STEP;
            p.energy = e > 100 ? 100 : uint8(e);
        } else if (a == Action.SendObserver) {
            // Placing the observer only. Sending one into an UNSURVEYED portal is
            // the survey, but the survey draws a random word and is therefore
            // two-phase (SPEC §6.3): PortalLab.act handles that case directly
            // (commit here-equivalent + request), and PortalLab.receiveWord calls
            // `EffectsLib.survey` on delivery. This branch is thus reached only for
            // an already-surveyed portal (a bare observer placement, no roll), so
            // it never surveys and never touches `surveyPending`.
            p.observerInside = true;
            g.observersFree -= 1;
        } else if (a == Action.RecallObserver) {
            p.observerInside = false;
            g.observersFree += 1;
        } else if (a == Action.SendRescuer) {
            // Blind entry (!creaturesKnown) is two-phase after Ticket 4.6 and never
            // reaches this branch. PortalLab.act intercepts it at commit and routes
            // the reveal through applyBlindRescuerReveal. This branch handles sighted
            // rescues only (creaturesKnown == true).
            p.rescuerInside = true;
            g.rescuersFree -= 1;
        } else if (a == Action.RecallRescuer) {
            p.rescuerInside = false;
            g.rescuersFree += 1;
        } else if (a == Action.Evacuate) {
            // A surveyed portal is emptied completely. A portal evacuated BLIND —
            // entered without a survey, so `surveyed` is still false even though a
            // blind entry made the count known — always leaves ONE behind: in the
            // dark you can never account for the last one.
            //
            // DELIBERATE, DO NOT "FIX": a second blind evacuation of the leftover
            // saves n-1 = 0, i.e. nobody. The only way to bring the last creature
            // out is to survey the portal first (which makes `surveyed` true and
            // this branch take the full count). That is the intended, legitimate
            // route — not a bug to be smoothed over.
            uint8 saved = p.surveyed ? p.creatures : (p.creatures > 0 ? p.creatures - 1 : 0);
            p.creatures -= saved;
            p.rescuerInside = false;
            g.rescuersFree += 1;
            uint256 healed = uint256(c.healPerCreature) * saved;
            uint256 newHp = uint256(g.hp) + healed;
            if (newHp > c.hpMax) newHp = c.hpMax;
            outcome.rescued = saved;
            outcome.hpGained = uint16(newHp - g.hp); // actual gain after the cap
            outcome.leftBehind = p.creatures; // 0 when surveyed; 1 (or 0) when blind
            g.hp = uint16(newHp);
            g.creaturesRescued += saved; // only living exits count (SPEC §15)
        } else {
            // Action.Close.
            // Deaths from creatures: exact count if creatures are known, else
            // creaturesHi (upper bound — the player chose to close without
            // knowing the full count, so they pay for the worst case).
            // NOTE: collapse uses the midpoint + hpCollapseBase; close uses
            // creaturesHi + no base. Two different rules on purpose (SPEC §4.4):
            // a collapse is an accident (pay base + midpoint); a close is a
            // player decision (pay per-death × worst-case, no base). Never
            // "align" these two formulas — they model different situations.
            uint256 deathsCreatures = p.creaturesKnown ? uint256(p.creatures) : uint256(p.creaturesHi);
            uint256 deaths = deathsCreatures;
            if (p.observerInside) deaths += 1;
            if (p.rescuerInside) deaths += 1;

            uint16 hpLost = 0;
            if (deaths > 0) {
                uint256 loss = uint256(c.hpCollapsePerDeath) * deaths;
                uint256 hpBefore = uint256(g.hp);
                uint256 actual = hpBefore > loss ? loss : hpBefore; // min(loss, hp before the hit)
                g.hp = uint16(hpBefore - actual);
                hpLost = uint16(actual);
            }
            outcome.deaths = uint8(deaths);
            outcome.hpLost = hpLost;

            // Closing a portal adds spawn pressure (SPEC §7): "close one, several
            // open". This bonus is added ONLY on the Close ACTION, never on a
            // collapse — the deterministic collapses handled in TimeLib do not
            // touch spawnDebt. Saturate at SPAWN_DEBT_MAX so it cannot overflow.
            uint256 debt = uint256(g.spawnDebt) + uint256(c.closePressureBonus);
            g.spawnDebt = debt > SPAWN_DEBT_MAX ? uint32(SPAWN_DEBT_MAX) : uint32(debt);

            // Crew inside dies with the portal and does NOT return to the pool
            // (SPEC §4.3): observersFree / rescuersFree are deliberately not
            // incremented here.
            g.openPortals -= 1;

            // The slot is freed: a fresh, zeroed portal (status == Empty).
            Portal memory cleared;
            return (g, cleared, outcome);
        }

        return (g, p, outcome);
    }

    /// @notice REVEAL phase of a two-phase blind rescue (Ticket 4.6). Determines the
    /// creature count from the delivered `word`, collapses the range, and either puts
    /// the rescuer inside (n > 0) or schedules a cooldown cell (n == 0).
    ///
    /// @dev Power and `rescuersFree` are handled by the CALLER before this call:
    ///   - In-epoch (PortalLab._revealBlindRescue): power was deducted and
    ///     rescuersFree was decremented at commit — this function does NOT touch them.
    ///   - Epoch-crossing (PortalLab._performDeferredAction): power is deducted there
    ///     and rescuersFree is decremented before calling this function.
    ///
    /// In both cases this function only handles the outcome of the count roll.
    function applyBlindRescuerReveal(
        Game memory g,
        Portal memory p,
        Config memory c,
        uint256 word
    ) internal pure returns (Game memory, Portal memory, Outcome memory outcome) {
        uint8 n = RandomStub.inRange(_fromWord(word, BLIND_RESCUE_SALT), p.creaturesLo, p.creaturesHi);
        p.creatures = n;
        p.creaturesLo = n;
        p.creaturesHi = n;
        p.creaturesKnown = true;

        if (n == 0) {
            // The gamble did not pay off: the portal was empty. The rescuer never
            // enters; they spend `rescuerCooldownHours` recovering (SPEC §4.3).
            // rescuersFree was already decremented at commit (or by the caller for
            // epoch-crossing) — only the cooldown cell is written here.
            uint32 readyAt = uint32(uint256(g.hoursElapsed) + uint256(c.rescuerCooldownHours));
            bool placed = false;
            for (uint8 cell = 0; cell < MAX_RESCUERS; cell++) {
                if (rescuerReadyAt(g, cell) == 0) {
                    setRescuerReadyAt(g, cell, readyAt);
                    placed = true;
                    break;
                }
            }
            if (!placed) revert NoFreeRescuerCell();
            outcome.rescuerBlindMiss = true;
            outcome.rescuerReadyAtHour = readyAt;
        } else {
            p.rescuerInside = true;
            // rescuersFree already decremented by the caller
        }
        return (g, p, outcome);
    }

    /// @notice Apply a survey to `p` using a delivered random `word` (SPEC §6.3).
    /// Returns the updated portal and whether the survey produced an exact value
    /// (`precise == true`) or merely narrowed the ranges (`precise == false`, a
    /// deaf portal's first survey). Called by `PortalLab.receiveWord` in the
    /// reveal phase of the two-phase survey.
    ///
    /// Precise types (`tp.surveyPrecise`) — and deaf portals already narrowed by
    /// an earlier survey (`narrowedOnce`) — read the exact
    /// energy/stability/creatures inside their CURRENT ranges and collapse each
    /// range to a point (`lo == hi == value`), so the struct never holds two
    /// contradicting sources of truth. `surveyed` becomes true.
    ///
    /// A deaf portal's first survey only halves each range around a random
    /// centre, sets `narrowedOnce` and leaves `surveyed == false`: a second visit
    /// is required (SPEC §3.1 — this is the price of the deaf type).
    ///
    /// @dev The three per-parameter draws come from the ONE word via
    /// `_fromWord(word, salt)` (Ticket 4.4 §2.3); the salt keeps energy, stability
    /// and creatures uncorrelated. `RandomStub.inRange` maps each onto its range,
    /// unchanged — it is the distribution contract and must not be touched.
    function survey(Portal memory p, Config memory, PortalTypeParams memory tp, uint256 word)
        internal
        pure
        returns (Portal memory, bool precise)
    {
        bool exact = tp.surveyPrecise || p.narrowedOnce;

        if (exact) {
            // Different salts keep the three parameters uncorrelated.
            uint8 energy = RandomStub.inRange(_fromWord(word, 0), p.energyLo, p.energyHi);
            uint8 stability = RandomStub.inRange(_fromWord(word, 1), p.stabilityLo, p.stabilityHi);
            uint8 creatures = RandomStub.inRange(_fromWord(word, 2), p.creaturesLo, p.creaturesHi);
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
            return (p, true);
        }

        // Deaf first pass: halve each of the three ranges around a random
        // centre and mark the portal. `surveyed` stays false.
        p.narrowedOnce = true;
        (p.energyLo, p.energyHi) = _narrow(p.energyLo, p.energyHi, _fromWord(word, 0));
        (p.stabilityLo, p.stabilityHi) = _narrow(p.stabilityLo, p.stabilityHi, _fromWord(word, 1));
        (p.creaturesLo, p.creaturesHi) = _narrow(p.creaturesLo, p.creaturesHi, _fromWord(word, 2));
        return (p, false);
    }

    /// @dev Derive one sub-draw from the delivered word and a `salt` (Ticket 4.4
    /// §2.3). Replaces the stub's `draw(player, nonce, salt)`: the per-request
    /// uniqueness now lives in the word itself (from the random source), so the
    /// derivation needs only the word and the salt. Feeds `RandomStub.inRange`.
    function _fromWord(uint256 word, uint8 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(word, salt)));
    }

    /// @dev Halve `[lo, hi]` around a random centre `c` inside it: new half-width
    /// `w = (hi - lo + 1) / 4`, new bounds `[c - w, c + w]` clipped to the old
    /// `lo`/`hi`. Truncating division (round toward zero) like the rest of
    /// EffectsLib.
    function _narrow(uint8 lo, uint8 hi, uint256 rnd) private pure returns (uint8, uint8) {
        uint8 centre = RandomStub.inRange(rnd, lo, hi);
        uint256 w = (uint256(hi) - uint256(lo) + 1) / 4;
        uint256 lowCand = uint256(centre) > w ? uint256(centre) - w : 0;
        uint8 newLo = lowCand < lo ? lo : uint8(lowCand);
        uint256 highCand = uint256(centre) + w;
        uint8 newHi = highCand > hi ? hi : uint8(highCand);
        return (newLo, newHi);
    }
}
