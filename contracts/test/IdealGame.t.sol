// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Game, Portal, Config, PortalTypeParams, PortalStatus, Action, Refusal,
    RiskLevel, MAX_OPEN_PORTALS, PortalType
} from "../src/PortalLabTypes.sol";
import {RiskLib} from "../src/RiskLib.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";

/// @title IdealGame — proof that gameplay is finite and measurement of survival duration.
/// @notice Two parts:
///   PART A: analytical boundary. Pure calculation (no contract calls) proving that
///           a run cannot exceed hour H, where H = (maxRemovalPerHour - base) / ramp.
///   PART B: dual simulation. Bystander run (no actions) vs. active run (a rational
///           TRIAGE policy) on four different addresses. Measures how much longer skill
///           extends survival, and instruments WHY a run ends.
contract IdealGameTest is Test {
    PortalLab internal lab;
    /// @dev Test randomness source (fee 0). Surveys are two-phase (SPEC §6.3):
    /// the simulation commits via `lab.act(SendObserver)` and immediately reveals
    /// via `source.reveal(...)` in the same step, since no time passes between
    /// them the reveal always applies (never cancels).
    DeterministicSource internal source;

    /// @dev Minimum hours remaining on a portal before we send crew in.
    /// One hour to enter, one to exit, two hours buffer (another crew member may be
    /// queued for recall and the policy allows exactly one action per game hour).
    uint16 constant MIN_EXIT_MARGIN = 4; // game hours

    // ─── Task 4.3: entropy measurement helpers ────────────────────────────────

    /// @dev Per-seed arrays for entropy distribution stats (Task 4.3).
    /// One struct to consume a single stack slot instead of 7 separate array vars.
    struct EntropyArrays {
        uint32[128] totalActs;       // all player act() calls
        uint32[128] actionsWithRoll; // acts that consumed RNG (survey + blind rescue)
        uint32[128] draws;           // RandomStub.draw() calls: survey×3 + spawn×3 (blind rescue via _fromWord after T4.6)
        uint32[128] spawned;         // portals spawned (fg.spawnCount)
        uint32[128] txWithSpawn;     // game-hour ticks with ≥1 new spawn
        uint32[128] requestsA;       // policy A: all acts (elapsed >= 1 always)
        uint32[128] requestsB;       // policy B: info-buying acts only
    }

    /// @dev Running totals for entropy aggregates.
    struct EntropyAgg {
        uint64 totalActs;
        uint64 actionsWithRoll;
        uint64 draws;
        uint64 spawned;
        uint64 txWithSpawn;
    }

    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Per-run instrumentation for an active game (SPEC §4.4 balance proof).
    struct Stats {
        uint32 surveys; // SendObserver
        uint32 recallObservers; // RecallObserver
        uint32 sendRescuers; // SendRescuer
        uint32 evacuations; // Evacuate
        uint32 recallRescuers; // RecallRescuer
        uint32 closes; // Close (honest-benefit policy, ticket 2.2)
        uint32 creaturesRescued; // total creatures pulled out by Evacuate
        uint32 hpHealed; // total HP recovered by Evacuate
        uint32 collapses; // portals that collapsed on their own
        uint32 powerStarvedHours; // hours the player did NOTHING purely for want of power
        // Ticket 2.2 measures.
        uint32 blindRescues; // SendRescuer into an UNSURVEYED portal (P6)
        uint32 blindRescuesEmpty; // of those, the ones that found an empty portal (bet lost)
        uint32 rescuerRecoveryHours; // total game hours rescuers spent recovering after empty blind entries
        uint32 closeHpSaved; // sum of the honest close-benefit over every Close performed (P7)
        uint32 creaturesLeftBehind; // creatures stranded by blind evacuations ("one is always left in the dark")
        uint32 knowledgeCostPos; // sum over surveyed collapses where knowledge cost MORE than the blind midpoint
        uint32 knowledgeCostNeg; // sum over surveyed collapses where knowledge SAVED vs the blind midpoint
        // HP ledger — populated from event logs via vm.recordLogs / vm.getRecordedLogs.
        uint32 collapseHpWithDeaths; // HP lost in PortalCollapsed events where deaths > 0
        uint32 collapseCountWithDeaths; // count of such collapses
        uint32 collapseHpEmpty; // HP lost in PortalCollapsed events where deaths == 0
        uint32 collapseCountEmpty; // count of empty collapses
        uint32 closeHpFromLogs; // HP lost in PortalClosed events (expected: 0 — never forced)
        uint32 closedFromLogs; // count of PortalClosed events (cross-check vs closes)
        uint32 rescuedFromLogs; // total creatures from CreaturesRescued events
        uint32 hpGainedFromLogs; // total HP from CreaturesRescued events
        // Ticket 2.3 §4: power-starvation breakdown.
        uint32 starvedSurveys;
        uint32 starvedRecallObs;
        uint32 starvedSendRescuers;
        uint32 starvedEvacuations;
        uint32 starvedRecallRescuers;
        uint32 starvedCloses;
        uint32 urgentStarvedHours;    // §4.2: starved where hoursToCollapse <= 3
        uint32 urgentWithLivesHours;  // §4.3: of urgent, portal has lives
        uint32 powerDeficitSum;       // §4.4: sum(cost - power) per starvation event
        uint32 maxStarvedStreak;      // §4.5: longest consecutive starved-hour run
        // Task 4.3: entropy measurement.
        uint32 spawnedPortals;        // total portals that appeared (= fg.spawnCount)
        uint32 txWithSpawn;           // game-hour ticks where ≥1 portal was spawned
    }

    function setUp() public {
        Config memory c = DefaultConfig.config();
        PortalTypeParams[5] memory params = DefaultConfig.portalTypeParams();
        source = new DeterministicSource(0);
        lab = new PortalLab(c, params, source);
        // The simulation PAYS for its own sync calls so the world advances across
        // epoch edges (Ticket 4.5 §4.4 amended): the fee is 0 here, so a single
        // wei of attached value flips sync onto the paid, two-phase path; the wei
        // is refunded as change each time. A balance and a payable receiver make
        // that possible.
        vm.deal(address(this), 1_000_000 ether);
    }

    /// @dev Accept the change refunded by a paid `sync`.
    receive() external payable {}

    /// @dev Carry `player`'s world to the live timestamp, paying for a word when
    /// the world hits the pinned-epoch edge (Ticket 4.5). One wei of value selects
    /// the paid path (fee is 0); if a deferral results, deliver the word at once —
    /// no time passes, so the catch-up always applies. After this the world is at
    /// the live hour and its epochs are pinned, so the policy's own acts never need
    /// to cross an edge and stay single-phase (surveys excepted, Ticket 4.4).
    function _advance(address player) private {
        lab.sync{value: 1}(player);
        if (lab.getPending(player).active) {
            source.reveal(lab.getPending(player).requestId);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    // PART A: Analytical Boundary (No Contract Calls)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Prove that a game run is finite by computing the critical hour H
    /// beyond which spawn pressure MUST exceed removal capacity, and the player
    /// must eventually die.
    ///
    /// Derivation (in favor of the player):
    ///   - ASSUMPTION 1: All 12 slots are Energetic portals, yielding max.
    ///   - ASSUMPTION 2: Surveys are free (no power cost, immediate).
    ///   - ASSUMPTION 3: Creatures never interfere; all rescues are free.
    ///   - Under these assumptions:
    ///       maxYield = max(powerYieldPerHour) over all types.
    ///       maxIncome = powerRegenPerHour + MAX_OPEN_PORTALS * maxYield
    ///           = max power regained per hour, never exceeding powerMax.
    ///       netPerClose = spawnCostUnits - closePressureBonus
    ///           = net pressure cost to remove one portal (close minus bonus).
    ///       maxRemovalPerHour = maxIncome * netPerClose / costClose
    ///           = max pressure that can be removed per hour,
    ///           = by spending ALL regenerated power on closes.
    ///   - spawn pressure grows as:
    ///       spawnRate(h) = basePressurePerHour + pressureRampPerHour * h.
    ///   - The critical hour H is the smallest hour where spawnRate(H) > maxRemovalPerHour.
    ///     After H, the player drowns in new portals faster than they can close them.
    ///   - If pressureRampPerHour == 0, no such H exists: pressure plateaus and
    ///     the game can be infinite (balance requirement violated).
    ///   - The boundary itself is a guarantee only for PERFECT play with INFINITE
    ///     crew and ZERO dead creatures. Real play yields hours < H (Requirement 4.4).
    function test_analyticalBoundary_PartA() public pure {
        Config memory c = DefaultConfig.config();
        PortalTypeParams[5] memory types = DefaultConfig.portalTypeParams();

        // A1. Ramp must be positive.
        assertGt(c.pressureRampPerHour, 0,
            "CRITICAL: pressureRampPerHour == 0 means no finite boundary; "
            "the game can run forever. Balance is broken.");

        // A2. Maximum yield: pick the highest powerYieldPerHour across all five types.
        uint256 maxYield = 0;
        for (uint8 i = 0; i < 5; i++) {
            if (types[i].powerYieldPerHour > maxYield) {
                maxYield = types[i].powerYieldPerHour;
            }
        }

        // A3. Max income per hour: base regen + (all 12 slots Energetic).
        uint256 maxIncome = uint256(c.powerRegenPerHour) + MAX_OPEN_PORTALS * maxYield;

        // A4. Net pressure cost to remove one portal.
        //     (what you spend) - (what you gain back) = close power cost * (spawn cost per power).
        uint256 netPerClose = uint256(c.spawnCostUnits) - uint256(c.closePressureBonus);

        // A5. Must not be negative or zero (else closing is useless / backwards).
        assertTrue(netPerClose > 0 && netPerClose < uint256(c.spawnCostUnits),
            "CRITICAL: closePressureBonus >= spawnCostUnits means closing a portal "
            "generates net positive pressure. Removal is impossible.");

        // A6. Max pressure removal per hour: spend all income on closes.
        //     We can close (maxIncome / costClose) portals, each removing netPerClose pressure.
        //     Result is in raw pressure units (not scaled by spawnCostUnits).
        //
        //     MULTIPLY BEFORE DIVIDING — dividing first truncates the fractional
        //     portal-per-hour and thereby UNDERSTATES the player's capability,
        //     which makes the boundary unsound (the proof "even so, he dies" is
        //     worthless if we secretly clipped his powers). Overflow is impossible:
        //     maxIncome <= ~65k and netPerClose < spawnCostUnits <= ~4e9, so the
        //     product is < ~2.6e14, far below uint256.
        uint256 maxRemovalPerHour;
        if (c.costClose > 0) {
            maxRemovalPerHour = maxIncome * netPerClose / uint256(c.costClose);
        } else {
            maxRemovalPerHour = 0;
        }

        // A7. Max removal must exceed base spawn rate (else stalled at zero).
        assertGt(maxRemovalPerHour, uint256(c.basePressurePerHour),
            "CRITICAL: maxRemovalPerHour <= basePressurePerHour means the player "
            "is doomed even at hour 0 (can never close faster than spawn). "
            "Balance is broken the other way.");

        // A8. Find the critical hour H: smallest h where spawnRate(h) > maxRemovalPerHour.
        //     spawnRate(h) = base + ramp * h
        //     base + ramp * h > maxRemoval
        //     ramp * h > maxRemoval - base
        //     h > (maxRemoval - base) / ramp
        //     H = floor((maxRemoval - base) / ramp) + 1 (first h where inequality holds)
        //
        //     CAREFUL: integer division floors. We want the FIRST hour where strict >.
        uint256 H;
        {
            uint256 diff = maxRemovalPerHour - uint256(c.basePressurePerHour);
            uint256 ramp = uint256(c.pressureRampPerHour);
            H = (diff / ramp) + 1;
        }

        // A9. Boundary validation: spawnRate(H) MUST be > max removal,
        //     and spawnRate(H-1) MUST be <= max removal.
        uint256 spawnRateAtH = uint256(c.basePressurePerHour) + uint256(c.pressureRampPerHour) * H;
        uint256 spawnRateAtHminus1 = uint256(c.basePressurePerHour) + uint256(c.pressureRampPerHour) * (H > 0 ? H - 1 : 0);

        assertGt(spawnRateAtH, maxRemovalPerHour,
            "BOUNDARY ERROR: spawnRate(H) <= maxRemovalPerHour. "
            "H is not actually critical.");

        assertTrue(spawnRateAtHminus1 <= maxRemovalPerHour,
            "BOUNDARY ERROR: spawnRate(H-1) > maxRemovalPerHour. "
            "There is an earlier critical hour.");

        // A10. Independent anchor — values hand-computed from DefaultConfig:
        //       maxIncome         = powerRegenPerHour + MAX_OPEN_PORTALS * maxYield
        //                         = 5 + 12*4 = 53
        //       netPerClose       = spawnCostUnits - closePressureBonus
        //                         = 10_000 - 2_500 = 7_500
        //       maxRemovalPerHour = maxIncome * netPerClose / costClose
        //                         = 53 * 7_500 / 25 = 15_900
        //       H                 = (maxRemovalPerHour - basePressurePerHour) / pressureRampPerHour + 1
        //                         = (15_900 - 1_000) / 1 + 1 = 14_901
        //
        //       If DefaultConfig changes, recompute BOTH numbers BY HAND and re-enter.
        //       DO NOT copy what the test printed — that defeats the purpose of the anchor.
        assertEq(maxRemovalPerHour, 15_900,
            "ANCHOR: maxRemovalPerHour changed. Recompute from DefaultConfig by hand.");
        assertEq(H, 14_901,
            "ANCHOR: H changed. Recompute from DefaultConfig by hand.");

        // A11. H must fit in uint32 (the game hour type).
        assertLe(H, type(uint32).max,
            "OVERFLOW: Critical hour H exceeds uint32. "
            "Cannot represent game state at boundary.");

        // A12. hpOverflowPerHour must be positive (the mechanism that kills overflow).
        assertGt(c.hpOverflowPerHour, 0,
            "CRITICAL: hpOverflowPerHour == 0 means 12-slot overflow never kills. "
            "The mechanism does not exist.");

        // A13. Log the boundary and all intermediate values.
        console2.log("=== ANALYTICAL BOUNDARY (PART A) ===");
        console2.log("Max yield per type (Energetic):", maxYield);
        console2.log("Max income per hour (12 Energetic):", maxIncome);
        console2.log("Net pressure cost per close:", netPerClose);
        console2.log("Max pressure removal per hour:", maxRemovalPerHour);
        console2.log("Base spawn rate (hour 0):", c.basePressurePerHour);
        console2.log("Pressure ramp per hour:", c.pressureRampPerHour);
        console2.log("");
        console2.log("CRITICAL HOUR H:", H);
        console2.log("spawnRate(H):", spawnRateAtH);
        console2.log("spawnRate(H-1):", spawnRateAtHminus1);
        console2.log("Survival ceiling in real-world seconds:", H * uint256(c.secPerHour));
        console2.log("Survival ceiling in real-world hours:", H * uint256(c.secPerHour) / 3600);
        console2.log("");
        console2.log("NOTE: All guarantees above assume perfect play with infinite crew");
        console2.log("      and zero creature interference. Real play yields H' < H.");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // PART B: Dual Simulation (Bystander vs. Active)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Run two games per address: one idle (D0), one active (D1). Runs for
    /// 128 deterministic addresses and prints distribution statistics. Per-seed details
    /// are NOT printed — the goal is to measure the distribution, not individual runs.
    ///
    /// Addresses: address(uint160(0x1000 + i)) for i = 0..127.
    ///   D0 = bystander (no actions, pure aging until death).
    ///   D1 = active (rational TRIAGE policy, one action per game hour).
    ///
    /// Logs are recorded and parsed INSIDE _runActiveGame (per run). The buffer resets
    /// at the start of each active run so it never grows across seeds.
    ///
    /// The ONLY assertions: all 256 runs finished in death before the 3000-hour horizon.
    /// No D1/D0 ratio thresholds — this test MEASURES, it does not police ratios.
    function test_dualSimulation_PartB() public {
        Config memory c = lab.config();

        // Number of seeds: 8 by default (fits the stock Foundry caps in
        // [profile.default]), overridden via SEEDS env var.
        // Full sweep: FOUNDRY_PROFILE=sweep SEEDS=128 forge test --match-test dualSimulation -vv
        uint256 seeds = vm.envOr("SEEDS", uint256(4));

        // BASE_OFFSET shifts the player addresses so multiple sweep runs (0, 1000,
        // 2000) cover different seed families for the distribution corridor check.
        uint256 baseOffset = vm.envOr("BASE_OFFSET", uint256(0));

        // Survival-hour arrays — fixed 128-slot capacity, first `seeds` slots used.
        uint32[128] memory d0s;
        uint32[128] memory d1s;
        uint32[128] memory ratios; // D1/D0 in percent (integer), one value per seed
        uint32[128] memory crs; // creatures rescued per active run (Task 4.4 distribution guard)
        uint32[128] memory reqs; // Pyth requests per ACTIVE run (Ticket 4.5 §8.2)

        // Histogram: 0-50, 50-100, 100-150, 150-200, 200-300, 300-500, 500+
        uint32[7] memory histD0;
        uint32[7] memory histD1;

        // Task 4.3: entropy tracking arrays and aggregates (one struct slot each).
        EntropyArrays memory ea;
        EntropyAgg memory eaAgg;

        // Aggregate stats over all D1 runs. uint64 avoids overflow at 128 × uint32.
        uint64 aggSurveys;
        uint64 aggRecallObservers;
        uint64 aggSendRescuers;
        uint64 aggEvacuations;
        uint64 aggRecallRescuers;
        uint64 aggCloses;
        uint64 aggCollapseCountWithDeaths;
        uint64 aggCollapseHpWithDeaths;
        uint64 aggCollapseCountEmpty;
        uint64 aggCollapseHpEmpty;
        uint64 aggCreaturesRescued;
        uint64 aggHpHealed;
        uint64 aggObserversLost;
        uint64 aggRescuersLost;
        uint64 aggPowerStarvedHours;
        uint64 aggBlindRescues;
        uint64 aggBlindRescuesEmpty;
        uint64 aggRescuerRecoveryHours;
        uint64 aggCloseHpSaved;
        uint64 aggCreaturesLeftBehind;
        uint64 aggKnowledgeCostPos;
        uint64 aggKnowledgeCostNeg;
        // Ticket 2.3 §4 aggregates.
        uint64 aggStarvedSurveys;
        uint64 aggStarvedRecallObs;
        uint64 aggStarvedSendRescuers;
        uint64 aggStarvedEvacuations;
        uint64 aggStarvedRecallRescuers;
        uint64 aggStarvedCloses;
        uint64 aggUrgentStarvedHours;
        uint64 aggUrgentWithLivesHours;
        uint64 aggPowerDeficitSum;
        uint32 maxStarvedStreakAll;

        uint32 countNoGain; // seeds where D1 <= D0 (skill gave no benefit)

        console2.log("=== DUAL SIMULATION (PART B) ===");
        console2.log("BASE_OFFSET:", baseOffset, "  Seeds:", seeds);
        console2.log("address(uint160(0x1000 + baseOffset + i)), i = 0..seeds-1.");
        console2.log("D0 = bystander (no actions). D1 = active (TRIAGE policy, 1 act/h).");
        console2.log("Horizon: 3000 game hours. Logs parsed per run, buffer reset each seed.");

        for (uint256 i = 0; i < seeds; i++) {
            address player = address(uint160(0x1000 + baseOffset + i));

            uint32 d0 = _runBystanderGame(player, c);
            uint64 reqBefore = source.lastRequestId(); // Ticket 4.5 §8.2
            (uint32 d1, Stats memory s) = _runActiveGame(player, c);
            reqs[i] = uint32(source.lastRequestId() - reqBefore);

            d0s[i]    = d0;
            d1s[i]    = d1;
            crs[i]    = s.creaturesRescued;
            ratios[i] = d0 > 0 ? uint32((uint256(d1) * 100) / uint256(d0)) : 0;

            if (d1 <= d0) countNoGain++;

            histD0[_histBucket(d0)] += 1;
            histD1[_histBucket(d1)] += 1;

            aggSurveys                 += s.surveys;
            aggRecallObservers         += s.recallObservers;
            aggSendRescuers            += s.sendRescuers;
            aggEvacuations             += s.evacuations;
            aggRecallRescuers          += s.recallRescuers;
            aggCloses                  += s.closes;
            aggCollapseCountWithDeaths += s.collapseCountWithDeaths;
            aggCollapseHpWithDeaths    += s.collapseHpWithDeaths;
            aggCollapseCountEmpty      += s.collapseCountEmpty;
            aggCollapseHpEmpty         += s.collapseHpEmpty;
            aggCreaturesRescued        += s.creaturesRescued;
            aggHpHealed                += s.hpHealed;

            aggObserversLost += s.surveys > s.recallObservers
                ? uint64(s.surveys - s.recallObservers) : 0;
            // A rescuer send is "accounted for" when the rescuer comes back: by an
            // evacuation, by a recall, or by returning from recovery after an empty
            // blind entry (which never put anyone at a collapse). The remainder were
            // lost inside collapsing portals.
            {
                uint32 returned = s.evacuations + s.recallRescuers + s.blindRescuesEmpty;
                aggRescuersLost += s.sendRescuers > returned ? uint64(s.sendRescuers - returned) : 0;
            }
            aggPowerStarvedHours += s.powerStarvedHours;
            aggBlindRescues          += s.blindRescues;
            aggBlindRescuesEmpty     += s.blindRescuesEmpty;
            aggRescuerRecoveryHours  += s.rescuerRecoveryHours;
            aggCloseHpSaved          += s.closeHpSaved;
            aggCreaturesLeftBehind   += s.creaturesLeftBehind;
            aggKnowledgeCostPos      += s.knowledgeCostPos;
            aggKnowledgeCostNeg      += s.knowledgeCostNeg;
            aggStarvedSurveys        += s.starvedSurveys;
            aggStarvedRecallObs      += s.starvedRecallObs;
            aggStarvedSendRescuers   += s.starvedSendRescuers;
            aggStarvedEvacuations    += s.starvedEvacuations;
            aggStarvedRecallRescuers += s.starvedRecallRescuers;
            aggStarvedCloses         += s.starvedCloses;
            aggUrgentStarvedHours    += s.urgentStarvedHours;
            aggUrgentWithLivesHours  += s.urgentWithLivesHours;
            aggPowerDeficitSum       += s.powerDeficitSum;
            if (s.maxStarvedStreak > maxStarvedStreakAll) maxStarvedStreakAll = s.maxStarvedStreak;

            assertTrue(d0 > 0, "Bystander game did not finish (logic error).");
            assertTrue(d1 > 0, "Active game did not finish (logic error).");

            // Task 4.3: fill per-seed entropy arrays.
            {
                // Player acts = all explicit act() calls (idle hours are NOT acts).
                uint32 _ta = s.surveys + s.recallObservers + s.sendRescuers
                    + s.evacuations + s.recallRescuers + s.closes;
                // Actions that consumed RNG: precise/deaf surveys and blind rescues.
                uint32 _aw = s.surveys + s.blindRescues;
                // Total RandomStub.draw() calls: survey=3, spawn=3 each.
                // Blind rescues use _fromWord (Ticket 4.6), not RandomStub.draw().
                uint32 _dr = s.surveys * 3 + s.spawnedPortals * 3;
                ea.totalActs[i]       = _ta;
                ea.actionsWithRoll[i] = _aw;
                ea.draws[i]           = _dr;
                ea.spawned[i]         = s.spawnedPortals;
                ea.txWithSpawn[i]     = s.txWithSpawn;
                // Policy A: all acts need a request (sim advances 1h between acts → elapsed always ≥ 1).
                ea.requestsA[i]  = _ta;
                // Policy B: only info-buying actions (survey + blind rescue).
                ea.requestsB[i]  = _aw;
                eaAgg.totalActs       += _ta;
                eaAgg.actionsWithRoll += _aw;
                eaAgg.draws           += _dr;
                eaAgg.spawned         += s.spawnedPortals;
                eaAgg.txWithSpawn     += s.txWithSpawn;
            }
        }

        // Sort first `seeds` elements of each array ascending for percentiles.
        _sortN(d0s, seeds);
        _sortN(d1s, seeds);
        _sortN(ratios, seeds);

        // ── D0 distribution ──────────────────────────────────────────────
        // P10 index = floor((seeds-1) * 0.10); P90 index = floor((seeds-1) * 0.90).
        console2.log("");
        console2.log("=== D0 (BYSTANDER) distribution, game hours ===");
        {
            uint64 sumD0 = 0;
            for (uint256 i = 0; i < seeds; i++) sumD0 += d0s[i];
            console2.log("  min:   ", uint256(d0s[0]));
            console2.log("  P10:   ", uint256(d0s[(seeds - 1) / 10]));
            console2.log("  median:", uint256(_medianN(d0s, seeds)));
            console2.log("  P90:   ", uint256(d0s[(seeds - 1) * 9 / 10]));
            console2.log("  max:   ", uint256(d0s[seeds - 1]));
            console2.log("  mean:  ", uint256(seeds > 0 ? sumD0 / seeds : 0));
        }
        console2.log("  histogram  0-50   :", uint256(histD0[0]));
        console2.log("             50-100 :", uint256(histD0[1]));
        console2.log("             100-150:", uint256(histD0[2]));
        console2.log("             150-200:", uint256(histD0[3]));
        console2.log("             200-300:", uint256(histD0[4]));
        console2.log("             300-500:", uint256(histD0[5]));
        console2.log("             500+   :", uint256(histD0[6]));

        // ── D1 distribution ──────────────────────────────────────────────
        console2.log("");
        console2.log("=== D1 (ACTIVE TRIAGE) distribution, game hours ===");
        {
            uint64 sumD1 = 0;
            for (uint256 i = 0; i < seeds; i++) sumD1 += d1s[i];
            console2.log("  min:   ", uint256(d1s[0]));
            console2.log("  P10:   ", uint256(d1s[(seeds - 1) / 10]));
            console2.log("  median:", uint256(_medianN(d1s, seeds)));
            console2.log("  P90:   ", uint256(d1s[(seeds - 1) * 9 / 10]));
            console2.log("  max:   ", uint256(d1s[seeds - 1]));
            console2.log("  mean:  ", uint256(seeds > 0 ? sumD1 / seeds : 0));
        }
        console2.log("  histogram  0-50   :", uint256(histD1[0]));
        console2.log("             50-100 :", uint256(histD1[1]));
        console2.log("             100-150:", uint256(histD1[2]));
        console2.log("             150-200:", uint256(histD1[3]));
        console2.log("             200-300:", uint256(histD1[4]));
        console2.log("             300-500:", uint256(histD1[5]));
        console2.log("             500+   :", uint256(histD1[6]));

        // ── Creatures rescued distribution (Task 4.4 guard) ───────────────
        _sortN(crs, seeds);
        console2.log("");
        console2.log("=== CREATURES RESCUED (ACTIVE) distribution ===");
        {
            uint64 sumCr = 0;
            for (uint256 i = 0; i < seeds; i++) sumCr += crs[i];
            console2.log("  min:   ", uint256(crs[0]));
            console2.log("  median:", uint256(_medianN(crs, seeds)));
            console2.log("  P90:   ", uint256(crs[(seeds - 1) * 9 / 10]));
            console2.log("  max:   ", uint256(crs[seeds - 1]));
            console2.log("  mean:  ", uint256(seeds > 0 ? sumCr / seeds : 0));
        }

        // ── Pyth requests per ACTIVE run (Ticket 4.5 §8.2) ────────────────
        // Each epoch the world enters costs one word (a paid sync here, folded
        // into an act for a real player), plus one per survey (blind rescue still
        // uses the stub, Ticket 4.6). This is the ACTUAL request count, unlike the
        // theoretical policy A/B figures reported further below.
        _sortN(reqs, seeds);
        console2.log("");
        console2.log("=== PYTH REQUESTS PER ACTIVE RUN (TICKET 4.5 s8.2) ===");
        {
            uint64 sumRq = 0;
            for (uint256 i = 0; i < seeds; i++) sumRq += reqs[i];
            console2.log("  min:   ", uint256(reqs[0]));
            console2.log("  median:", uint256(_medianN(reqs, seeds)));
            console2.log("  P90:   ", uint256(reqs[(seeds - 1) * 9 / 10]));
            console2.log("  max:   ", uint256(reqs[seeds - 1]));
            console2.log("  mean:  ", uint256(seeds > 0 ? sumRq / seeds : 0));
        }

        // ── D1/D0 ratio ──────────────────────────────────────────────────
        console2.log("");
        console2.log("=== D1/D0 RATIO ===");
        {
            uint64 sumRatio = 0;
            for (uint256 i = 0; i < seeds; i++) sumRatio += ratios[i];
            console2.log("  average ratio (%): ", uint256(seeds > 0 ? sumRatio / seeds : 0));
            console2.log("  median ratio (%):  ", uint256(_medianN(ratios, seeds)));
            console2.log("  seeds where D1 <= D0:", uint256(countNoGain));
        }

        // ── Aggregate action stats ────────────────────────────────────────
        console2.log("");
        console2.log("=== ACTIVE RUN AGGREGATE (sum / avg per run) ===");
        console2.log("  surveys          total", uint256(aggSurveys),        "avg", uint256(seeds > 0 ? uint256(aggSurveys) / seeds : 0));
        console2.log("  recall obs       total", uint256(aggRecallObservers),"avg", uint256(seeds > 0 ? uint256(aggRecallObservers) / seeds : 0));
        console2.log("  send rescuers    total", uint256(aggSendRescuers),   "avg", uint256(seeds > 0 ? uint256(aggSendRescuers) / seeds : 0));
        console2.log("  evacuations      total", uint256(aggEvacuations),    "avg", uint256(seeds > 0 ? uint256(aggEvacuations) / seeds : 0));
        console2.log("  recall rescuers  total", uint256(aggRecallRescuers), "avg", uint256(seeds > 0 ? uint256(aggRecallRescuers) / seeds : 0));
        console2.log("  closes           total", uint256(aggCloses),         "avg", uint256(seeds > 0 ? uint256(aggCloses) / seeds : 0));
        console2.log("  collapses w/deaths count  total", uint256(aggCollapseCountWithDeaths), "avg", uint256(seeds > 0 ? uint256(aggCollapseCountWithDeaths) / seeds : 0));
        console2.log("  HP lost collapses w/deaths total", uint256(aggCollapseHpWithDeaths),   "avg", uint256(seeds > 0 ? uint256(aggCollapseHpWithDeaths) / seeds : 0));
        console2.log("  empty collapses count     total", uint256(aggCollapseCountEmpty),      "avg", uint256(seeds > 0 ? uint256(aggCollapseCountEmpty) / seeds : 0));
        console2.log("  HP lost empty collapses   total", uint256(aggCollapseHpEmpty),         "avg", uint256(seeds > 0 ? uint256(aggCollapseHpEmpty) / seeds : 0));
        console2.log("  creatures rescued  total", uint256(aggCreaturesRescued), "avg", uint256(seeds > 0 ? uint256(aggCreaturesRescued) / seeds : 0));
        console2.log("  HP healed          total", uint256(aggHpHealed),         "avg", uint256(seeds > 0 ? uint256(aggHpHealed) / seeds : 0));
        {
            uint64 potential = aggCreaturesRescued * uint64(c.healPerCreature);
            uint64 wasted    = potential > aggHpHealed ? potential - aggHpHealed : 0;
            console2.log("  healing wasted     total", uint256(wasted), "avg", uint256(seeds > 0 ? uint256(wasted) / seeds : 0));
        }
        console2.log("  observers lost     total", uint256(aggObserversLost),    "avg", uint256(seeds > 0 ? uint256(aggObserversLost) / seeds : 0));
        console2.log("  rescuers lost      total", uint256(aggRescuersLost),     "avg", uint256(seeds > 0 ? uint256(aggRescuersLost) / seeds : 0));
        console2.log("  power-starved h    total", uint256(aggPowerStarvedHours),"avg", uint256(seeds > 0 ? uint256(aggPowerStarvedHours) / seeds : 0));

        // ── Ticket 2.2 measures ───────────────────────────────────────────────
        console2.log("");
        console2.log("=== BLIND RESCUE / COOLDOWN / CLOSE (ticket 2.2) ===");
        console2.log("  blind rescues      total", uint256(aggBlindRescues),        "avg", uint256(seeds > 0 ? uint256(aggBlindRescues) / seeds : 0));
        console2.log("    of which empty   total", uint256(aggBlindRescuesEmpty),   "avg", uint256(seeds > 0 ? uint256(aggBlindRescuesEmpty) / seeds : 0));
        console2.log("  rescuer recovery h total", uint256(aggRescuerRecoveryHours),"avg", uint256(seeds > 0 ? uint256(aggRescuerRecoveryHours) / seeds : 0));
        console2.log("  closes             total", uint256(aggCloses),              "avg", uint256(seeds > 0 ? uint256(aggCloses) / seeds : 0));
        console2.log("  close HP saved     total", uint256(aggCloseHpSaved),        "avg", uint256(seeds > 0 ? uint256(aggCloseHpSaved) / seeds : 0));
        console2.log("  creatures left     total", uint256(aggCreaturesLeftBehind), "avg", uint256(seeds > 0 ? uint256(aggCreaturesLeftBehind) / seeds : 0));

        // ── Hypothesis: are players punished for looking? ─────────────────────
        // For every collapse of a SURVEYED portal that still held creatures, the
        // overpay vs the blind midpoint is hpCollapsePerDeath*(creatures - typeMid).
        // Positive sum = knowledge cost more; negative sum = knowledge saved. A
        // strongly negative net would mean the rules still reward NOT looking.
        console2.log("");
        console2.log("=== HYPOTHESIS: knowledge cost on surveyed collapses ===");
        console2.log("  knowledge cost MORE (sum HP):", uint256(aggKnowledgeCostPos));
        console2.log("  knowledge SAVED     (sum HP):", uint256(aggKnowledgeCostNeg));
        if (aggKnowledgeCostPos >= aggKnowledgeCostNeg) {
            console2.log("  net (cost - saved) POSITIVE, knowledge cost more by:", uint256(aggKnowledgeCostPos - aggKnowledgeCostNeg));
        } else {
            console2.log("  net (saved - cost) NEGATIVE, knowledge saved more by:", uint256(aggKnowledgeCostNeg - aggKnowledgeCostPos));
        }

        // ── Ticket 2.3 §4: power-starvation breakdown ────────────────────────────
        console2.log("");
        console2.log("=== POWER-STARVATION BREAKDOWN (ticket 2.3 s4) ===");
        console2.log("  [4.1] starved surveys       total", uint256(aggStarvedSurveys),        "avg", uint256(seeds > 0 ? uint256(aggStarvedSurveys) / seeds : 0));
        console2.log("  [4.1] starved recall-obs    total", uint256(aggStarvedRecallObs),       "avg", uint256(seeds > 0 ? uint256(aggStarvedRecallObs) / seeds : 0));
        console2.log("  [4.1] starved send-rescuers total", uint256(aggStarvedSendRescuers),    "avg", uint256(seeds > 0 ? uint256(aggStarvedSendRescuers) / seeds : 0));
        console2.log("  [4.1] starved evacuations   total", uint256(aggStarvedEvacuations),     "avg", uint256(seeds > 0 ? uint256(aggStarvedEvacuations) / seeds : 0));
        console2.log("  [4.1] starved recall-resc   total", uint256(aggStarvedRecallRescuers),  "avg", uint256(seeds > 0 ? uint256(aggStarvedRecallRescuers) / seeds : 0));
        console2.log("  [4.1] starved closes        total", uint256(aggStarvedCloses),          "avg", uint256(seeds > 0 ? uint256(aggStarvedCloses) / seeds : 0));
        console2.log("  [4.2] urgent starved (h<=3) total", uint256(aggUrgentStarvedHours),     "avg", uint256(seeds > 0 ? uint256(aggUrgentStarvedHours) / seeds : 0));
        console2.log("  [4.3] urgent+lives starved  total", uint256(aggUrgentWithLivesHours),   "avg", uint256(seeds > 0 ? uint256(aggUrgentWithLivesHours) / seeds : 0));
        {
            uint64 aggStarvedTotal = aggStarvedSurveys + aggStarvedRecallObs + aggStarvedSendRescuers
                + aggStarvedEvacuations + aggStarvedRecallRescuers + aggStarvedCloses;
            console2.log("  [4.4] total starved refusals:", uint256(aggStarvedTotal));
            console2.log("  [4.4] power deficit sum:     ", uint256(aggPowerDeficitSum));
            console2.log("  [4.4] avg deficit/refusal:   ", uint256(aggStarvedTotal > 0 ? aggPowerDeficitSum / aggStarvedTotal : 0));
        }
        console2.log("  [4.5] max starved streak (hours):", uint256(maxStarvedStreakAll));

        // ── Task 4.3: Entropy request report ─────────────────────────────────
        // Sort arrays for percentile computation (reuses existing _sortN helper).
        _sortN(ea.totalActs,       seeds);
        _sortN(ea.actionsWithRoll, seeds);
        _sortN(ea.draws,           seeds);
        _sortN(ea.spawned,         seeds);
        _sortN(ea.txWithSpawn,     seeds);
        _sortN(ea.requestsA,       seeds);
        _sortN(ea.requestsB,       seeds);

        console2.log("");
        console2.log("=== ENTROPY REQUESTS (TASK 4.3) ===");
        console2.log("RandomStub.draw() mapping: Survey=3 draws/action, BlindRescue=1 draw/action, Spawn=3 draws/portal");
        console2.log("Policy A (full two-phase): one Pyth request per player act() where elapsed >= 1 (always in sim)");
        console2.log("Policy B (buy info only):  one request per survey or blind rescue only");
        console2.log("");

        // Helper: display median/mean/p90/max for a sorted array.
        // Line format: "<label>  med=X  mean=Y  p90=Z  max=W"
        console2.log("--- 1.1/1.2  Total player acts (breakdown in ACTIVE RUN AGGREGATE above) ---");
        {
            uint256 med = uint256(_medianN(ea.totalActs, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.totalActs / seeds) : 0;
            uint256 p90 = uint256(ea.totalActs[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.totalActs[seeds - 1]);
            console2.log("  totalActs   med", med, "mean", mn);
            console2.log("              p90", p90, "max", mx);
        }
        console2.log("");

        console2.log("--- 1.3  RandomStub.draw() calls per run ---");
        {
            uint256 med = uint256(_medianN(ea.draws, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.draws / seeds) : 0;
            uint256 p90 = uint256(ea.draws[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.draws[seeds - 1]);
            console2.log("  drawsTotal  med", med, "mean", mn);
            console2.log("              p90", p90, "max", mx);
        }
        console2.log("--- 1.4  Actions that consumed randomness (survey + blind rescue) ---");
        {
            uint256 med = uint256(_medianN(ea.actionsWithRoll, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.actionsWithRoll / seeds) : 0;
            uint256 p90 = uint256(ea.actionsWithRoll[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.actionsWithRoll[seeds - 1]);
            console2.log("  actWithRoll med", med, "mean", mn);
            console2.log("              p90", p90, "max", mx);
        }
        console2.log("");

        console2.log("--- 1.5  Spawned portals and spawn-producing ticks ---");
        {
            uint256 med = uint256(_medianN(ea.spawned, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.spawned / seeds) : 0;
            uint256 p90 = uint256(ea.spawned[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.spawned[seeds - 1]);
            console2.log("  spawnedPortals med", med, "mean", mn);
            console2.log("                 p90", p90, "max", mx);
        }
        {
            uint256 med = uint256(_medianN(ea.txWithSpawn, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.txWithSpawn / seeds) : 0;
            uint256 p90 = uint256(ea.txWithSpawn[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.txWithSpawn[seeds - 1]);
            console2.log("  txWithSpawn    med", med, "mean", mn);
            console2.log("                 p90", p90, "max", mx);
        }
        console2.log("  NOTE: actionsAtZeroElapsed=0 (sim advances exactly 1h per act)");
        console2.log("");

        console2.log("--- 2.1/2.2  Pyth requests per game ---");
        {
            uint256 medA = uint256(_medianN(ea.requestsA, seeds));
            uint256 mnA  = seeds > 0 ? uint256(eaAgg.totalActs / seeds) : 0;
            uint256 p90A = uint256(ea.requestsA[(seeds - 1) * 9 / 10]);
            uint256 mxA  = uint256(ea.requestsA[seeds - 1]);
            console2.log("  requestsA (all acts): med", medA, "mean", mnA);
            console2.log("                        p90", p90A, "max", mxA);
        }
        {
            uint256 medB = uint256(_medianN(ea.requestsB, seeds));
            uint256 mnB  = seeds > 0 ? uint256(eaAgg.actionsWithRoll / seeds) : 0;
            uint256 p90B = uint256(ea.requestsB[(seeds - 1) * 9 / 10]);
            uint256 mxB  = uint256(ea.requestsB[seeds - 1]);
            console2.log("  requestsB (info-buy): med", medB, "mean", mnB);
            console2.log("                        p90", p90B, "max", mxB);
        }
        {
            uint256 ra90 = uint256(ea.requestsA[(seeds - 1) * 9 / 10]);
            uint256 rb90 = uint256(ea.requestsB[(seeds - 1) * 9 / 10]);
            console2.log("  A/B ratio at p90: A", ra90, "B", rb90);
            console2.log("  A/B multiplier:", rb90 > 0 ? ra90 / rb90 : 0);
        }
        console2.log("");

        // ── 2.3 Cost table ────────────────────────────────────────────────────
        // Prices: testnet=0.12816 MON/req, mainnet=0.4 MON/req.
        // Cost column = requests × price, shown in units of 10^-5 MON.
        //   (divide by 100000 to get MON; e.g. 1281600 = 12.816 MON)
        // Testnet factor: 12816.  Mainnet factor: 40000.
        console2.log("--- 2.3  Cost table  (units of 10^-5 MON; /100000 = MON) ---");
        console2.log("  [Policy A | testnet 0.12816 MON/req]");
        {
            uint256 med = uint256(_medianN(ea.requestsA, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.totalActs / seeds) : 0;
            uint256 p90 = uint256(ea.requestsA[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.requestsA[seeds - 1]);
            console2.log("    med", med * 12816, "mean", mn * 12816);
            console2.log("    p90", p90 * 12816, "max",  mx * 12816);
        }
        console2.log("  [Policy A | mainnet 0.4 MON/req]");
        {
            uint256 med = uint256(_medianN(ea.requestsA, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.totalActs / seeds) : 0;
            uint256 p90 = uint256(ea.requestsA[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.requestsA[seeds - 1]);
            console2.log("    med", med * 40000, "mean", mn * 40000);
            console2.log("    p90", p90 * 40000, "max",  mx * 40000);
        }
        console2.log("  [Policy B | testnet 0.12816 MON/req]");
        {
            uint256 med = uint256(_medianN(ea.requestsB, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.actionsWithRoll / seeds) : 0;
            uint256 p90 = uint256(ea.requestsB[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.requestsB[seeds - 1]);
            console2.log("    med", med * 12816, "mean", mn * 12816);
            console2.log("    p90", p90 * 12816, "max",  mx * 12816);
        }
        console2.log("  [Policy B | mainnet 0.4 MON/req]");
        {
            uint256 med = uint256(_medianN(ea.requestsB, seeds));
            uint256 mn  = seeds > 0 ? uint256(eaAgg.actionsWithRoll / seeds) : 0;
            uint256 p90 = uint256(ea.requestsB[(seeds - 1) * 9 / 10]);
            uint256 mx  = uint256(ea.requestsB[seeds - 1]);
            console2.log("    med", med * 40000, "mean", mn * 40000);
            console2.log("    p90", p90 * 40000, "max",  mx * 40000);
        }
        console2.log("");

        console2.log("All", seeds, "seeds: bystander and active runs ended in death before the horizon.");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Creature-range invariants (ticket 2.3)
    // ════════════════════════════════════════════════════════════════════════════

    /// @notice Pin the midpoints of Flash and LongLived. These midpoints are
    /// load-bearing for blind-rescue value calculations (P6 uses them to decide
    /// whether a blind entry is worth it) and for the HP economy (atCollapse is
    /// the midpoint when creatures are unknown). If creaturesMin ever drops to
    /// zero the midpoint shifts and all HP math changes silently.
    function test_creaturesRange_midpoints_preserved() public pure {
        PortalTypeParams[5] memory types = DefaultConfig.portalTypeParams();
        // Flash: creaturesMin=1, creaturesMax=3 -> mid = (1+3)/2 = 2.
        uint8 flashMid = uint8((uint16(types[0].creaturesMin) + uint16(types[0].creaturesMax)) / 2);
        // LongLived: creaturesMin=1, creaturesMax=5 -> mid = (1+5)/2 = 3.
        uint8 longMid  = uint8((uint16(types[1].creaturesMin) + uint16(types[1].creaturesMax)) / 2);
        assertEq(flashMid, 2, "Flash midpoint must be 2; check HP economy after any creaturesMin change.");
        assertEq(longMid,  3, "LongLived midpoint must be 3; check HP economy after any creaturesMin change.");
        // Guard against creaturesMin hitting zero (blind evacuation of 1 saves nobody).
        assertGt(types[0].creaturesMin, 0, "Flash creaturesMin must be > 0.");
        assertGt(types[1].creaturesMin, 0, "LongLived creaturesMin must be > 0.");
    }

    // ────────────────────────────────────────────────────────────────────────────
    // Helper: Bystander Game (no actions, pure aging)
    // ────────────────────────────────────────────────────────────────────────────

    /// @notice Start a game for `player`, do NOT perform any actions, just age
    /// the world and watch it collapse.
    function _runBystanderGame(address player, Config memory c) private returns (uint32 diedAtHour) {
        vm.prank(player);
        lab.startGame();

        // Age until the game finishes. Sync is public, anyone can call it.
        // We jump forward in 24-game-hour steps to reach death quickly; each sync
        // repeats the O(portals) catch-up, never an O(hours) loop.
        Game memory game;

        for (uint256 iter = 0; iter < 200; iter++) {
            uint256 jumpSeconds = 24 * uint256(c.secPerHour);
            vm.warp(block.timestamp + jumpSeconds);

            // Pay to bring the world forward across epoch edges and commit events.
            _advance(player);

            game = lab.getGame(player);
            if (game.finished) {
                return game.diedAtHour;
            }

            // Safety: a bystander must not outlive the horizon.
            if (game.hoursElapsed >= 3000) {
                revert("Bystander ran past 3000 hours (should have died).");
            }
        }

        revert("Bystander did not finish in 200 iterations of 24h (logic error).");
    }

    // ────────────────────────────────────────────────────────────────────────────
    // Helper: Active Game (rational triage policy)
    // ────────────────────────────────────────────────────────────────────────────

    /// @notice Run an active game with a fixed rational TRIAGE policy, ONE action
    /// per game hour, for at most 3000 game hours (or until death).
    ///
    /// WHY THIS POLICY (the economy it is derived from, all from DefaultConfig):
    ///   - empty collapse                 = hpEmptyCollapse (cheap, 3)
    ///   - collapse with N beings         = hpCollapseBase + hpCollapsePerDeath*N (20 + 10N)
    ///   - CLOSE with N creatures inside  = hpCollapsePerDeath*N (10N) + costClose power,
    ///                                      vs. evacuate = GAIN healPerCreature*N HP; close
    ///                                      is strictly worse when creatures > 0. NEVER do it.
    ///   - CLOSE with crew inside         = hpCollapsePerDeath per crew, crew lost forever.
    ///                                      Recall them first. NEVER close with crew inside.
    ///   - close empty                    = 0 HP, but burns costClose power AND adds
    ///                                      closePressureBonus pressure => almost never worth it.
    ///   - an observer left inside at collapse = +1 death (hpCollapsePerDeath) and the
    ///                                      person is lost for good.
    ///   - Evacuate itself returns the rescuer (rescuerInside=false, rescuersFree+=1),
    ///     so no separate RecallRescuer is needed after an evacuation.
    ///
    /// SAFETY MARGIN (MIN_EXIT_MARGIN = 4 hours):
    ///   Sending crew into a portal that has fewer than MIN_EXIT_MARGIN hours remaining
    ///   is suicide: one hour to enter, one to exit, two hours buffer. A FULL cycle
    ///   (survey THEN rescue) needs even more, MIN_EXIT_MARGIN + 2.
    ///
    /// PRIORITY ORDER (exactly one step per game hour — ticket 2.2 Part 2):
    ///   P1. Recall an observer inside (soonest-to-collapse first).
    ///   P2. Evacuate where a rescuer is inside and creatures remain (surveyed OR
    ///       blind; a blind evacuation leaves one behind).
    ///   P3. Recall a rescuer stuck in a portal with no creatures left.
    ///   P4. Full rescue: send a rescuer into a SURVEYED portal with creatures,
    ///       hoursToCollapse >= MIN_EXIT_MARGIN, risk not Critical. Most creatures
    ///       first; ties to the soonest collapse.
    ///   P5. Survey: send an observer into an UNSURVEYED portal with time for the
    ///       full cycle (hoursToCollapse >= MIN_EXIT_MARGIN + 2). Highest expected
    ///       creatures (midpoint); midpoint 0 skipped.
    ///   P6. Blind rescue: send a rescuer into an UNSURVEYED portal with time for a
    ///       blind entry (>= MIN_EXIT_MARGIN) and at least one of: no time for the full
    ///       survey cycle, no free observer, or rich portal (mid >= 3). Midpoint >= 2
    ///       required; never re-enters one emptied to <= 1. Cautious risk gate.
    ///   P7. Close whenever the HONEST benefit is strictly positive (never with crew
    ///       inside); take the portal with the greatest benefit. Benefit =
    ///       hpCollapseBase + hpCollapsePerDeath*(deathsAtCollapse - deathsAtClose).
    ///   P8. Otherwise do nothing and let power regenerate.
    ///
    /// Before every act, canAct MUST be Refusal.None; no act may revert. If a
    /// selected action is refused for anything OTHER than lack of power, that is a
    /// policy bug and the test fails loudly. A "power-starved" hour is one where the
    /// player did NOTHING at all only because every action it wanted was unaffordable.
    ///
    /// Death during catch-up is handled by `sync` at the top of each iteration: the
    /// finished game is read and the loop returns before any act runs (an act on a
    /// dead game would revert; we never reach it).
    function _runActiveGame(address player, Config memory c)
        private
        returns (uint32 diedAtHour, Stats memory stats)
    {
        vm.prank(player);
        lab.startGame();

        // Start recording all events emitted during this run.
        vm.recordLogs();

        PortalTypeParams[5] memory types = DefaultConfig.portalTypeParams();

        // Snapshot of the world as it stood at the END of the previous game hour
        // (after that hour's action). Comparing it against the world after the next
        // catch-up reveals which portals collapsed during that catch-up, so the
        // "punished for looking" hypothesis can be tallied. Fixed-size scalar arrays
        // updated IN PLACE — never reallocated — so they add no per-hour memory
        // growth to this long loop.
        uint16[MAX_OPEN_PORTALS] memory prevId;
        bool[MAX_OPEN_PORTALS] memory prevSurveyed;
        uint8[MAX_OPEN_PORTALS] memory prevCreatures;
        uint8[MAX_OPEN_PORTALS] memory prevType;

        uint32 streakCurrent = 0; // consecutive power-starved hours (§4.5)
        uint32 prevSpawnCount = 0; // Task 4.3: tracks spawnCount before each sync

        for (uint256 iter = 0; iter < 3000; iter++) {
            // Age forward exactly ONE game hour.
            vm.warp(block.timestamp + uint256(c.secPerHour));

            // Catch the world up first (pay across epoch edges; records
            // collapses/spawns and any death).
            _advance(player);

            Game memory game = lab.getGame(player);

            // Task 4.3: count ticks that produced at least one new portal.
            if (game.spawnCount > prevSpawnCount) stats.txWithSpawn++;
            prevSpawnCount = game.spawnCount;

            if (game.finished) {
                diedAtHour = game.diedAtHour;
                // Final window may have collapsed surveyed portals; tally them too.
                _tallyKnowledgeCost(prevId, prevSurveyed, prevCreatures, prevType, lab.getPortals(player), types, c, stats);
                break;
            }
            if (game.hoursElapsed >= 3000) {
                revert("Active player ran past 3000 hours (should have died).");
            }

            Portal[MAX_OPEN_PORTALS] memory portals = lab.getPortals(player);

            // Collapses that happened during THIS catch-up: portals present in the
            // previous snapshot whose slot no longer holds the same portal.
            _tallyKnowledgeCost(prevId, prevSurveyed, prevCreatures, prevType, portals, types, c, stats);

            uint32 prevStarvedHours = stats.powerStarvedHours;
            _decide(player, game, portals, c, stats);
            if (stats.powerStarvedHours > prevStarvedHours) {
                streakCurrent++;
                if (streakCurrent > stats.maxStarvedStreak) stats.maxStarvedStreak = streakCurrent;
            } else {
                streakCurrent = 0;
            }

            // Re-snapshot AFTER the action so a close/evacuate/survey done this hour
            // is not later mistaken for a collapse.
            Portal[MAX_OPEN_PORTALS] memory postDecide = lab.getPortals(player);
            for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
                prevId[i] = postDecide[i].id;
                prevSurveyed[i] = postDecide[i].surveyed;
                prevCreatures[i] = postDecide[i].creatures;
                prevType[i] = uint8(postDecide[i].portalType);
            }
        }

        // Verify the run genuinely ended in death within the horizon.
        Game memory fg = lab.getGame(player);
        if (!fg.finished) {
            revert("Active game did not finish within 3000 game hours (logic error).");
        }
        diedAtHour = fg.diedAtHour;

        // Collapses are not double-counted: every spawned portal ends as closed,
        // collapsed, or still-open-at-death. So collapses = spawned - closed - open.
        stats.collapses = uint32(fg.spawnCount) - stats.closes - uint32(fg.openPortals);
        // Task 4.3: record total portals spawned this run.
        stats.spawnedPortals = fg.spawnCount;

        // Parse the HP ledger from the event log.
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        _parseLogStats(logs, player, stats);

        return (diedAtHour, stats);
    }

    /// @dev Run the triage policy for a single game hour: pick the highest-priority
    /// action with a structural candidate and, if affordable, perform it. Falls
    /// through to cheaper lower-priority actions when a costlier one is unaffordable;
    /// a fully idle hour caused only by lack of power increments powerStarvedHours.
    function _decide(
        address player,
        Game memory game,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        Stats memory stats
    ) private {
        bool acted = false;
        bool blockedByPower = false;
        uint8 slot;
        bool ok;

        // P1. Recall a surveyed observer (soonest-to-collapse first).
        (slot, ok) = _pickRecallObserver(portals);
        if (ok) {
            Refusal r = lab.canAct(player, slot, Action.RecallObserver);
            if (r == Refusal.None) {
                vm.prank(player);
                lab.act(slot, Action.RecallObserver);
                stats.recallObservers += 1;
                acted = true;
            } else if (r == Refusal.NotEnoughPower) {
                blockedByPower = true;
                stats.starvedRecallObs++;
                _tallyStarve(portals[slot], c.costRecallObserver, game, stats);
            } else {
                assertTrue(false, "P1 RecallObserver selected but refused for a non-power reason.");
            }
        }

        // P2. Evacuate (surveyed or blind — a blind evacuation leaves one behind).
        if (!acted) {
            (slot, ok) = _pickEvacuate(portals);
            if (ok) {
                Refusal r = lab.canAct(player, slot, Action.Evacuate);
                if (r == Refusal.None) {
                    uint8 n = portals[slot].creatures;
                    uint16 hpBefore = game.hp;
                    vm.prank(player);
                    lab.act(slot, Action.Evacuate);
                    uint16 hpAfter = lab.getGame(player).hp;
                    uint8 leftBehind = lab.getPortals(player)[slot].creatures;
                    stats.evacuations += 1;
                    stats.creaturesRescued += (n - leftBehind); // saved, not attempted
                    stats.creaturesLeftBehind += leftBehind; // 0 when surveyed
                    stats.hpHealed += uint32(hpAfter - hpBefore);
                    acted = true;
                } else if (r == Refusal.NotEnoughPower) {
                    blockedByPower = true;
                    stats.starvedEvacuations++;
                    _tallyStarve(portals[slot], c.costEvacuate, game, stats);
                } else {
                    assertTrue(false, "P2 Evacuate selected but refused for a non-power reason.");
                }
            }
        }

        // P3. Recall a rescuer stuck empty-handed (soonest-to-collapse first).
        if (!acted) {
            (slot, ok) = _pickRecallRescuer(portals);
            if (ok) {
                Refusal r = lab.canAct(player, slot, Action.RecallRescuer);
                if (r == Refusal.None) {
                    vm.prank(player);
                    lab.act(slot, Action.RecallRescuer);
                    stats.recallRescuers += 1;
                    acted = true;
                } else if (r == Refusal.NotEnoughPower) {
                    blockedByPower = true;
                    stats.starvedRecallRescuers++;
                    _tallyStarve(portals[slot], c.costRecallRescuer, game, stats);
                } else {
                    assertTrue(false, "P3 RecallRescuer selected but refused for a non-power reason.");
                }
            }
        }

        // P4. Full rescue: send a rescuer into a SURVEYED portal with creatures.
        if (!acted) {
            (slot, ok) = _pickSendRescuer(game, portals);
            if (ok) {
                Refusal r = lab.canAct(player, slot, Action.SendRescuer);
                if (r == Refusal.None) {
                    vm.prank(player);
                    lab.act(slot, Action.SendRescuer);
                    stats.sendRescuers += 1;
                    acted = true;
                } else if (r == Refusal.NotEnoughPower) {
                    blockedByPower = true;
                    stats.starvedSendRescuers++;
                    _tallyStarve(portals[slot], c.costSendRescuer, game, stats);
                } else {
                    assertTrue(false, "P4 SendRescuer selected but refused for a non-power reason.");
                }
            }
        }

        // P5. Survey — only with time for the full cycle (>= MIN_EXIT_MARGIN + 2).
        if (!acted) {
            (slot, ok) = _pickSurvey(game, portals);
            if (ok) {
                Refusal r = lab.canAct(player, slot, Action.SendObserver);
                if (r == Refusal.None) {
                    vm.prank(player);
                    lab.act(slot, Action.SendObserver); // commit (two-phase survey)
                    // Reveal immediately: same timestamp, so the world cannot have
                    // changed and the survey always applies (SPEC §6.3).
                    source.reveal(lab.getPending(player).requestId);
                    stats.surveys += 1;
                    acted = true;
                } else if (r == Refusal.NotEnoughPower) {
                    blockedByPower = true;
                    stats.starvedSurveys++;
                    _tallyStarve(portals[slot], c.costSendObserver, game, stats);
                } else {
                    assertTrue(false, "P5 SendObserver selected but refused for a non-power reason.");
                }
            }
        }

        // P6. Blind rescue: send a rescuer into an UNSURVEYED portal when there is
        //     no longer time to survey first, but still time for a blind entry.
        if (!acted) {
            (slot, ok) = _pickBlindRescue(game, portals);
            if (ok) {
                Refusal r = lab.canAct(player, slot, Action.SendRescuer);
                if (r == Refusal.None) {
                    vm.prank(player);
                    lab.act(slot, Action.SendRescuer); // commit (Ticket 4.6: two-phase if creaturesKnown==false)
                    // If a two-phase blind rescue was committed, reveal immediately.
                    // No time passes between commit and reveal, so the portal cannot
                    // have collapsed and the reveal always applies (never cancels).
                    if (lab.getPending(player).active) {
                        source.reveal(lab.getPending(player).requestId);
                    }
                    stats.sendRescuers += 1;
                    stats.blindRescues += 1;
                    // Did the bet pay off? If the rescuer never entered, the portal
                    // was empty and they are now recovering.
                    if (!lab.getPortals(player)[slot].rescuerInside) {
                        stats.blindRescuesEmpty += 1;
                        stats.rescuerRecoveryHours += uint32(c.rescuerCooldownHours);
                    }
                    acted = true;
                } else if (r == Refusal.NotEnoughPower) {
                    blockedByPower = true;
                    stats.starvedSendRescuers++;
                    _tallyStarve(portals[slot], c.costSendRescuer, game, stats);
                } else {
                    assertTrue(false, "P6 blind SendRescuer selected but refused for a non-power reason.");
                }
            }
        }

        // P7. Close — whenever the honest benefit is positive (never with crew inside).
        if (!acted) {
            (slot, ok) = _pickClose(game, portals, c);
            if (ok) {
                Refusal r = lab.canAct(player, slot, Action.Close);
                if (r == Refusal.None) {
                    int256 benefit = _closeBenefit(portals[slot], c);
                    vm.prank(player);
                    lab.act(slot, Action.Close);
                    stats.closes += 1;
                    if (benefit > 0) stats.closeHpSaved += uint32(uint256(benefit));
                    acted = true;
                } else if (r == Refusal.NotEnoughPower) {
                    blockedByPower = true;
                    stats.starvedCloses++;
                    _tallyStarve(portals[slot], c.costClose, game, stats);
                } else {
                    assertTrue(false, "P7 Close selected but refused for a non-power reason.");
                }
            }
        }

        // P8. Nothing to do. Count the hour as power-starved only if the sole
        //     reason for inaction was affordability.
        if (!acted && blockedByPower) {
            stats.powerStarvedHours += 1;
        }
    }

    // ────────────────────────────────────────────────────────────────────────────
    // Policy Helpers — each returns (slot, found). Candidates are chosen on
    // STRUCTURE only (not power), so the sole refusal canAct can add is
    // NotEnoughPower; any other refusal indicates a policy bug.
    // ────────────────────────────────────────────────────────────────────────────

    /// @notice P1: recall an observer as soon as it enters a portal.
    /// An observer completes its job in a single action: on entry, it immediately
    /// surveys and narrows the creatures range. Holding an observer inside after
    /// this serves no purpose — either the portal has been narrowed (surveyed || just-attempted),
    /// or it collapses (hpCollapsePerDeath + the observer is lost for good).
    /// Deaf portals (surveyPrecise=false) are not narrowed to exact range in one visit;
    /// a second SendObserver is needed. That is a NEW action, not a recall —
    /// no observer currently sits idle in a Deaf portal waiting to be narrowed further.
    ///
    /// Returns the one whose portal collapses SOONEST to minimise exposure.
    function _pickRecallObserver(Portal[MAX_OPEN_PORTALS] memory portals) private pure returns (uint8, bool) {
        bool found = false;
        uint8 best = 0;
        uint16 bestHours = type(uint16).max;

        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            Portal memory p = portals[i];
            if (p.status == PortalStatus.Empty) continue;
            if (!p.observerInside) continue;
            if (p.surveyPending) continue;

            if (!found || p.hoursToCollapse < bestHours) {
                found = true;
                best = i;
                bestHours = p.hoursToCollapse;
            }
        }
        return (best, found);
    }

    /// @notice P2: a rescuer inside a portal that still has creatures to pull out.
    function _pickEvacuate(Portal[MAX_OPEN_PORTALS] memory portals) private pure returns (uint8, bool) {
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            Portal memory p = portals[i];
            if (p.status == PortalStatus.Empty) continue;
            if (!p.rescuerInside) continue;
            if (p.creatures == 0) continue;
            return (i, true);
        }
        return (0, false);
    }

    /// @notice P3: a rescuer stuck inside a portal with no creatures left.
    /// Returns the one whose portal collapses SOONEST to minimise exposure.
    function _pickRecallRescuer(Portal[MAX_OPEN_PORTALS] memory portals) private pure returns (uint8, bool) {
        bool found = false;
        uint8 best = 0;
        uint16 bestHours = type(uint16).max;

        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            Portal memory p = portals[i];
            if (p.status == PortalStatus.Empty) continue;
            if (!p.rescuerInside) continue;
            if (p.creatures != 0) continue;

            if (!found || p.hoursToCollapse < bestHours) {
                found = true;
                best = i;
                bestHours = p.hoursToCollapse;
            }
        }
        return (best, found);
    }

    /// @notice P4: the surveyed, non-Critical portal with hoursToCollapse >= MIN_EXIT_MARGIN
    /// and the most creatures (ties break to the one closest to collapse). Requires a free rescuer.
    function _pickSendRescuer(Game memory g, Portal[MAX_OPEN_PORTALS] memory portals)
        private
        pure
        returns (uint8, bool)
    {
        if (g.rescuersFree == 0) return (0, false);

        bool found = false;
        uint8 best = 0;
        uint8 bestCreatures = 0;
        uint16 bestHours = type(uint16).max;

        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            Portal memory p = portals[i];
            if (p.status == PortalStatus.Empty) continue;
            if (!p.surveyed) continue;
            if (p.creatures == 0) continue;
            if (p.rescuerInside) continue;
            // Safety margin: rescuer cannot safely exit a portal with too few hours left.
            if (p.hoursToCollapse < MIN_EXIT_MARGIN) continue;
            // Same risk gate as canAct: rescue is forbidden once Critical.
            (, RiskLevel lvl) = RiskLib.portalRisk(p);
            if (lvl == RiskLevel.Critical) continue;

            if (!found || p.creatures > bestCreatures
                || (p.creatures == bestCreatures && p.hoursToCollapse < bestHours)) {
                found = true;
                best = i;
                bestCreatures = p.creatures;
                bestHours = p.hoursToCollapse;
            }
        }
        return (best, found);
    }

    /// @notice P5: the unsurveyed portal with enough time for the FULL cycle
    /// (survey, then a rescue and exit) — hoursToCollapse >= MIN_EXIT_MARGIN + 2 —
    /// and the highest expected creatures (range midpoint), ties break to the one
    /// closest to collapse. Skips portals whose midpoint is 0 and any already
    /// holding an observer. Requires a free observer. Portals with too little time
    /// for the full cycle are left to P6 (blind rescue).
    function _pickSurvey(Game memory g, Portal[MAX_OPEN_PORTALS] memory portals)
        private
        pure
        returns (uint8, bool)
    {
        if (g.observersFree == 0) return (0, false);

        bool found = false;
        uint8 best = 0;
        uint8 bestMid = 0;
        uint16 bestHours = type(uint16).max;

        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            Portal memory p = portals[i];
            if (p.status == PortalStatus.Empty) continue;
            if (p.surveyed) continue;
            if (p.surveyPending) continue;
            if (p.observerInside) continue;
            // Full cycle needs time to survey AND still run a rescue afterwards.
            if (p.hoursToCollapse < MIN_EXIT_MARGIN + 2) continue;

            uint8 mid = uint8((uint16(p.creaturesLo) + uint16(p.creaturesHi)) / 2);
            if (mid == 0) continue;

            if (!found || mid > bestMid || (mid == bestMid && p.hoursToCollapse < bestHours)) {
                found = true;
                best = i;
                bestMid = mid;
                bestHours = p.hoursToCollapse;
            }
        }
        return (best, found);
    }

    /// @notice P6: blind rescue. Send a rescuer into an UNSURVEYED portal that has
    /// time for a blind entry (>= MIN_EXIT_MARGIN). Qualifies when at least one of:
    ///   (a) no time left for the full survey+rescue cycle (< MIN_EXIT_MARGIN + 2),
    ///   (b) no free observer to survey with (g.observersFree == 0),
    ///   (c) rich portal (mid >= 3) — immediate blind entry beats waiting.
    /// Only where the midpoint is >= 2 — a blind evacuation leaves one behind, so
    /// a midpoint of 0 or 1 saves nobody while still risking the rescuer. Never
    /// re-enters a portal a prior blind visit already emptied to <= 1. Cautious risk
    /// gate so canAct can only ever add NotEnoughPower. Ranks by expected count,
    /// ties to the one closest to collapse.
    function _pickBlindRescue(Game memory g, Portal[MAX_OPEN_PORTALS] memory portals)
        private
        pure
        returns (uint8, bool)
    {
        if (g.rescuersFree == 0) return (0, false);

        bool found = false;
        uint8 best = 0;
        uint8 bestMid = 0;
        uint16 bestHours = type(uint16).max;

        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            Portal memory p = portals[i];
            if (p.status == PortalStatus.Empty) continue;
            if (p.surveyed) continue; // blind rescue is for UNSURVEYED portals
            if (p.rescuerInside) continue;
            // Safety margin for a blind entry (enter + exit): >= MIN_EXIT_MARGIN.
            if (p.hoursToCollapse < MIN_EXIT_MARGIN) continue;
            // A prior blind visit that emptied it to <= 1 leaves nothing to save.
            if (p.creaturesKnown && p.creatures <= 1) continue;

            uint8 mid = uint8((uint16(p.creaturesLo) + uint16(p.creaturesHi)) / 2);
            if (mid < 2) continue;

            // Qualify only when survey is not possible or the portal is rich enough.
            bool qualifies = p.hoursToCollapse < MIN_EXIT_MARGIN + 2
                || g.observersFree == 0
                || mid >= 3;
            if (!qualifies) continue;

            // Same cautious gate as canAct for an unsurveyed SendRescuer.
            (, RiskLevel lvl) = RiskLib.cautiousPortalRisk(p);
            if (lvl == RiskLevel.Critical) continue;

            if (!found || mid > bestMid || (mid == bestMid && p.hoursToCollapse < bestHours)) {
                found = true;
                best = i;
                bestMid = mid;
                bestHours = p.hoursToCollapse;
            }
        }
        return (best, found);
    }

    /// @notice Honest HP benefit of closing `p` now versus letting it collapse
    /// (SPEC §4.4, ticket 2.2). Deaths from own crew are excluded by the caller and
    /// would cancel between the two terms anyway.
    ///   atCollapse = known ? creatures : midpoint (what a collapse charges)
    ///   atClose    = known ? creatures : creaturesHi (what a close charges)
    ///   benefit    = hpCollapseBase + hpCollapsePerDeath * (atCollapse - atClose)
    /// A close skips the collapse base but pays the worst-case count when blind, so
    /// a wide unknown range can make closing a net loss (benefit <= 0).
    function _closeBenefit(Portal memory p, Config memory c) private pure returns (int256) {
        uint256 mid = (uint256(p.creaturesLo) + uint256(p.creaturesHi)) / 2;
        uint256 atCollapse = p.creaturesKnown ? uint256(p.creatures) : mid;
        uint256 atClose = p.creaturesKnown ? uint256(p.creatures) : uint256(p.creaturesHi);
        return int256(uint256(c.hpCollapseBase))
            + int256(uint256(c.hpCollapsePerDeath)) * (int256(atCollapse) - int256(atClose));
    }

    /// @notice P7: the closable portal with the greatest honest close-benefit, and
    /// only if that benefit is strictly positive. NEVER a portal with an observer or
    /// rescuer inside — losing one's own people is strictly worse than doing nothing.
    function _pickClose(Game memory, Portal[MAX_OPEN_PORTALS] memory portals, Config memory c)
        private
        pure
        returns (uint8, bool)
    {
        bool found = false;
        uint8 best = 0;
        int256 bestBenefit = 0;

        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            Portal memory p = portals[i];
            if (p.status == PortalStatus.Empty) continue;

            // HARD PROHIBITION: never close with a living crew member inside. Recall
            // them first; closing kills them permanently and wastes the crew slot.
            if (p.observerInside || p.rescuerInside) continue;

            int256 benefit = _closeBenefit(p, c);
            if (benefit <= 0) continue;

            // Must be allowed by the rules (same gate as canAct's Close), else the
            // action would be refused for NotUnstableEnough.
            bool closable =
                p.hoursToCollapse <= c.closeHoursAtMost || (p.surveyed && p.stability < c.closeStabilityBelow);
            if (!closable) continue;

            if (!found || benefit > bestBenefit) {
                found = true;
                best = i;
                bestBenefit = benefit;
            }
        }
        return (best, found);
    }

    /// @dev Record a single power-starvation event. Increments urgency counters and
    /// accumulates the power deficit. Called from _decide for every NotEnoughPower
    /// refusal that had a structural candidate (ticket 2.3 §4.2–§4.4).
    function _tallyStarve(
        Portal memory target,
        uint16 cost,
        Game memory game,
        Stats memory stats
    ) private pure {
        if (target.hoursToCollapse <= 3) {
            stats.urgentStarvedHours++;
            if (target.creatures > 0 || target.creaturesLo > 0) {
                stats.urgentWithLivesHours++;
            }
        }
        if (cost > game.power) {
            stats.powerDeficitSum += uint32(cost - game.power);
        }
    }

    /// @dev Detect portals that collapsed between the previous snapshot and `cur`
    /// and, for those that were SURVEYED and still held creatures, tally how much
    /// the exact count cost the player against the type's blind midpoint (ticket
    /// 2.2 hypothesis). A slot whose id changed or emptied since the snapshot, whose
    /// prior state was surveyed with creatures, is such a collapse — the player took
    /// no action on it between the snapshot (taken after the last action) and the
    /// catch-up, so its disappearance is a collapse, not a close.
    function _tallyKnowledgeCost(
        uint16[MAX_OPEN_PORTALS] memory prevId,
        bool[MAX_OPEN_PORTALS] memory prevSurveyed,
        uint8[MAX_OPEN_PORTALS] memory prevCreatures,
        uint8[MAX_OPEN_PORTALS] memory prevType,
        Portal[MAX_OPEN_PORTALS] memory cur,
        PortalTypeParams[5] memory types,
        Config memory c,
        Stats memory stats
    ) private pure {
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (prevId[i] == 0) continue; // slot was empty last time
            if (!prevSurveyed[i]) continue; // only surveyed collapses count
            if (prevCreatures[i] == 0) continue; // must still hold creatures
            if (cur[i].id == prevId[i]) continue; // still the same portal: survived

            // Collapsed. Compare the exact count against the type's blind midpoint.
            PortalTypeParams memory tp = types[prevType[i]];
            uint256 typeMid = (uint256(tp.creaturesMin) + uint256(tp.creaturesMax)) / 2;
            uint256 creatures = uint256(prevCreatures[i]);
            if (creatures > typeMid) {
                stats.knowledgeCostPos += uint32(uint256(c.hpCollapsePerDeath) * (creatures - typeMid));
            } else if (creatures < typeMid) {
                stats.knowledgeCostNeg += uint32(uint256(c.hpCollapsePerDeath) * (typeMid - creatures));
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────────
    // HP Ledger: parse event logs recorded during _runActiveGame.
    // ────────────────────────────────────────────────────────────────────────────

    /// @dev Walk the recorded logs and tally HP movements for `player` into `stats`.
    ///
    /// Events parsed:
    ///   PortalCollapsed(address indexed player, uint8 indexed slot,
    ///                   uint8 deaths, uint16 hpLost, uint32 atHour)
    ///   PortalClosed   (address indexed player, uint8 indexed slot,
    ///                   uint8 deaths, uint16 hpLost, uint32 atHour)
    ///   CreaturesRescued(address indexed player, uint8 indexed slot,
    ///                    uint8 count,  uint16 hpGained, uint32 atHour)
    ///
    /// Non-indexed data is ABI-encoded at 32 bytes per field (standard encoding),
    /// so each log.data is 3 × 32 = 96 bytes.
    function _parseLogStats(VmSafe.Log[] memory logs, address player, Stats memory stats) private pure {
        bytes32 sigCollapsed = keccak256("PortalCollapsed(address,uint8,uint8,uint16,uint32)");
        bytes32 sigClosed    = keccak256("PortalClosed(address,uint8,uint8,uint16,uint32)");
        bytes32 sigRescued   = keccak256("CreaturesRescued(address,uint8,uint8,uint16,uint32)");
        bytes32 playerTopic  = bytes32(uint256(uint160(player)));

        for (uint256 i = 0; i < logs.length; i++) {
            VmSafe.Log memory lg = logs[i];
            // All three events have 3 topics: [sig, player, slot].
            if (lg.topics.length < 2) continue;
            if (lg.topics[1] != playerTopic) continue;

            bytes32 sig = lg.topics[0];

            if (sig == sigCollapsed) {
                (uint8 deaths, uint16 hpLost,) = abi.decode(lg.data, (uint8, uint16, uint32));
                if (deaths > 0) {
                    stats.collapseHpWithDeaths += uint32(hpLost);
                    stats.collapseCountWithDeaths += 1;
                } else {
                    stats.collapseHpEmpty += uint32(hpLost);
                    stats.collapseCountEmpty += 1;
                }
            } else if (sig == sigClosed) {
                (, uint16 hpLost,) = abi.decode(lg.data, (uint8, uint16, uint32));
                stats.closeHpFromLogs += uint32(hpLost);
                stats.closedFromLogs += 1;
            } else if (sig == sigRescued) {
                (uint8 count, uint16 hpGained,) = abi.decode(lg.data, (uint8, uint16, uint32));
                stats.rescuedFromLogs += uint32(count);
                stats.hpGainedFromLogs += uint32(hpGained);
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────────
    // Part B distribution helpers
    // ────────────────────────────────────────────────────────────────────────────

    /// @dev Insertion sort (ascending) over the first `n` elements of a 128-slot array.
    /// O(n²) is acceptable for n ≤ 128.
    function _sortN(uint32[128] memory arr, uint256 n) private pure {
        for (uint256 i = 1; i < n; i++) {
            uint32 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }

    /// @dev Median of the first `n` elements of a sorted array.
    /// Even n: average of the two middle elements; odd n: the middle element.
    function _medianN(uint32[128] memory sorted, uint256 n) private pure returns (uint32) {
        if (n == 0) return 0;
        return uint32((uint256(sorted[(n - 1) / 2]) + uint256(sorted[n / 2])) / 2);
    }

    /// @dev Map a game-hour count to histogram bucket index.
    ///      Buckets: 0=0-50, 1=50-100, 2=100-150, 3=150-200, 4=200-300, 5=300-500, 6=500+
    function _histBucket(uint32 h) private pure returns (uint8) {
        if (h <  50) return 0;
        if (h < 100) return 1;
        if (h < 150) return 2;
        if (h < 200) return 3;
        if (h < 300) return 4;
        if (h < 500) return 5;
        return 6;
    }
}
