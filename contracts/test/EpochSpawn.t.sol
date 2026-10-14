// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Game, Portal, Pending, PortalType, PortalStatus, Action, Config, MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {EffectsLib} from "../src/EffectsLib.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @title EpochSpawnTest — the per-epoch spawn entropy of Ticket 4.5.
/// @notice Covers 6.1–6.8: domain separation, past-immutability, one request
/// per absence, the combined cross+roll case, the free in-epoch path, sync/settle
/// never requesting, preview stopping at the pinned edge, and the bounded
/// look-ahead. The two-phase plumbing itself lives in TwoPhaseSurvey.t.sol; this
/// file is about WHICH epoch a spawn is pinned to and WHEN a word is fetched.
contract EpochSpawnTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    address internal player;

    uint40 internal constant BASE = 1_000_000;
    uint32 internal SPH;
    uint32 internal EPH;

    // Accept the change a paid sync refunds.
    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);
        Config memory c = DefaultConfig.config();
        SPH = c.secPerHour;
        EPH = c.epochHours;
        vm.deal(address(this), 1_000 ether);
        vm.warp(BASE);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _warpHours(uint32 h) internal {
        vm.warp(BASE + uint256(h) * SPH);
    }

    /// @dev Carry the world to now, paying across any epoch edge, then reveal.
    function _advance() internal {
        harness.sync{value: 1}(player);
        if (harness.getPending(player).active) {
            source.reveal(harness.getPending(player).requestId);
        }
    }

    /// @dev A started game made durable: hp 60_000 and nothing pinned. With
    /// epochHours 36 the first edge is hour 35, and a 50-hp empty lab can die
    /// before reaching it; these tests are about WHEN a word is fetched, not
    /// about surviving, so the run is given room (setup only, Ticket "36").
    function _startDurable() internal {
        harness.startGame();
        Game memory seeded = _game();
        seeded.hp = 60_000;
        harness.setGame(player, seeded);
        // setGame pins a generous coverage of its own; put "nothing pinned" back.
        harness.setCoverage(player, 0, 0);
    }

    function _reqCount() internal view returns (uint64) {
        return source.lastRequestId();
    }

    function _game() internal view returns (Game memory) {
        return harness.getGame(player);
    }

    function _portals() internal view returns (Portal[MAX_OPEN_PORTALS] memory) {
        return harness.getPortals(player);
    }

    // ── 6.1 / 3.3: domains are separated, irreversibly ───────────────────────

    /// An epoch seed never equals any of the three survey draws derived from the
    /// SAME word. The two share a word in a combined reveal (6.4), so a collision
    /// would couple a spawn to a survey roll.
    function test_EpochSeedNeverCollidesWithSurveyDraws() public pure {
        uint256[3] memory words =
            [uint256(keccak256("w0")), uint256(keccak256("w1")), type(uint256).max];
        for (uint256 wi = 0; wi < words.length; wi++) {
            uint256 word = words[wi];
            uint256 d0 = EffectsLib._fromWord(word, 0);
            uint256 d1 = EffectsLib._fromWord(word, 1);
            uint256 d2 = EffectsLib._fromWord(word, 2);
            for (uint256 e = 0; e < 100; e++) {
                uint256 s = TimeLib.epochSeed(word, e);
                assertTrue(s != d0, "epoch seed equals survey energy draw");
                assertTrue(s != d1, "epoch seed equals survey stability draw");
                assertTrue(s != d2, "epoch seed equals survey creatures draw");
            }
        }
    }

    // ── 6.3: one absence, one request ─────────────────────────────────────────

    function test_OneAbsenceOneRequest() public {
        // A high-HP game with nothing pinned yet, so a twenty-epoch absence does
        // not die to the deterministic overflow before we return (an empty lab from
        // a 50-HP start would overflow around hour 124 — see §5.5 — which is why we
        // seed a durable game here instead of relying on startGame's HP).
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 60_000;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        harness.setGame(player, g);
        harness.setCoverage(player, uint256(keccak256("seed")), 0); // nothing pinned
        assertEq(_reqCount(), 0, "set-up requests no word");

        // Leave for six epochs (it was twenty with epochHours 12: at 36 that is
        // 720 hours, and even 60_000 hp dies to the ramping pressure at hour 297),
        // come back, advance in a single paid sync.
        _warpHours(6 * EPH);
        harness.sync{value: 1}(player);
        assertTrue(harness.getPending(player).active, "crossing six epochs defers");
        assertEq(_reqCount(), 1, "exactly one request covers all six epochs");
        source.reveal(harness.getPending(player).requestId);
        assertEq(_reqCount(), 1, "reveal makes no further request");

        // The world reached the live hour; coverage now spans through this epoch.
        assertEq(uint256(_game().hoursElapsed), 6 * EPH, "world advanced to now");
    }

    // ── 4.5: startGame opens with zero portals and fetches nothing ────────────

    function test_StartGameRequestsNothingAndHasNoPortals() public {
        harness.startGame();
        assertEq(_reqCount(), 0, "no word requested at start");
        assertEq(uint256(_game().openPortals), 0, "no portals at start");
        assertEq(harness.epochWordOf(player), 0, "no word pinned yet");
        assertFalse(harness.getPending(player).active, "no deferral at start");
    }

    // ── 6.6: sync (unpaid) and settle never request ───────────────────────────

    function test_FreeSyncAndSettleNeverRequest() public {
        _startDurable();
        // A modest absence that does NOT reach the deterministic overflow (an empty
        // 50-HP lab survives well past five epochs), so the game is genuinely
        // unfinished at the pinned edge.
        _warpHours(5 * EPH);

        // Unpaid sync: advances only to the pinned edge (none yet → stays put),
        // and asks for no word even several epochs behind.
        harness.sync(player);
        assertEq(_reqCount(), 0, "unpaid sync requests nothing");
        assertFalse(harness.getPending(player).active, "unpaid sync never defers");

        // settle: the run is not finished at the edge, so it honestly refuses,
        // and it too asks for nothing.
        vm.expectRevert(PortalLab.GameNotFinished.selector);
        harness.settle(player);
        assertEq(_reqCount(), 0, "settle requests nothing");
    }

    /// Even a very long absence that ends in the deterministic 5.5 overflow is
    /// settled with no word: that death needs no randomness.
    function test_SettleOnDeterministicDeathNeedsNoWord() public {
        harness.startGame();
        // Far enough that the abandoned lab overflows and dies analytically.
        _warpHours(5000);
        harness.sync(player); // unpaid
        assertEq(_reqCount(), 0, "no word for the deterministic death");
        assertTrue(_game().finished, "long absence killed the run deterministically");
        harness.settle(player); // succeeds, still no word
        assertEq(_reqCount(), 0, "settle still requests nothing");
    }

    // ── 6.5: an in-epoch action with no roll is free and single-phase ─────────

    function test_InEpochActionIsFreeAndSinglePhase() public {
        _startDurable();
        // Advance a few hours INSIDE epoch 0 so a portal exists but no edge is hit.
        _warpHours(EPH - 2);
        _advance();
        uint64 afterSetup = _reqCount();

        Portal[MAX_OPEN_PORTALS] memory ps = _portals();
        // Find an open portal to toggle (ToggleQuestioned costs 0 power, no roll).
        bool found = false;
        uint8 slot;
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (ps[i].status != PortalStatus.Empty) {
                slot = i;
                found = true;
                break;
            }
        }
        assertTrue(found, "a portal spawned inside epoch 0");

        harness.act(slot, Action.ToggleQuestioned);
        assertFalse(harness.getPending(player).active, "in-epoch action is single-phase");
        assertEq(_reqCount(), afterSetup, "in-epoch action requests no word, takes no fee");
    }

    // ── 6.2: the past is never recomputed ─────────────────────────────────────

    function test_PastDoesNotChange() public {
        harness.startGame();
        // Portals are born at maturity while the player is away, and their
        // collapses cost HP: a 50-HP start would die before the second word. Seed
        // a durable lab so the property (a new word never re-rolls the past) is
        // what the test measures.
        Game memory seeded = _game();
        seeded.hp = 60_000;
        harness.setGame(player, seeded);
        // setGame pins a generous coverage of its own; put "nothing pinned" back so
        // the words are fetched by the epochs below, as in a played game.
        harness.setCoverage(player, 0, 0);

        // Live through a couple of epochs so several portals are pinned to the
        // words delivered so far.
        _warpHours(2 * EPH + 3);
        _advance();

        Portal[MAX_OPEN_PORTALS] memory before = _portals();
        // Snapshot the identity of every open portal (type + name + id never age).
        uint16[MAX_OPEN_PORTALS] memory ids;
        uint8[MAX_OPEN_PORTALS] memory types;
        uint16[MAX_OPEN_PORTALS] memory names;
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            ids[i] = before[i].id;
            types[i] = uint8(before[i].portalType);
            names[i] = before[i].nameIndex;
        }
        uint256 word1 = harness.epochWordOf(player);

        // Cross into further epochs, fetching a NEW word.
        _warpHours(4 * EPH + 1);
        _advance();
        uint256 word2 = harness.epochWordOf(player);
        assertTrue(word2 != word1, "a fresh word pinned the new epochs");

        // Every portal that still occupies its slot must carry the SAME identity:
        // the new word did not reach back and re-roll it.
        Portal[MAX_OPEN_PORTALS] memory afterP = _portals();
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (before[i].status == PortalStatus.Empty) continue;
            if (afterP[i].id != ids[i]) continue; // slot was freed and refilled — a new portal
            assertEq(uint8(afterP[i].portalType), types[i], "portal type changed under a new word");
            assertEq(afterP[i].nameIndex, names[i], "portal name changed under a new word");
        }
    }

    // ── 6.4: crossing AND rolling — one request serves both ───────────────────

    function test_CombinedCrossAndSurvey_OneRequest() public {
        _startDurable();
        // Advance to hour 11 (still epoch 0): the first portal appears at hour 10
        // once accrued pressure reaches spawnCostUnits, so one portal is now open.
        _warpHours(EPH - 1);
        _advance();
        uint64 afterSetup = _reqCount();

        // Find an unsurveyed open portal.
        Portal[MAX_OPEN_PORTALS] memory ps = _portals();
        uint8 slot = type(uint8).max;
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (ps[i].status != PortalStatus.Empty && !ps[i].surveyed) {
                slot = i;
                break;
            }
        }
        assertTrue(slot != type(uint8).max, "an unsurveyed portal to survey");

        // Now cross into the next epoch AND survey the portal in one act.
        _warpHours(EPH + 2); // hour 14, epoch 1 — the probe is capped short
        harness.act(slot, Action.SendObserver);
        assertTrue(harness.getPending(player).active, "the crossing survey deferred");
        assertEq(_reqCount(), afterSetup + 1, "ONE request serves both the spawns and the survey");

        source.reveal(harness.getPending(player).requestId);
        assertEq(_reqCount(), afterSetup + 1, "still one request after reveal");

        // The deferral resolved and the world advanced across the edge to the live
        // hour. Independence of the two derivations (spawns vs survey draws) from
        // the ONE shared word is proven structurally by
        // test_EpochSeedNeverCollidesWithSurveyDraws.
        assertFalse(harness.getPending(player).active, "deferral resolved");
        assertEq(uint256(_game().hoursElapsed), EPH + 2, "world at the live hour");
    }

    // ── 6.7: preview stops at the edge and equals an unpaid sync ──────────────

    function test_PreviewStopsAtEdgeAndMatchesSync() public {
        _startDurable();
        // Pin epoch 0 by advancing partway into it.
        _warpHours(EPH - 4);
        _advance();

        // Now jump past the pinned edge WITHOUT paying. The absence must stay
        // short: the seeded starting pressure kills an unattended lab at hour 97,
        // and a dead lab is a different code path (a deterministic §5.5 death is
        // evaluated over the FULL window, so the walk reports the death hour
        // rather than stopping at the edge). 4 * EPH keeps the lab alive there.
        _warpHours(4 * EPH);

        (Game memory gp, Portal[MAX_OPEN_PORTALS] memory pp, bool capped) = harness.preview(player);

        // preview cannot see past the end of the pinned epoch (epoch 0).
        assertTrue(capped, "preview capped at the pinned-epoch edge");
        assertLe(uint256(gp.hoursElapsed), uint256(EPH) - 1, "reached hour is within epoch 0");

        // An unpaid sync must land on exactly the same world preview projected.
        harness.sync(player);
        Game memory gs = _game();
        Portal[MAX_OPEN_PORTALS] memory psy = _portals();
        assertEq(uint256(gs.hoursElapsed), uint256(gp.hoursElapsed), "sync hours == preview hours");
        assertEq(uint256(gs.spawnDebt), uint256(gp.spawnDebt), "sync debt == preview debt");
        assertEq(uint256(gs.openPortals), uint256(gp.openPortals), "sync openPortals == preview");
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            assertEq(uint8(psy[i].status), uint8(pp[i].status), "status matches");
            assertEq(psy[i].id, pp[i].id, "id matches");
            assertEq(uint8(psy[i].portalType), uint8(pp[i].portalType), "type matches");
            assertEq(psy[i].nameIndex, pp[i].nameIndex, "name matches");
        }
    }

    // ── 8.1: worst-case epoch-crossing reveal gas ─────────────────────────────

    /// Return after twenty epochs to a full twelve-portal lab, so the reveal's
    /// catch-up processes a wave of collapses and refills every freed slot with a
    /// birth at once. This is the heaviest `receiveWord` path a REAL game can
    /// reach (hp <= hpMax). The Pyth callback limit is 1 000 000 gas; a blocker is
    /// anything closer than a third of it (>= 666 667).
    ///
    /// Why this state. Births now happen at maturity inside the window, so the
    /// work of a reveal grows with the number of events it meets, and HP is what
    /// bounds that number: every collapse costs HP and a full lab drains it. The
    /// heaviest reachable shape keeps the lab full at the edge (so the abandoned-lab
    /// rule beyond the edge does not end the run before the word arrives), makes the
    /// twelve stored collapses as cheap as possible (surveyed and empty: 3 hp each),
    /// and holds enough debt to refill each freed slot immediately. A reviewer
    /// sweep over debt 0..200 000, collapse staggers 0..3 hours, absences of 1, 2
    /// and 20 epochs and three portal types peaked at about 595 000 gas, with this
    /// debt and stagger. (The former stand had 60 000 hp: unreachable, and with
    /// births at maturity it walks the full 64-event fuse.)
    function test_Gas_CrossingRevealWorstCase_UnderBudget() public {
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100; // hpMax: the most a real game can hold, so the most events it can meet
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 12;
        g.spawnDebt = 110_000; // eleven portals' worth: every freed slot refills at once
        harness.setGame(player, g);
        harness.setCoverage(player, uint256(keccak256("seed")), 0); // nothing pinned

        // Twelve occupied portals collapsing at staggered hours 1..12, surveyed and
        // empty (the cheapest collapse, so the most of them before death),
        // snapshotted at BASE.
        for (uint8 i = 0; i < 12; i++) {
            Portal memory p;
            p.status = PortalStatus.Open;
            p.portalType = PortalType.LongLived;
            p.snapshotAt = BASE;
            p.hoursToCollapse = uint16(i + 1);
            p.surveyed = true;
            p.creaturesKnown = true;
            harness.setPortal(player, i, p);
        }

        // Twenty epochs away, then one paid sync to carry the world over.
        _warpHours(20 * EPH);
        harness.sync{value: 1}(player);
        uint64 reqId = harness.getPending(player).requestId;
        assertTrue(harness.getPending(player).active, "deferred across the edge");

        uint256 before = gasleft();
        source.reveal(reqId);
        uint256 used = before - gasleft();

        console2.log("crossing-reveal worst-case gas used (incl. source dispatch):", used);
        assertLt(used, 666_667, "crossing reveal must stay well under the 1M callback limit");
        // The wave really happened: the stored portals collapsed and their slots
        // were refilled by births inside the window.
        assertGe(uint256(harness.getGame(player).spawnCount), 10, "freed slots were refilled");
        assertFalse(harness.getPending(player).active, "deferral resolved");
    }

    // ── 6.8: look-ahead is bounded by one epoch ───────────────────────────────

    /// A player who has just entered an epoch can compute spawns no further than
    /// the end of THAT epoch — at most `epochHours` hours — and not one hour more.
    /// We land the world exactly at an epoch boundary, then show an unpaid sync
    /// from arbitrarily far in the future advances only to that epoch's last hour.
    function test_LookaheadBoundedToOneEpoch() public {
        // Seed a durable game sitting exactly at the start of epoch 3, with
        // coverage pinned through epoch 3 (coveredEpochs == 4). High HP so the
        // deterministic §5.5 overflow does not intervene and mask the cap.
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE + 3 * uint40(EPH) * uint40(SPH);
        g.hoursElapsed = 3 * EPH;
        g.hp = 60_000;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        harness.setGame(player, g);
        harness.setCoverage(player, uint256(keccak256("seed")), 4); // epochs 0..3 pinned

        // From here, with no further payment, the world can be projected at most to
        // the last hour of epoch 3 — epochHours-1 hours ahead — no matter how far
        // real time has run.
        _warpHours(3 * EPH + 100 * EPH);
        (Game memory gLook,,) = harness.preview(player);
        assertEq(uint256(gLook.hoursElapsed), 4 * uint256(EPH) - 1, "projection ends at epoch 3's last hour");
        assertEq(uint256(gLook.hoursElapsed) - 3 * uint256(EPH), uint256(EPH) - 1, "exactly epochHours-1 hours ahead");
    }
}
