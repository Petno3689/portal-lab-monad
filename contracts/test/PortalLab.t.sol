// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Config,
    Game,
    Portal,
    PortalType,
    PortalStatus,
    PortalTypeParams
} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";

contract PortalLabTest is Test {
    PortalLab internal lab;
    DeterministicSource internal src;

    function setUp() public {
        src = new DeterministicSource(0);
        lab = new PortalLab(DefaultConfig.config(), DefaultConfig.portalTypeParams(), src);
    }

    // 0. The constructor rejects a zero random source.
    function test_ConstructorRevertsOnZeroRandomSource() public {
        Config memory c = DefaultConfig.config();
        PortalTypeParams[5] memory p = DefaultConfig.portalTypeParams();
        vm.expectRevert(PortalLab.ZeroRandomSource.selector);
        new PortalLab(c, p, DeterministicSource(address(0)));
    }

    // 1. Configuration is stored.
    function test_ConfigStored() public view {
        Config memory c = lab.config();
        assertEq(c.secPerHour, 15);
        assertEq(c.hpMax, 100);
        assertEq(c.powerMax, 100);
        assertEq(c.observersTotal, 3);
        assertEq(c.rescuersTotal, 2);
        assertEq(c.closeStabilityBelow, 40);
        assertEq(c.maxSpawnsPerTx, 3);
    }

    // 2. Per-type parameters are stored, with the distinctive ones checked.
    function test_PortalTypeParamsStored() public view {
        assertEq(lab.portalTypeParams(PortalType.Flash).degradePerHour, 6);
        assertEq(lab.portalTypeParams(PortalType.LongLived).hoursMax, 60);
        assertEq(lab.portalTypeParams(PortalType.Deaf).surveyPrecise, false);
        assertEq(lab.portalTypeParams(PortalType.Energetic).powerYieldPerHour, 4);
        assertEq(lab.portalTypeParams(PortalType.Resonant).actionMultiplierPct, 200);
    }

    // 3. The constructor rejects invalid configurations.
    function test_ConstructorRevertsOnInvalidConfig() public {
        Config memory c = DefaultConfig.config();
        PortalTypeParams[5] memory p = DefaultConfig.portalTypeParams();

        // secPerHour == 0
        Config memory cSec = DefaultConfig.config();
        cSec.secPerHour = 0;
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "secPerHour"));
        new PortalLab(cSec, p, src);

        // hpStart == 0
        Config memory cHpStart0 = DefaultConfig.config();
        cHpStart0.hpStart = 0;
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "hpStart"));
        new PortalLab(cHpStart0, p, src);

        // hpStart > hpMax
        Config memory cHpStartOver = DefaultConfig.config();
        cHpStartOver.hpStart = cHpStartOver.hpMax + 1;
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "hpStart"));
        new PortalLab(cHpStartOver, p, src);

        // healPerCreature >= hpCollapsePerDeath
        Config memory cHeal = DefaultConfig.config();
        cHeal.healPerCreature = cHeal.hpCollapsePerDeath;
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "healPerCreature"));
        new PortalLab(cHeal, p, src);

        // a type with hoursMin > hoursMax
        PortalTypeParams[5] memory pHours = DefaultConfig.portalTypeParams();
        pHours[0].hoursMin = pHours[0].hoursMax + 1;
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "hoursMin>hoursMax"));
        new PortalLab(c, pHours, src);

        // a type with stabilityMax > 100
        PortalTypeParams[5] memory pStab = DefaultConfig.portalTypeParams();
        pStab[1].stabilityMax = 101;
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "stabilityMax"));
        new PortalLab(c, pStab, src);
    }

    // 4. startGame initializes a clean game.
    function test_StartGameInitializes() public {
        vm.warp(5000);
        lab.startGame();

        Game memory g = lab.getGame(address(this));
        assertEq(g.startedAt, 5000);
        assertEq(g.lastTickAt, 5000);
        assertEq(g.hp, 50);  // hpStart, not hpMax
        assertEq(g.power, 100);
        assertEq(g.observersFree, 3);
        assertEq(g.rescuersFree, 2);
        assertEq(g.hoursElapsed, 0);
        assertEq(g.finished, false);
        assertEq(g.openPortals, 0);

        Portal[12] memory ps = lab.getPortals(address(this));
        for (uint256 i = 0; i < 12; i++) {
            assertEq(uint256(uint8(ps[i].status)), uint256(uint8(PortalStatus.Empty)));
        }
    }

    // 5. startGame emits GameStarted with the right fields.
    function test_StartGameEmitsGameStarted() public {
        vm.warp(1000);
        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameStarted(address(this), uint40(1000));
        lab.startGame();
    }

    // 6. A second startGame forfeits the live game and re-initializes.
    function test_RestartForfeitsAndReinitializes() public {
        vm.warp(1000);
        lab.startGame();

        vm.warp(2000);
        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameForfeited(address(this), 0);
        lab.startGame();

        Game memory g = lab.getGame(address(this));
        assertEq(g.startedAt, 2000);
    }

    // 7. getGame for an address with no game returns startedAt == 0.
    function test_GetGameNoGameReturnsZero() public view {
        Game memory g = lab.getGame(address(0xBEEF));
        assertEq(g.startedAt, 0);
    }
}
