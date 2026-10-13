// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Game, Pending, Config} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @title StartingHandTest — Ticket 8.1: a new game starts with three portals'
/// worth of pressure, and `startGame` may buy the first word.
contract StartingHandTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    Config internal c;
    address internal player;
    uint40 internal constant BASE = 1_000_000;

    // Accept the change `startGame` refunds.
    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);
        c = DefaultConfig.config();
        source.setFee(0.01 ether); // the mock's default fee is 0
        vm.deal(address(this), 1_000 ether);
        vm.warp(BASE);
    }

    function test_StartGame_SeedsThreePortalsOfPressure() public {
        harness.startGame();
        assertEq(uint256(harness.getGame(player).spawnDebt), 3 * uint256(c.spawnCostUnits));
    }

    function test_StartGame_NoValue_RequestsNothing() public {
        harness.startGame();
        assertFalse(harness.getPending(player).active, "no pending without a fee");
        assertEq(source.lastRequestId(), 0, "no word requested without a fee");
    }

    function test_StartGame_Paid_RecordsSyncOnlyDeferralAndRequests() public {
        uint256 f = source.fee();
        harness.startGame{value: f}();

        Pending memory p = harness.getPending(player);
        assertTrue(p.active, "deferral recorded");
        assertTrue(p.syncOnly, "syncOnly");
        assertTrue(p.deferredWorld, "deferredWorld");
        assertEq(uint256(p.requestId), uint256(source.lastRequestId()), "request id stored");
        assertEq(source.lastRequestId(), 1, "exactly one word requested");
    }

    function test_StartGame_Paid_RefundsExcess() public {
        uint256 f = source.fee();
        uint256 before = address(this).balance;
        harness.startGame{value: f + 5 ether}();
        assertEq(before - address(this).balance, f, "only the fee is kept");
    }

    function test_StartGame_Paid_UnderpayReverts() public {
        uint256 f = source.fee();
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InsufficientFee.selector, f, f - 1));
        harness.startGame{value: f - 1}();
    }

    /// The reveal is the existing `receiveWord` path: after one game hour the lab
    /// holds `maxSpawnsPerTx` portals.
    function test_StartGame_Paid_RevealFillsLab() public {
        harness.startGame{value: source.fee()}();
        vm.warp(BASE + c.secPerHour);
        source.reveal(harness.getPending(player).requestId);

        assertFalse(harness.getPending(player).active, "deferral resolved");
        Game memory g = harness.getGame(player);
        assertEq(uint256(g.openPortals), uint256(c.maxSpawnsPerTx), "starting hand spawned");
        assertEq(uint256(g.hoursElapsed), 1, "walked one hour");
    }

    function test_gas_startGame_withAndWithoutFee() public {
        address a = address(0xA11CE);
        address b = address(0xB0B);
        uint256 f = source.fee();
        vm.deal(a, 10 ether);
        vm.deal(b, 10 ether);

        vm.prank(a);
        uint256 g0 = gasleft();
        harness.startGame();
        emit log_named_uint("gas startGame (no fee)", g0 - gasleft());

        vm.prank(b);
        g0 = gasleft();
        harness.startGame{value: f}();
        emit log_named_uint("gas startGame (with fee)", g0 - gasleft());
    }
}
