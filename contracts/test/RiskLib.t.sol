// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiskLib} from "../src/RiskLib.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Portal, PortalStatus, PortalType, RiskLevel} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";

/// @title RiskLibTest — canonical vectors for the fixed-point risk maths.
/// @notice Every expected value below comes from the reviewer's reference model,
/// which matched the old fractional version on 776,286 input combinations. The
/// numbers are NOT to be recomputed or "corrected": a failing test means the
/// implementation is wrong, not the number.
contract RiskLibTest is Test {
    PortalLab internal lab;

    function setUp() public {
        lab = new PortalLab(DefaultConfig.config(), DefaultConfig.portalTypeParams(), new DeterministicSource(0));
    }

    // 1. Anchor cases.
    function test_AnchorScores() public pure {
        assertEq(RiskLib.score(100, 0, 48, 0), 0);
        assertEq(RiskLib.score(0, 100, 0, 5), 100);
        assertEq(RiskLib.score(50, 50, 24, 0), 50);
        assertEq(RiskLib.score(10, 80, 2, 3), 97);
        assertEq(RiskLib.score(40, 40, 6, 1), 71);
    }

    // 2. Level boundaries with no factors.
    function test_LevelBoundariesNoFactors() public pure {
        _assertScoreLevel(42, 0, 48, 0, 29, RiskLevel.Low);
        _assertScoreLevel(40, 0, 48, 0, 30, RiskLevel.Medium);
        _assertScoreLevel(20, 62, 48, 0, 59, RiskLevel.Medium);
        _assertScoreLevel(20, 65, 48, 0, 60, RiskLevel.High);
        _assertScoreLevel(0, 83, 48, 0, 84, RiskLevel.High);
        _assertScoreLevel(0, 88, 48, 0, 85, RiskLevel.Critical);
    }

    // 3. Exact half on the boundary rounds up (raw values are 29.5 / 59.5 / 84.5).
    function test_HalfRoundsUp() public pure {
        assertEq(RiskLib.score(41, 0, 48, 0), 30);
        assertEq(RiskLib.score(20, 15, 12, 0), 60);
        assertEq(RiskLib.score(21, 100, 12, 0), 85);
    }

    // 4. The 84/85 gate across every combination of factors.
    function test_Gate84_85_WithFactors() public pure {
        _assertScoreLevel(20, 37, 2, 0, 84, RiskLevel.High); // time <= 2
        _assertScoreLevel(20, 43, 2, 0, 85, RiskLevel.Critical); // time <= 2
        _assertScoreLevel(20, 64, 6, 1, 84, RiskLevel.High); // time <= 6, lives
        _assertScoreLevel(20, 69, 6, 1, 85, RiskLevel.Critical); // time <= 6, lives
        _assertScoreLevel(3, 0, 6, 1, 84, RiskLevel.High); // time <= 6, crit instability, lives
        _assertScoreLevel(0, 0, 6, 1, 85, RiskLevel.Critical); // time <= 6, crit instability, lives
    }

    // 5. levelOf thresholds.
    function test_LevelOf() public pure {
        assertEq(uint256(RiskLib.levelOf(0)), uint256(RiskLevel.Low));
        assertEq(uint256(RiskLib.levelOf(29)), uint256(RiskLevel.Low));
        assertEq(uint256(RiskLib.levelOf(30)), uint256(RiskLevel.Medium));
        assertEq(uint256(RiskLib.levelOf(59)), uint256(RiskLevel.Medium));
        assertEq(uint256(RiskLib.levelOf(60)), uint256(RiskLevel.High));
        assertEq(uint256(RiskLib.levelOf(84)), uint256(RiskLevel.High));
        assertEq(uint256(RiskLib.levelOf(85)), uint256(RiskLevel.Critical));
        assertEq(uint256(RiskLib.levelOf(100)), uint256(RiskLevel.Critical));
    }

    // 6. portalRisk lifecycle and lives counting.
    function test_PortalRiskEmpty() public pure {
        Portal memory p;
        p.status = PortalStatus.Empty;
        (uint8 s, RiskLevel level) = RiskLib.portalRisk(p);
        assertEq(s, 0);
        assertEq(uint256(level), uint256(RiskLevel.None));
    }

    function test_PortalRiskUnsurveyed() public pure {
        Portal memory p;
        p.status = PortalStatus.Open;
        p.surveyed = false;
        // Non-zero numeric fields must be ignored while unsurveyed.
        p.stability = 10;
        p.energy = 90;
        p.hoursToCollapse = 2;
        p.creatures = 3;
        (uint8 s, RiskLevel level) = RiskLib.portalRisk(p);
        assertEq(s, 0);
        assertEq(uint256(level), uint256(RiskLevel.Unknown));
    }

    function test_PortalRiskCountsLivesSameWhoeverIsInside() public pure {
        // Surveyed: stability 40, energy 40, 6 hours, 0 creatures, observer inside -> 71.
        Portal memory observer;
        observer.status = PortalStatus.Open;
        observer.surveyed = true;
        observer.stability = 40;
        observer.energy = 40;
        observer.hoursToCollapse = 6;
        observer.creatures = 0;
        observer.observerInside = true;
        (uint8 s1, RiskLevel l1) = RiskLib.portalRisk(observer);
        assertEq(s1, 71);
        assertEq(uint256(l1), uint256(RiskLevel.High));

        // Same portal but one creature and no observer -> also 71.
        Portal memory creature;
        creature.status = PortalStatus.Open;
        creature.surveyed = true;
        creature.stability = 40;
        creature.energy = 40;
        creature.hoursToCollapse = 6;
        creature.creatures = 1;
        creature.observerInside = false;
        (uint8 s2, RiskLevel l2) = RiskLib.portalRisk(creature);
        assertEq(s2, 71);
        assertEq(uint256(l2), uint256(RiskLevel.High));
    }

    // 7. Hours beyond the window.
    function test_HoursBeyondWindow() public pure {
        assertEq(RiskLib.score(100, 0, 60, 0), 0);
        assertEq(RiskLib.score(100, 0, 1000, 0), 0);
    }

    // 8. Invalid input reverts.
    function test_RevertsOnInvalidStability() public {
        vm.expectRevert(RiskLib.InvalidRiskInput.selector);
        this.callScore(101, 0, 48, 0);
    }

    function test_RevertsOnInvalidEnergy() public {
        vm.expectRevert(RiskLib.InvalidRiskInput.selector);
        this.callScore(0, 101, 48, 0);
    }

    /// @dev External wrapper so `vm.expectRevert` catches the library revert.
    function callScore(uint8 stability, uint8 energy, uint16 hoursToCollapse, uint8 lives)
        external
        pure
        returns (uint8)
    {
        return RiskLib.score(stability, energy, hoursToCollapse, lives);
    }

    /// Base rounding (step 4) must be half-up: truncating it changes the score on
    /// these inputs. Found by mutation testing.
    function test_BaseRoundingIsHalfUp() public pure {
        assertEq(RiskLib.score(20, 0, 14, 2), 62);
        assertEq(RiskLib.score(20, 75, 8, 2), 83);
    }

    /// The lives factor is capped at 30%: from 6 lives on, adding more changes
    /// nothing. Raising the cap to 31% changes the score to 59.
    function test_LivesFactorCappedAt30() public pure {
        assertEq(RiskLib.score(20, 0, 48, 6), 58);
        assertEq(RiskLib.score(20, 0, 48, 10), 58);
    }

    // 9. Fuzz properties (true under half-up rounding at each step).
    function testFuzz_ScoreNeverExceeds100(uint8 stability, uint8 energy, uint16 hrs, uint8 lives)
        public
        pure
    {
        stability = uint8(bound(stability, 0, 100));
        energy = uint8(bound(energy, 0, 100));
        hrs = uint16(bound(hrs, 0, 200));
        lives = uint8(bound(lives, 0, 10));
        assertLe(RiskLib.score(stability, energy, hrs, lives), 100);
    }

    function testFuzz_LowerStabilityNeverLowersScore(
        uint8 stability,
        uint8 energy,
        uint16 hrs,
        uint8 lives
    ) public pure {
        stability = uint8(bound(stability, 1, 100));
        energy = uint8(bound(energy, 0, 100));
        hrs = uint16(bound(hrs, 0, 200));
        lives = uint8(bound(lives, 0, 10));
        uint8 base = RiskLib.score(stability, energy, hrs, lives);
        uint8 lower = RiskLib.score(stability - 1, energy, hrs, lives);
        assertGe(lower, base);
    }

    function testFuzz_MoreLivesNeverLowersScore(
        uint8 stability,
        uint8 energy,
        uint16 hrs,
        uint8 lives
    ) public pure {
        stability = uint8(bound(stability, 0, 100));
        energy = uint8(bound(energy, 0, 100));
        hrs = uint16(bound(hrs, 0, 200));
        lives = uint8(bound(lives, 0, 9));
        uint8 base = RiskLib.score(stability, energy, hrs, lives);
        uint8 more = RiskLib.score(stability, energy, hrs, lives + 1);
        assertGe(more, base);
    }

    function testFuzz_FewerHoursNeverLowersScore(
        uint8 stability,
        uint8 energy,
        uint16 hrs,
        uint8 lives
    ) public pure {
        stability = uint8(bound(stability, 0, 100));
        energy = uint8(bound(energy, 0, 100));
        hrs = uint16(bound(hrs, 1, 200));
        lives = uint8(bound(lives, 0, 10));
        uint8 base = RiskLib.score(stability, energy, hrs, lives);
        uint8 fewer = RiskLib.score(stability, energy, hrs - 1, lives);
        assertGe(fewer, base);
    }

    // 10. The PortalLab wrapper returns the same score and level as the library.
    function test_WrapperMatchesLibrary() public view {
        _assertWrapper(50, 50, 24, 0);
        _assertWrapper(10, 80, 2, 3);
        _assertWrapper(0, 88, 48, 0);
    }

    function _assertScoreLevel(
        uint8 stability,
        uint8 energy,
        uint16 hrs,
        uint8 lives,
        uint8 expectedScore,
        RiskLevel expectedLevel
    ) internal pure {
        uint8 s = RiskLib.score(stability, energy, hrs, lives);
        assertEq(s, expectedScore);
        assertEq(uint256(RiskLib.levelOf(s)), uint256(expectedLevel));
    }

    function _assertWrapper(uint8 stability, uint8 energy, uint16 hrs, uint8 lives) internal view {
        (uint8 ws, RiskLevel wl) = lab.riskScore(stability, energy, hrs, lives);
        uint8 ls = RiskLib.score(stability, energy, hrs, lives);
        assertEq(ws, ls);
        assertEq(uint256(wl), uint256(RiskLib.levelOf(ls)));
    }
}
