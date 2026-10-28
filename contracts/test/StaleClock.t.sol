// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Game, Portal, PortalStatus} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

/// @title StaleClockTest — a clock behind `lastTickAt` means "no time passed".
/// @notice The front runs the same rule with the BROWSER clock, which can be a
/// little slow right after the player's own transaction. `TimeLib.catchUp` clamps
/// such a clock to `lastTickAt` instead of reverting (SPEC §5.3).
contract StaleClockTest is Test {
    PortalLabHarness internal harness;
    address internal player;

    uint40 internal constant BASE = 1000;
    uint40 internal constant SPH = 15;

    function setUp() public {
        harness = new PortalLabHarness();
        player = address(this);
    }

    /// @dev A game stored one second into game hour 10, two portals open.
    function _seedMidHour() internal returns (uint40 lastTick) {
        lastTick = BASE + 10 * SPH + 1;
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = lastTick;
        g.hoursElapsed = 10;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 2;
        g.spawnDebt = 4000;
        harness.setGame(player, g);
        for (uint8 i = 0; i < 2; i++) {
            Portal memory p;
            p.status = PortalStatus.Open;
            p.surveyed = true;
            p.stability = 100;
            p.energy = 50;
            p.hoursToCollapse = 1000;
            p.snapshotAt = BASE + 10 * SPH;
            harness.setPortal(player, i, p);
        }
    }

    function _worldHash() internal view returns (bytes32) {
        return keccak256(abi.encode(harness.getGame(player), harness.getPortals(player)));
    }

    function _previewHash() internal view returns (bytes32) {
        (Game memory g, Portal[12] memory ps, bool capped) = harness.preview(player);
        return keccak256(abi.encode(g, ps, capped));
    }

    /// @dev `behind` seconds before lastTickAt, preview and sync neither revert
    /// nor differ from the call made exactly at lastTickAt.
    function _check(uint40 behind) internal {
        uint40 lastTick = _seedMidHour();

        vm.warp(lastTick);
        bytes32 previewAt = _previewHash();
        uint256 snap = vm.snapshotState();
        harness.sync(player);
        bytes32 syncAt = _worldHash();
        vm.revertToState(snap);

        vm.warp(lastTick - behind);
        assertEq(_previewHash(), previewAt, "preview behind lastTickAt equals preview at it");
        harness.sync(player);
        assertEq(_worldHash(), syncAt, "sync behind lastTickAt equals sync at it");
    }

    function test_ClockTwoSecondsBehindAcrossHourBoundary() public {
        // 1 s into hour 10: two seconds back lands in hour 9.
        _check(2);
    }

    function test_ClockSeveralHoursBehind() public {
        _check(5 * SPH + 3);
    }
}
