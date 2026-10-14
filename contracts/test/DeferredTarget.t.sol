// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Game, Portal, PortalType, PortalStatus, Action, Refusal} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @title DeferredTargetTest — a deferred action targets the PORTAL (by id), not
/// the slot: if the target collapses and a newborn takes the slot while the word
/// is in flight, the action is cancelled as PortalEmpty and the newborn is
/// untouched.
contract DeferredTargetTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    address internal player;

    uint40 internal constant BASE = 1_000_000;
    uint32 internal SPH;
    uint16 internal constant OLD_ID = 7;
    uint32 internal constant REVEAL_HOUR = 13;

    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);
        SPH = DefaultConfig.config().secPerHour;
        vm.warp(BASE);
    }

    function _game() internal {
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 2;
        harness.setGame(player, g);
        harness.setCoverage(player, uint256(keccak256("seed")), 0);
    }

    function _longLived(uint16 id, uint16 collapseIn, bool surveyed) internal pure returns (Portal memory p) {
        p.id = id;
        p.status = PortalStatus.Open;
        p.portalType = PortalType.LongLived;
        p.snapshotAt = BASE;
        p.hoursToCollapse = collapseIn;
        p.creaturesKnown = true;
        p.surveyed = surveyed;
        p.creatures = 2;
        p.creaturesLo = 2;
        p.creaturesHi = 2;
    }

    /// Slot 0 stays occupied for good, slot 1 holds the target that collapses at
    /// hour 1; the first birth (hour 10) lands in slot 1.
    function _setupTargetAt1(bool surveyed) internal {
        _game();
        harness.setPortal(player, 0, _longLived(5, 500, true));
        harness.setPortal(player, 1, _longLived(OLD_ID, 1, surveyed));
    }

    function _defer(uint8 slot, Action a) internal returns (uint64 reqId) {
        vm.warp(BASE + SPH);
        harness.act(slot, a);
        assertTrue(harness.getPending(player).active, "deferred");
        assertEq(harness.getPending(player).portalId, OLD_ID, "pending records the portal id");
        reqId = harness.getPending(player).requestId;
        vm.warp(BASE + uint256(REVEAL_HOUR) * SPH);
    }

    function _assertNewbornUntouched() internal view {
        Portal memory n = harness.getPortals(player)[1];
        assertEq(uint8(n.status), uint8(PortalStatus.Open), "newborn open");
        assertTrue(n.id != OLD_ID && n.id != 0, "newborn has its own id");
        assertFalse(n.observerInside, "no observer in newborn");
        assertFalse(n.rescuerInside, "no rescuer in newborn");
        assertFalse(n.surveyPending, "no survey on newborn");
        assertEq(harness.getGame(player).power, 100, "no power spent");
        assertEq(harness.getGame(player).observersFree, 3, "observers untouched");
        assertEq(harness.getGame(player).rescuersFree, 2, "rescuers untouched");
        assertFalse(harness.getPending(player).active, "deferral resolved");
    }

    function test_DeferredClose_TargetReplaced_Cancels() public {
        _setupTargetAt1(true);
        uint64 reqId = _defer(1, Action.Close);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.DeferredActionCancelled(player, 1, Action.Close, Refusal.PortalEmpty, reqId, REVEAL_HOUR);
        source.reveal(reqId);

        _assertNewbornUntouched();
        Portal memory n = harness.getPortals(player)[1];
        // Only the old portal's collapse cost HP (nothing from a close).
        assertEq(n.spawnedAtHour, 10, "newborn born at hour 10");
    }

    function test_DeferredSendObserver_TargetReplaced_Cancels() public {
        _setupTargetAt1(false);
        uint64 reqId = _defer(1, Action.SendObserver);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.DeferredActionCancelled(player, 1, Action.SendObserver, Refusal.PortalEmpty, reqId, REVEAL_HOUR);
        source.reveal(reqId);

        _assertNewbornUntouched();
    }

    function test_DeferredAction_TargetSurvives_Applied() public {
        _game();
        harness.setPortal(player, 0, _longLived(5, 500, true));
        harness.setPortal(player, 1, _longLived(OLD_ID, 500, true));

        vm.warp(BASE + SPH);
        harness.act(1, Action.ToggleQuestioned);
        assertEq(harness.getPending(player).portalId, OLD_ID, "id recorded");
        uint64 reqId = harness.getPending(player).requestId;
        vm.warp(BASE + uint256(REVEAL_HOUR) * SPH);

        vm.expectEmit(true, true, false, false);
        emit PortalLab.ActionPerformed(player, 1, Action.ToggleQuestioned, 0, REVEAL_HOUR);
        source.reveal(reqId);

        assertEq(harness.getPortals(player)[1].id, OLD_ID, "same portal");
        assertFalse(harness.getPending(player).active, "resolved");
    }
}
