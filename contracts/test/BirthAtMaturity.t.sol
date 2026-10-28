// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Game,
    Portal,
    Config,
    PortalType,
    PortalTypeParams,
    PortalStatus,
    MAX_OPEN_PORTALS,
    MAX_CATCHUP_EVENTS,
    SPAWN_DEBT_MAX
} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";

/// @title BirthAtMaturityTest — the world does not depend on WHEN anyone calls.
/// @notice A portal is born at the hour its pressure matures (and a slot is
/// free), not at the hour of whichever call happens to age the world. Every
/// event hour is then a function of the stored snapshot and of time alone, so:
///   * SPLIT INVARIANCE — one `sync` at `c` leaves exactly the Game and the
///     twelve portals that `sync` at `b` followed by `sync` at `c` leaves, for
///     any `b` in between, and two syncs at one moment equal one;
///   * PREVIEW STABILITY — a portal `preview` shows is the portal a later `sync`
///     stores: same id, type, name, birth hour and collapse hour;
///   * the event FUSE (MAX_CATCHUP_EVENTS) stops a walk the same way in
///     `preview` and `sync`, and the next call carries on.
/// States are seeded with the harness setters; structs are built fresh by helpers
/// (never assigned by copy — CLAUDE.md rule).
contract BirthAtMaturityTest is Test {
    PortalLabHarness internal harness;
    address internal player;

    uint40 internal constant BASE = 1000;
    uint40 internal constant SPH = 15;

    uint256 internal constant STATE_COUNT = 6;

    function setUp() public {
        harness = new PortalLabHarness();
        player = address(0xC0FFEE);
        vm.warp(BASE);
    }

    // ── Seeded states ────────────────────────────────────────────────────────

    function _ts(uint256 h) internal pure returns (uint40) {
        return uint40(uint256(BASE) + h * SPH);
    }

    function _game(uint256 atHour) internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = _ts(atHour);
        g.hoursElapsed = uint32(atHour);
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.spawnCount = 20;
        g.rngNonce = 20;
    }

    function _surveyed(PortalType t, uint16 htc, uint8 stability, uint8 creatures, uint256 snapHour)
        internal
        pure
        returns (Portal memory p)
    {
        p.id = 7;
        p.portalType = t;
        p.nameIndex = 3;
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.stability = stability;
        p.energy = 50;
        p.creatures = creatures;
        p.hoursToCollapse = htc;
        p.snapshotAt = _ts(snapHour);
    }

    function _unsurveyed(PortalType t, uint16 htc, uint256 snapHour) internal pure returns (Portal memory p) {
        PortalTypeParams memory tp = DefaultConfig.portalTypeParams()[uint8(t)];
        p.id = 9;
        p.portalType = t;
        p.nameIndex = 11;
        p.status = PortalStatus.Open;
        p.hoursToCollapse = htc;
        p.snapshotAt = _ts(snapHour);
        p.energyLo = tp.energyMin;
        p.energyHi = tp.energyMax;
        p.stabilityLo = tp.stabilityMin;
        p.stabilityHi = tp.stabilityMax;
        p.creaturesLo = tp.creaturesMin;
        p.creaturesHi = tp.creaturesMax;
    }

    /// @dev Seed state `i` for `player` and return the moment `c` it is synced to
    /// (and the moment it stands at).
    function _seed(uint256 i) internal returns (uint40 start, uint40 c) {
        if (i == 0) {
            // A fresh starting hand: hour 0, three portals' worth of debt, nothing open.
            Game memory g = _game(0);
            g.hp = 50;
            g.spawnDebt = 30_000;
            harness.setGame(player, g);
            return (_ts(0), _ts(40) + 4);
        }
        if (i == 1) {
            // Mid-game at hour 20: four portals of different kinds, part of a portal's
            // debt, a rescuer recovering until hour 30.
            Game memory g = _game(20);
            g.spawnDebt = 7000;
            g.openPortals = 4;
            g.observersFree = 2;
            g.rescuersFree = 1;
            g.rescuerReadyAt0 = 30;
            harness.setGame(player, g);
            harness.setPortal(player, 0, _surveyed(PortalType.LongLived, 40, 70, 3, 20));
            harness.setPortal(player, 2, _unsurveyed(PortalType.Flash, 6, 20));
            harness.setPortal(player, 5, _unsurveyed(PortalType.Deaf, 15, 18));
            Portal memory r = _surveyed(PortalType.Resonant, 25, 60, 1, 20);
            r.observerInside = true;
            harness.setPortal(player, 7, r);
            return (_ts(20), _ts(55) + 9);
        }
        if (i == 2) {
            // A full lab: twelve open, collapsing one after another, debt waiting
            // for room. The overflow drains until the first collapse frees a slot.
            Game memory g = _game(0);
            g.spawnDebt = 25_000;
            g.openPortals = 12;
            harness.setGame(player, g);
            for (uint8 s = 0; s < 12; s++) {
                harness.setPortal(player, s, _surveyed(PortalType.LongLived, uint16(3 + 4 * uint16(s)), 80, 0, 0));
            }
            return (_ts(0), _ts(30));
        }
        if (i == 3) {
            // An Energetic portal feeding a drained reactor until it collapses.
            Game memory g = _game(0);
            g.power = 10;
            g.openPortals = 2;
            harness.setGame(player, g);
            harness.setPortal(player, 0, _surveyed(PortalType.Energetic, 12, 60, 0, 0));
            harness.setPortal(player, 1, _unsurveyed(PortalType.Energetic, 17, 0));
            return (_ts(0), _ts(20) + 14);
        }
        if (i == 4) {
            // A long absence from an empty lab: portals are born at hours 10, 20,
            // 30, 40 and some of them collapse inside the window.
            Game memory g = _game(0);
            harness.setGame(player, g);
            return (_ts(0), _ts(45) + 1);
        }
        // A lethal absence: the empty lab fills, newborns collapse, the run dies
        // long before `c`.
        Game memory gl = _game(0);
        gl.hp = 30;
        harness.setGame(player, gl);
        return (_ts(0), _ts(200));
    }

    // ── Comparison ───────────────────────────────────────────────────────────

    struct World {
        Game g;
        Portal[MAX_OPEN_PORTALS] p;
    }

    function _stored() internal view returns (World memory w) {
        w.g = harness.getGame(player);
        w.p = harness.getPortals(player);
    }

    /// @dev Every field of the game and of all twelve portals, never a selection.
    function _assertSame(World memory got, World memory want, string memory where) internal pure {
        if (keccak256(abi.encode(got.g)) != keccak256(abi.encode(want.g))) {
            assertEq(VectorCodec.gameJson(got.g), VectorCodec.gameJson(want.g), string.concat("game differs: ", where));
        }
        for (uint256 s = 0; s < MAX_OPEN_PORTALS; s++) {
            if (keccak256(abi.encode(got.p[s])) == keccak256(abi.encode(want.p[s]))) continue;
            assertEq(
                VectorCodec.portalJson(got.p[s]),
                VectorCodec.portalJson(want.p[s]),
                string.concat("portal differs: ", where, " slot=", vm.toString(s))
            );
        }
    }

    /// @dev One sync at `c`, against a sync at `b` followed by one at `c`.
    function _checkSplit(uint256 i, uint40 b) internal {
        uint256 snap = vm.snapshotState();
        (, uint40 c) = _seed(i);
        vm.warp(c);
        harness.sync(player);
        World memory once = _stored();
        vm.revertToState(snap);

        (, c) = _seed(i);
        vm.warp(b);
        harness.sync(player);
        vm.warp(c);
        harness.sync(player);
        World memory split = _stored();
        vm.revertToState(snap);

        _assertSame(split, once, string.concat("state ", vm.toString(i), " b=", vm.toString(uint256(b))));
    }

    // ── Split invariance ─────────────────────────────────────────────────────

    function test_SplitInvariance_EveryStateSeveralHours() public {
        for (uint256 i = 0; i < STATE_COUNT; i++) {
            uint256 snap = vm.snapshotState();
            (uint40 start, uint40 c) = _seed(i);
            vm.revertToState(snap);
            uint256 span = uint256(c) - uint256(start);
            // The start itself, one second on, an exact hour boundary, the middle
            // off the hour, the last hour before `c`, and `c` itself.
            uint40[6] memory bs = [
                start,
                start + 1,
                start + SPH,
                uint40(uint256(start) + span / 2 + 7),
                c - SPH,
                c
            ];
            for (uint256 k = 0; k < bs.length; k++) {
                if (bs[k] < start || bs[k] > c) continue;
                _checkSplit(i, bs[k]);
            }
        }
    }

    /// @dev Every second of the window is as good a `b` as any other.
    function testFuzz_SplitInvariance(uint256 stateIdx, uint256 bOff) public {
        uint256 i = bound(stateIdx, 0, STATE_COUNT - 1);
        uint256 snap = vm.snapshotState();
        (uint40 start, uint40 c) = _seed(i);
        vm.revertToState(snap);
        uint40 b = uint40(bound(bOff, uint256(start), uint256(c)));
        _checkSplit(i, b);
    }

    /// @dev Many intermediate calls, each at an hour nobody would choose, still
    /// land on the single call's world.
    function test_SplitInvariance_ManyCalls() public {
        for (uint256 i = 0; i < STATE_COUNT; i++) {
            uint256 snap = vm.snapshotState();
            (uint40 start, uint40 c) = _seed(i);
            vm.warp(c);
            harness.sync(player);
            World memory once = _stored();
            vm.revertToState(snap);

            (start, c) = _seed(i);
            for (uint40 t = start + 13; t < c; t += 37) {
                vm.warp(t);
                harness.sync(player);
            }
            vm.warp(c);
            harness.sync(player);
            World memory many = _stored();
            vm.revertToState(snap);

            _assertSame(many, once, string.concat("many calls, state ", vm.toString(i)));
        }
    }

    function test_TwoSyncsAtOneMomentEqualOne() public {
        for (uint256 i = 0; i < STATE_COUNT; i++) {
            uint256 snap = vm.snapshotState();
            (, uint40 c) = _seed(i);
            vm.warp(c);
            harness.sync(player);
            World memory once = _stored();
            harness.sync(player);
            World memory twice = _stored();
            vm.revertToState(snap);
            _assertSame(twice, once, string.concat("two syncs, state ", vm.toString(i)));
        }
    }

    // ── Preview stability ────────────────────────────────────────────────────

    /// A portal `preview` shows at t1 is, after a `sync` at a later t2, stored with
    /// the same id, type, nameIndex, spawnedAtHour and collapse hour. Before this
    /// rule a not-yet-stored portal was re-created at the current hour on every
    /// `preview`, so its countdown stood still on the screen until some
    /// transaction stored it — and across an epoch edge it could be a different
    /// portal altogether.
    ///
    /// `snapshotAt` itself is NOT compared: every walk re-stamps the survivors at
    /// the moment it reaches (t1 for the preview, t2 for the sync), exactly as for
    /// stored portals — that is what keeps split catch-ups equal. The quantity the
    /// snapshot carries, the collapse hour `h(snapshotAt) + hoursToCollapse`, is
    /// compared instead, and the stored snapshot is checked to be the sync's stamp.
    function test_PreviewStability() public {
        _seed(4); // empty lab: births at hours 10, 20, 30, 40
        // Under the epochHours-36 draws the two portals born at 10 and 20 collapse
        // at hours 26 and 27, so the window sits at hours 21..24 (it was 25..33):
        // setup only, the comparison is untouched.
        uint40 t1 = _ts(21) + 7;
        uint40 t2 = _ts(24) + 2;

        vm.warp(t1);
        (, Portal[MAX_OPEN_PORTALS] memory shown,) = harness.preview(player);
        vm.warp(t2);
        harness.sync(player);
        Portal[MAX_OPEN_PORTALS] memory stored = harness.getPortals(player);

        uint256 compared;
        for (uint256 s = 0; s < MAX_OPEN_PORTALS; s++) {
            Portal memory a = shown[s];
            if (a.status == PortalStatus.Empty) continue;
            uint256 collapseHour = _hourOf(a.snapshotAt) + a.hoursToCollapse;
            if (collapseHour <= _hourOf(t2)) continue; // gone by t2: nothing to find
            Portal memory z = stored[s];
            assertEq(z.id, a.id, "id");
            assertEq(uint8(z.portalType), uint8(a.portalType), "type");
            assertEq(z.nameIndex, a.nameIndex, "nameIndex");
            assertEq(z.spawnedAtHour, a.spawnedAtHour, "spawnedAtHour");
            assertEq(_hourOf(z.snapshotAt) + z.hoursToCollapse, collapseHour, "collapse hour");
            assertEq(uint256(z.snapshotAt), uint256(t2), "re-stamped at the sync");
            compared += 1;
        }
        assertGe(compared, 1, "no portal born before t1 survived to t2");
    }

    function _hourOf(uint40 ts) internal pure returns (uint256) {
        return (uint256(ts) - uint256(BASE)) / SPH;
    }

    // ── The fuse ─────────────────────────────────────────────────────────────

    /// More than MAX_CATCHUP_EVENTS events in one window (harness state: hp far
    /// above hpMax keeps the run alive, saturated debt refills every freed slot at
    /// once). The walk stops at the hour of the last processed event and says so
    /// like the pinned edge; `preview` and `sync` agree at that moment, and the
    /// next call carries on from there.
    function test_Fuse_PreviewEqualsSyncAndNextCallContinues() public {
        Game memory g = _game(0);
        g.hp = 60_000;
        g.spawnDebt = uint32(SPAWN_DEBT_MAX);
        harness.setGame(player, g);
        uint40 c = _ts(400);
        vm.warp(c);

        (Game memory pg, Portal[MAX_OPEN_PORTALS] memory pp, bool capped) = harness.preview(player);
        assertTrue(capped, "the fuse reports cappedShort");
        assertFalse(pg.finished, "alive");
        assertLt(uint256(pg.hoursElapsed), 400, "stopped before now");

        vm.recordLogs();
        harness.sync(player);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 events;
        for (uint256 k = 0; k < logs.length; k++) {
            bytes32 sig = logs[k].topics[0];
            if (sig == PortalLab.PortalCollapsed.selector || sig == PortalLab.PortalSpawned.selector) events += 1;
        }
        assertEq(events, MAX_CATCHUP_EVENTS, "exactly the fuse's worth of events");

        World memory first = _stored();
        World memory shown;
        shown.g = pg;
        shown.p = pp;
        _assertSame(first, shown, "fuse: preview vs sync");
        assertEq(uint256(first.g.lastTickAt), uint256(_ts(first.g.hoursElapsed)), "stamped at the stop hour");

        // The next call at the same moment continues the walk.
        harness.sync(player);
        Game memory second = harness.getGame(player);
        assertGt(uint256(second.spawnCount), uint256(first.g.spawnCount), "more births");
        assertGe(uint256(second.hoursElapsed), uint256(first.g.hoursElapsed), "never back in time");
    }

    // ── Deploy guard ─────────────────────────────────────────────────────────

    function test_ConstructorRejectsZeroEmptyCollapse() public {
        Config memory cfg = DefaultConfig.config();
        cfg.hpEmptyCollapse = 0;
        PortalTypeParams[5] memory tp = DefaultConfig.portalTypeParams();
        DeterministicSource src = new DeterministicSource(0);
        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "hpEmptyCollapse"));
        new PortalLab(cfg, tp, src);
    }
}
