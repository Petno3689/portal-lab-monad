// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Config,
    Game,
    Portal,
    Pending,
    PortalType,
    PortalStatus,
    Action,
    Refusal,
    MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @dev Test-only lab with a caller-supplied config (the stock harness is bound to
/// the deployed numbers) and direct state setters.
contract CustomConfigLab is PortalLab {
    constructor(Config memory c, DeterministicSource src)
        PortalLab(c, DefaultConfig.portalTypeParams(), src)
    {}

    function setGame(address player, Game calldata g) external {
        _players[player].game = g;
        _players[player].pending.coveredEpochs = type(uint32).max;
        _players[player].epochWord = uint256(keccak256(abi.encode("portal-lab/harness-word", player)));
    }

    function setPortal(address player, uint8 slot, Portal calldata p) external {
        _players[player].portals[slot] = p;
    }
}

/// @title RequestTimeoutTest — Ticket 4.7: a stuck deferral can be cancelled.
contract RequestTimeoutTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    address internal player;

    uint40 internal constant BASE = 1_000_000;
    uint32 internal SPH;
    uint32 internal EPH;
    uint256 internal TIMEOUT; // seconds, the player's own timeout
    uint256 internal OUTSIDER_TIMEOUT; // seconds, what a stranger must wait

    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);
        Config memory c = DefaultConfig.config();
        SPH = c.secPerHour;
        EPH = c.epochHours;
        TIMEOUT = uint256(c.requestTimeoutHours) * SPH;
        OUTSIDER_TIMEOUT = uint256(c.outsiderTimeoutHours) * SPH;
        vm.warp(BASE);
    }

    function _game(uint16 power) internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = power;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
    }

    function _unsurveyed() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.portalType = PortalType.LongLived;
        p.snapshotAt = BASE;
        p.hoursToCollapse = 1000;
        p.energyHi = 5;
        p.stabilityLo = 95;
        p.stabilityHi = 100;
        p.creaturesLo = 2;
        p.creaturesHi = 3;
    }

    function _commit(Action a, uint16 power) internal returns (uint64) {
        harness.setGame(player, _game(power));
        harness.setPortal(player, 0, _unsurveyed());
        harness.act(0, a);
        return harness.getPending(player).requestId;
    }

    /// @dev Stuck epoch-crossing action: epoch 0 pinned, world one hour past its edge.
    function _commitCrossing(uint16 power) internal returns (uint64) {
        harness.setGame(player, _game(power));
        harness.setPortal(player, 0, _unsurveyed());
        harness.setCoverage(player, uint256(keccak256("seed")), 1);
        vm.warp(BASE + uint256(EPH + 1) * SPH);
        harness.act(0, Action.SendObserver);
        assertTrue(harness.getPending(player).deferredWorld, "crossing deferral");
        return harness.getPending(player).requestId;
    }

    function test_6_1_CancelBeforeTimeout_Reverts() public {
        _commit(Action.SendObserver, 50);
        uint256 firstOk = uint256(BASE) + TIMEOUT + 1;
        vm.expectRevert(abi.encodeWithSelector(PortalLab.RequestNotTimedOut.selector, firstOk));
        harness.cancelDeferred(player);
        vm.warp(BASE + TIMEOUT); // exactly at the deadline: still too early
        vm.expectRevert(abi.encodeWithSelector(PortalLab.RequestNotTimedOut.selector, firstOk));
        harness.cancelDeferred(player);
    }

    function test_NoDeferral_Reverts() public {
        harness.setGame(player, _game(50));
        vm.expectRevert(PortalLab.NoPendingAction.selector);
        harness.cancelDeferred(player);
    }

    function test_6_2_StuckSurvey_CrewBackHalfPowerBack() public {
        uint64 reqId = _commit(Action.SendObserver, 50); // cost 10 -> power 40
        assertEq(harness.getGame(player).power, 40);
        vm.warp(BASE + TIMEOUT + 1);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.DeferredActionCancelled(player, 0, Action.SendObserver, Refusal.RandomnessTimeout, reqId, 0);
        harness.cancelDeferred(player);

        Game memory g = harness.getGame(player);
        Portal memory p = harness.getPortals(player)[0];
        assertEq(g.power, 50, "half of 10 returned + 5 regen for the hung hour");
        assertEq(g.observersFree, 3, "observer back, alive");
        assertFalse(p.observerInside, "observer out");
        assertFalse(p.surveyPending, "survey flag cleared");
        assertEq(uint8(p.status), uint8(PortalStatus.Open), "portal intact");
        assertFalse(harness.getPending(player).active, "lock released");
    }

    function test_6_3_StuckBlindRescue_RescuerBack() public {
        _commit(Action.SendRescuer, 50); // cost 20 -> 30
        assertEq(harness.getGame(player).rescuersFree, 1);
        vm.warp(BASE + TIMEOUT + 1);
        harness.cancelDeferred(player);

        Game memory g = harness.getGame(player);
        assertEq(g.rescuersFree, 2, "rescuer back in the pool");
        assertEq(g.power, 45, "half of 20 returned + 5 regen for the hung hour");
        assertFalse(harness.getPortals(player)[0].rescuerPending, "rescuer flag cleared");
    }

    function test_PowerRefundCappedAtMax() public {
        _commit(Action.SendObserver, 100); // 100 - 10 = 90
        // Three hung hours regen 15, so catch-up alone fills the pool to 100; the
        // refund of 5 (half of 10) then lands on a full pool and must be clamped.
        vm.warp(BASE + 3 * uint256(SPH));
        harness.cancelDeferred(player);
        assertEq(harness.getGame(player).power, 100); // 90 + 15 regen capped at 100, + 5 refund capped at 100
    }

    function test_6_4_CrossingDeferral_NoPowerRefund_LockReleased_WorldStays() public {
        uint64 reqId = _commitCrossing(50);
        Game memory before_ = harness.getGame(player);
        assertEq(before_.power, 50, "crossing commit spends nothing");
        vm.warp(block.timestamp + TIMEOUT + 1);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.DeferredActionCancelled(
            player, 0, Action.SendObserver, Refusal.RandomnessTimeout, reqId, harness.getPending(player).atHour
        );
        harness.cancelDeferred(player);

        Game memory g = harness.getGame(player);
        assertEq(g.power, 100, "nothing refunded: only the free catch-up regen, up to the ceiling");
        assertEq(g.observersFree, 3, "crew untouched");
        // Free catch-up may move the world, but never across the pinned edge.
        assertLe(g.hoursElapsed, uint32(1) * EPH - 1, "world has not crossed the pinned edge");
        assertFalse(harness.getPending(player).active, "lock released");
        assertEq(harness.getPending(player).coveredEpochs, 1, "coverage preserved");
    }

    function test_6_5_StuckPaidSync_Cancelled() public {
        harness.setGame(player, _game(50));
        harness.setCoverage(player, uint256(keccak256("seed")), 1);
        vm.warp(BASE + uint256(EPH + 1) * SPH);
        harness.sync{value: 1}(player);
        Pending memory pend = harness.getPending(player);
        assertTrue(pend.active && pend.syncOnly, "sync deferral");
        vm.warp(block.timestamp + TIMEOUT + 1);
        harness.cancelDeferred(player);

        assertFalse(harness.getPending(player).active, "lock released");
        assertEq(harness.getPending(player).coveredEpochs, 1, "coverage preserved");
        assertEq(harness.getGame(player).power, 100, "no refund: only the free catch-up regen, up to the ceiling");
        assertEq(harness.getGame(player).observersFree, 3, "crew untouched");
    }

    function test_6_6_StrangerCanCancel() public {
        _commit(Action.SendObserver, 50);
        vm.warp(BASE + OUTSIDER_TIMEOUT + 1);
        vm.prank(address(0xBEEF));
        harness.cancelDeferred(player);
        assertFalse(harness.getPending(player).active);
        assertEq(harness.getGame(player).observersFree, 3);
    }

    /// A stranger past the PLAYER's timeout but before the outsider's is refused.
    function test_6_6a_StrangerAtPlayerTimeoutPlusOne_Reverts() public {
        _commit(Action.SendObserver, 50);
        vm.warp(BASE + TIMEOUT + 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(PortalLab.RequestNotTimedOut.selector, uint256(BASE) + OUTSIDER_TIMEOUT + 1)
        );
        harness.cancelDeferred(player);
        assertTrue(harness.getPending(player).active, "deferral untouched");
    }

    /// Exactly at the outsider deadline: refused; one second later: allowed.
    function test_6_6b_StrangerOutsiderDeadlineBoundary() public {
        _commit(Action.SendObserver, 50);
        uint256 firstOk = uint256(BASE) + OUTSIDER_TIMEOUT + 1;
        vm.warp(BASE + OUTSIDER_TIMEOUT);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(PortalLab.RequestNotTimedOut.selector, firstOk));
        harness.cancelDeferred(player);

        vm.warp(firstOk);
        vm.prank(address(0xBEEF));
        harness.cancelDeferred(player);
        assertFalse(harness.getPending(player).active);
    }

    /// The player is not held to the outsider timeout.
    function test_6_6c_PlayerCancelsAtPlayerTimeoutPlusOne() public {
        _commit(Action.SendObserver, 50);
        vm.warp(BASE + TIMEOUT + 1);
        vm.prank(player);
        harness.cancelDeferred(player);
        assertFalse(harness.getPending(player).active);
    }

    function test_ConstructorRejectsZeroOutsiderTimeout() public {
        Config memory c = DefaultConfig.config();
        c.outsiderTimeoutHours = 0;
        DeterministicSource src = new DeterministicSource(0);
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "outsiderTimeoutHours"));
        new PortalLab(c, DefaultConfig.portalTypeParams(), src);
    }

    function test_ConstructorRejectsOutsiderBelowPlayerTimeout() public {
        Config memory c = DefaultConfig.config();
        c.requestTimeoutHours = 5;
        c.outsiderTimeoutHours = 4;
        DeterministicSource src = new DeterministicSource(0);
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "outsiderTimeoutHours"));
        new PortalLab(c, DefaultConfig.portalTypeParams(), src);
    }

    /// The trap: game hours stand still while a crossing is stuck, so only real
    /// time can ever expire it.
    function test_6_7_CrossingCancelledWhileGameClockStands() public {
        _commitCrossing(50);

        vm.warp(block.timestamp + TIMEOUT); // not yet
        vm.expectRevert();
        harness.cancelDeferred(player);

        vm.warp(block.timestamp + 1);
        harness.cancelDeferred(player); // real time passed -> allowed
        assertFalse(harness.getPending(player).active);
        assertLe(harness.getGame(player).hoursElapsed, uint32(1) * EPH - 1, "world has not crossed the pinned edge");
    }

    function test_6_8_LateWordAfterCancel_FallsOffHarmlessly() public {
        uint64 reqId = _commit(Action.SendObserver, 50);
        vm.warp(BASE + TIMEOUT + 1);
        harness.cancelDeferred(player);

        bytes32 gameHash = keccak256(abi.encode(harness.getGame(player)));
        bytes32 portalsHash = keccak256(abi.encode(harness.getPortals(player)));
        vm.expectRevert(PortalLab.UnknownRequest.selector);
        source.reveal(reqId);
        assertEq(keccak256(abi.encode(harness.getGame(player))), gameHash, "game unchanged");
        assertEq(keccak256(abi.encode(harness.getPortals(player))), portalsHash, "portals unchanged");
        assertFalse(harness.getPending(player).active);
    }

    function test_6_9_PlayerActsAgainAfterCancel() public {
        _commit(Action.SendObserver, 50);
        vm.warp(BASE + TIMEOUT + 1);
        harness.cancelDeferred(player);

        harness.act(0, Action.SendObserver); // a fresh survey commits fine
        assertTrue(harness.getPending(player).active);
        harness.reveal(player);
        assertTrue(harness.getPortals(player)[0].surveyed, "game intact, survey completes");
    }

    function test_ConstructorRejectsZeroTimeout() public {
        Config memory c = DefaultConfig.config();
        c.requestTimeoutHours = 0;
        DeterministicSource src = new DeterministicSource(0);
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "requestTimeoutHours"));
        new PortalLab(c, DefaultConfig.portalTypeParams(), src);
    }

    /// @dev Survey committed, portal then collapses (1h) while the word is stuck.
    /// `syncFirst` chooses whether anyone aged the world before the cancel.
    function _collapseThenCancel(bool syncFirst)
        internal
        returns (Game memory g, Portal memory p, Pending memory pend)
    {
        PortalLabHarness h = new PortalLabHarness();
        vm.warp(BASE);
        Portal memory doomed = _unsurveyed();
        doomed.hoursToCollapse = 1;
        h.setGame(player, _game(50));
        h.setPortal(player, 0, doomed);
        h.act(0, Action.SendObserver);
        assertTrue(h.getPortals(player)[0].surveyPending, "survey committed");

        vm.warp(BASE + TIMEOUT + 1); // portal has collapsed in lazy time
        if (syncFirst) h.sync(player);
        h.cancelDeferred(player);
        return (h.getGame(player), h.getPortals(player)[0], h.getPending(player));
    }

    /// Main test of 4.7a: a collapse that nobody synced must still kill the observer.
    function test_7a_CollapseBeforeCancel_NoSync_ObserverStaysDead_OrderIndependent() public {
        (Game memory a, Portal memory pa, Pending memory penda) = _collapseThenCancel(false);
        (Game memory b, Portal memory pb, Pending memory pendb) = _collapseThenCancel(true);

        assertEq(a.observersFree, 2, "dead observer not returned to the pool");
        assertLt(a.hp, 100, "player pays health for the observer's death");
        assertFalse(penda.active, "lock released");
        assertEq(uint8(pa.status), uint8(PortalStatus.Empty), "portal collapsed (slot freed)");
        assertFalse(pa.surveyPending);

        // Both orders agree on everything.
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "game identical");
        assertEq(keccak256(abi.encode(pa)), keccak256(abi.encode(pb)), "portal identical");
        assertEq(keccak256(abi.encode(penda)), keccak256(abi.encode(pendb)), "pending identical");
    }

    /// Odd price: half rounds UP in the player's favour (11 -> 6, 21 -> 11).
    function test_7a_RefundRoundsHalfUp_OddPrices() public {
        Config memory c = DefaultConfig.config();
        c.costSendObserver = 11;
        c.costSendRescuer = 21;
        c.requestTimeoutHours = 1;
        CustomConfigLab lab = new CustomConfigLab(c, new DeterministicSource(0));
        uint256 t = uint256(c.requestTimeoutHours) * c.secPerHour;
        Config memory d = DefaultConfig.config();

        // Observer: 50 - 11 = 39, +regen (1h) + ceil(11/2)=6.
        lab.setGame(player, _game(50));
        lab.setPortal(player, 0, _unsurveyed());
        lab.act(0, Action.SendObserver);
        assertEq(lab.getGame(player).power, 39);
        vm.warp(BASE + t + 1);
        lab.cancelDeferred(player);
        assertEq(lab.getGame(player).power, 39 + d.powerRegenPerHour + 6, "11 -> 6, not 5");

        // Rescuer: 50 - 21 = 29, +regen + ceil(21/2)=11.
        vm.warp(BASE);
        lab.setGame(player, _game(50));
        lab.setPortal(player, 0, _unsurveyed());
        lab.act(0, Action.SendRescuer);
        assertEq(lab.getGame(player).power, 29);
        vm.warp(BASE + t + 1);
        lab.cancelDeferred(player);
        assertEq(lab.getGame(player).power, 29 + d.powerRegenPerHour + 11, "21 -> 11, not 10");
    }

    function test_Gas_CancelDeferred() public {
        _commit(Action.SendObserver, 50);
        vm.warp(BASE + TIMEOUT + 1);
        uint256 g0 = gasleft();
        harness.cancelDeferred(player);
        emit log_named_uint("cancelDeferred gas", g0 - gasleft());
    }
}
