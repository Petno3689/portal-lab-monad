// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Config, Game, BestRun, Portal, PortalStatus} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

contract LeaderboardTest is Test {
    PortalLabHarness internal harness;
    address internal player1 = address(0x100);
    address internal player2 = address(0x200);
    address internal player3 = address(0x300);

    uint40 internal constant BASE = 1_000;

    function setUp() public {
        harness = new PortalLabHarness();
        vm.warp(BASE);
    }

    function _game() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 50;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 0;
    }

    function _deadGame(uint32 hrs, uint32 rescued) internal pure returns (Game memory g) {
        g = _game();
        g.finished = true;
        g.diedAtHour = hrs;
        g.hoursElapsed = hrs;
        g.hp = 0;
        g.creaturesRescued = rescued;
    }

    function test_leaderboard_first_settle_adds_player() public {
        harness.setGame(player1, _deadGame(10, 5));
        assertEq(harness.leaderboardSize(), 0, "leaderboard empty initially");

        harness.settle(player1);

        assertEq(harness.leaderboardSize(), 1, "size is 1 after first settle");
        (address[] memory players,) = harness.leaderboardPage(0, 1);
        assertEq(players.length, 1);
        assertEq(players[0], player1);
    }

    function test_leaderboard_second_settle_does_not_add_again() public {
        harness.setGame(player1, _deadGame(10, 5));
        harness.settle(player1);
        assertEq(harness.leaderboardSize(), 1);

        // Force a second game and settle it
        harness.setGame(player1, _deadGame(20, 3));
        harness.settle(player1);

        assertEq(harness.leaderboardSize(), 1, "player not added twice");
        (address[] memory players,) = harness.leaderboardPage(0, 10);
        assertEq(players.length, 1);
        assertEq(players[0], player1);
    }

    function test_leaderboard_two_players_insertion_order() public {
        harness.setGame(player1, _deadGame(10, 5));
        harness.settle(player1);

        harness.setGame(player2, _deadGame(20, 3));
        harness.settle(player2);

        assertEq(harness.leaderboardSize(), 2);
        (address[] memory players,) = harness.leaderboardPage(0, 10);
        assertEq(players.length, 2);
        assertEq(players[0], player1, "player1 first");
        assertEq(players[1], player2, "player2 second");
    }

    function test_leaderboard_paging_normal_slice() public {
        // Add 5 players
        for (uint8 i = 0; i < 5; i++) {
            address p = address(uint160(0x1000 + i));
            harness.setGame(p, _deadGame(10 + i, 1));
            harness.settle(p);
        }

        // Request slice [1, 4)
        (address[] memory players,) = harness.leaderboardPage(1, 3);
        assertEq(players.length, 3);
        assertEq(players[0], address(0x1001));
        assertEq(players[1], address(0x1002));
        assertEq(players[2], address(0x1003));
    }

    function test_leaderboard_paging_clamped_at_end() public {
        // Add 3 players
        for (uint8 i = 0; i < 3; i++) {
            address p = address(uint160(0x1000 + i));
            harness.setGame(p, _deadGame(10 + i, 1));
            harness.settle(p);
        }

        // Request [2, 10) — should clamp to [2, 3)
        (address[] memory players,) = harness.leaderboardPage(2, 10);
        assertEq(players.length, 1);
        assertEq(players[0], address(0x1002));
    }

    function test_leaderboard_paging_offset_at_size() public {
        harness.setGame(player1, _deadGame(10, 5));
        harness.settle(player1);
        harness.setGame(player2, _deadGame(20, 3));
        harness.settle(player2);

        // offset == size, should return empty
        (address[] memory players, BestRun[] memory runs) = harness.leaderboardPage(2, 5);
        assertEq(players.length, 0);
        assertEq(runs.length, 0);
    }

    function test_leaderboard_paging_offset_beyond_size() public {
        harness.setGame(player1, _deadGame(10, 5));
        harness.settle(player1);
        harness.setGame(player2, _deadGame(20, 3));
        harness.settle(player2);

        // offset > size, should return empty
        (address[] memory players, BestRun[] memory runs) = harness.leaderboardPage(5, 10);
        assertEq(players.length, 0);
        assertEq(runs.length, 0);
    }

    function test_leaderboard_paging_limit_zero() public {
        harness.setGame(player1, _deadGame(10, 5));
        harness.settle(player1);
        harness.setGame(player2, _deadGame(20, 3));
        harness.settle(player2);

        // limit == 0, should return empty
        (address[] memory players, BestRun[] memory runs) = harness.leaderboardPage(0, 0);
        assertEq(players.length, 0);
        assertEq(runs.length, 0);
    }

    function test_leaderboard_page_runs_match_bestrun() public {
        // player1: a first run, then a new best, then a worse run — each settled
        // at a different timestamp so settledAt distinguishes them.
        harness.setGame(player1, _deadGame(10, 5));
        harness.settle(player1);

        vm.warp(BASE + 100);
        harness.setGame(player1, _deadGame(30, 2));
        harness.settle(player1);

        vm.warp(BASE + 200);
        harness.setGame(player1, _deadGame(5, 9));
        harness.settle(player1);

        vm.warp(BASE + 300);
        harness.setGame(player2, _deadGame(20, 3));
        harness.settle(player2);

        // Sanity: player1's record is the 30h run, settled at BASE + 100, three runs.
        BestRun memory best1 = harness.bestRun(player1);
        assertEq(best1.hoursSurvived, 30);
        assertEq(best1.creaturesRescued, 2);
        assertEq(best1.settledAt, BASE + 100);
        assertEq(best1.runsSettled, 3);

        (address[] memory players, BestRun[] memory runs) = harness.leaderboardPage(0, 10);
        assertEq(players.length, 2);
        assertEq(runs.length, 2);
        assertEq(players[0], player1);
        assertEq(players[1], player2);
        for (uint256 i = 0; i < players.length; i++) {
            BestRun memory expected = harness.bestRun(players[i]);
            assertEq(runs[i].hoursSurvived, expected.hoursSurvived, "hoursSurvived");
            assertEq(runs[i].creaturesRescued, expected.creaturesRescued, "creaturesRescued");
            assertEq(runs[i].settledAt, expected.settledAt, "settledAt");
            assertEq(runs[i].runsSettled, expected.runsSettled, "runsSettled");
        }
    }

    function test_leaderboard_auto_settle_adds_player() public {
        // A finished-but-unsettled game: startGame must auto-settle it.
        harness.setGame(player1, _deadGame(10, 5));
        assertEq(harness.leaderboardSize(), 0);

        vm.prank(player1);
        harness.startGame();

        BestRun memory br = harness.bestRun(player1);
        assertEq(br.runsSettled, 1, "run recorded by auto-settle");
        assertEq(br.hoursSurvived, 10);
        assertEq(harness.leaderboardSize(), 1);
        (address[] memory players,) = harness.leaderboardPage(0, 10);
        assertEq(players.length, 1);
        assertEq(players[0], player1);

        // A second auto-settled run must not add the player again.
        harness.setGame(player1, _deadGame(20, 1));
        vm.prank(player1);
        harness.startGame();

        assertEq(harness.bestRun(player1).runsSettled, 2);
        assertEq(harness.leaderboardSize(), 1, "player listed exactly once");
        (players,) = harness.leaderboardPage(0, 10);
        assertEq(players.length, 1);
        assertEq(players[0], player1);
    }

    function test_leaderboard_forfeited_game_not_recorded() public {
        // A live (unfinished) game abandoned via startGame is forfeited, not recorded.
        harness.setGame(player1, _game());

        vm.warp(BASE + 15); // one game hour later
        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameForfeited(player1, 0);
        vm.prank(player1);
        harness.startGame();

        assertEq(harness.leaderboardSize(), 0, "forfeit does not enter the leaderboard");
        assertEq(harness.bestRun(player1).runsSettled, 0, "forfeit does not record a run");
    }

    function test_leaderboard_paging_huge_limit_no_overflow() public {
        for (uint8 i = 0; i < 3; i++) {
            address p = address(uint160(0x1000 + i));
            harness.setGame(p, _deadGame(10 + i, 1));
            harness.settle(p);
        }

        // offset + limit would overflow; must clamp to [1, 3) instead of reverting.
        (address[] memory players, BestRun[] memory runs) = harness.leaderboardPage(1, type(uint256).max);
        assertEq(players.length, 2);
        assertEq(runs.length, 2);
        assertEq(players[0], address(0x1001));
        assertEq(players[1], address(0x1002));
    }
}
