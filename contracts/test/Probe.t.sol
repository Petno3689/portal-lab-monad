// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Probe} from "../src/Probe.sol";

contract ProbeTest is Test {
    Probe internal probe;

    function setUp() public {
        probe = new Probe();
    }

    function test_CountStartsAtZero() public view {
        assertEq(probe.count(), 0);
    }

    function test_ThreeTicksCountsThree() public {
        probe.tick();
        probe.tick();
        probe.tick();
        assertEq(probe.count(), 3);
    }

    function test_TickEmitsTickedWithNewCount() public {
        vm.expectEmit(true, false, false, false);
        emit Probe.Ticked(1, 0, 0, address(0));
        probe.tick();
    }

    function test_TickEmitsMeasurementFields() public {
        uint256 expectedTimestamp = 1_700_000_000;
        uint256 expectedBlockNumber = 12_345;
        vm.warp(expectedTimestamp);
        vm.roll(expectedBlockNumber);

        vm.expectEmit(true, false, false, true);
        emit Probe.Ticked(1, expectedTimestamp, expectedBlockNumber, address(this));
        probe.tick();
    }
}
