// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Portal, PortalStatus, RiskLevel} from "./PortalLabTypes.sol";

/// @title RiskLib — fixed-point portal risk, canonical Solidity implementation.
/// @notice Pure risk arithmetic (SPEC §4.1). All intermediate values are in
/// fixed point with scale `S = 1e18`; every division rounds half up. The exact
/// order of operations and roundings is part of the specification: the
/// TypeScript mirror (ticket 1.3) must reproduce it bit for bit, because the
/// level thresholds are gates (critical risk forbids sending people) where a
/// one-unit difference on a boundary changes game behaviour, not just a display.
///
/// @dev The contract returns only the score and level. The per-factor breakdown
/// (how much instability, energy, time, lives each contributed) is intentionally
/// NOT computed here: it is needed only by the UI, and computing it on-chain
/// would cost gas for no in-contract use. The TS mirror produces the breakdown.
library RiskLib {
    /// @notice Reverts when `stability` or `energy` exceeds 100.
    error InvalidRiskInput();

    /// @dev Fixed-point scale.
    uint256 private constant S = 1e18;

    /// @dev Non-negative division rounding half up: (a + c/2) / c.
    function divHalfUp(uint256 a, uint256 c) internal pure returns (uint256) {
        return (a + c / 2) / c;
    }

    /// @notice Compute the risk score (0..100) for an already-aged portal
    /// snapshot. Ageing to the current moment is ticket 1.6's job; this function
    /// only evaluates the passed fields.
    /// @param stability Portal stability, 0..100.
    /// @param energy Portal energy load, 0..100.
    /// @param hoursToCollapse Hours until the portal collapses.
    /// @param lives Living beings inside (creatures + observer + rescuer).
    /// @return The risk score, capped at 100.
    function score(uint8 stability, uint8 energy, uint16 hoursToCollapse, uint8 lives)
        internal
        pure
        returns (uint8)
    {
        if (stability > 100 || energy > 100) revert InvalidRiskInput();

        // 1–3. The three weighted base components, in fixed point.
        uint256 inst = (uint256(100) - stability) * S;
        uint256 en = uint256(energy) * S;
        uint256 tp;
        if (hoursToCollapse >= 48) {
            tp = 0;
        } else {
            tp = 100 * S - divHalfUp(uint256(hoursToCollapse) * 100 * S, 48);
        }

        // 4. Weighted base: instability 0.5, energy 0.3, time deficit 0.2.
        uint256 r = divHalfUp(inst * 50 + en * 30 + tp * 20, 100);

        // 5. Time factor — mutually exclusive branches.
        if (hoursToCollapse <= 2) {
            r = r + divHalfUp((100 * S - r) * 45, 100);
        } else if (hoursToCollapse <= 6) {
            r = r + divHalfUp((100 * S - r) * 20, 100);
        }

        // 6. Critical instability factor.
        if (stability < 20) {
            r = r + divHalfUp((100 * S - r) * 35, 100);
        }

        // 7. Lives factor.
        if (lives > 0) {
            uint256 k = 8 + 4 * uint256(lives);
            if (k > 30) k = 30;
            r = r + divHalfUp((100 * S - r) * k, 100);
        }

        // 8. Back to an integer 0..100, capped.
        uint256 result = divHalfUp(r, S);
        if (result > 100) result = 100;
        return uint8(result);
    }

    /// @notice Map a risk score to its level. Thresholds: 0–29 Low, 30–59
    /// Medium, 60–84 High, 85–100 Critical.
    function levelOf(uint8 s) internal pure returns (RiskLevel) {
        if (s < 30) return RiskLevel.Low;
        if (s < 60) return RiskLevel.Medium;
        if (s < 85) return RiskLevel.High;
        return RiskLevel.Critical;
    }

    /// @notice Risk of a stored portal. Handles the lifecycle cases first:
    /// an empty slot has no risk; an unsurveyed portal's true values do not
    /// exist yet, so its level is `Unknown` and its numeric fields are not read.
    /// @dev `p` is assumed already aged to the current moment (ticket 1.6).
    function portalRisk(Portal memory p) internal pure returns (uint8 s, RiskLevel level) {
        if (p.status == PortalStatus.Empty) return (0, RiskLevel.None);
        if (!p.surveyed) return (0, RiskLevel.Unknown);

        uint8 lives = p.creatures;
        if (p.observerInside) lives += 1;
        if (p.rescuerInside) lives += 1;

        s = score(p.stability, p.energy, p.hoursToCollapse, lives);
        level = levelOf(s);
    }

    /// @notice Cautious risk of an UNSURVEYED portal, read from the worst corner
    /// of its published ranges. A surveyed portal's exact values do not exist yet,
    /// so `portalRisk` returns `Unknown` and cannot gate; but a rescuer can now be
    /// sent in blind (ticket 2.2), and blind is where a keeper needs protecting
    /// from the worst case. This estimate assumes every unknown is as bad as its
    /// range allows:
    ///   - stability = `stabilityLo` (least stable — highest risk),
    ///   - energy    = `energyHi`    (most energetic — highest risk),
    ///   - hoursToCollapse as-is     (always exact, never hidden),
    ///   - lives     = `creaturesHi` (most inhabitants) + any observer already
    ///                 inside + the rescuer about to enter.
    /// `hoursToCollapse` needs no worst-casing: it is public and exact even before
    /// survey (SPEC §3.1).
    /// @dev Used only for the SendRescuer gate on an unsurveyed portal. It is
    /// DELIBERATELY not applied to SendObserver — see the anti-deadlock note in
    /// `RulesLib.check`.
    function cautiousPortalRisk(Portal memory p) internal pure returns (uint8 s, RiskLevel level) {
        if (p.status == PortalStatus.Empty) return (0, RiskLevel.None);

        uint8 lives = p.creaturesHi;
        if (p.observerInside) lives += 1;
        lives += 1; // the rescuer we are about to send in

        s = score(p.stabilityLo, p.energyHi, p.hoursToCollapse, lives);
        level = levelOf(s);
    }
}
