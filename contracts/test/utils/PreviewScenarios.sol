// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {PortalLabHarness} from "./PortalLabHarness.sol";
import {
    Game,
    Portal,
    Config,
    Action,
    Refusal,
    PortalType,
    PortalStatus,
    MAX_OPEN_PORTALS
} from "../../src/PortalLabTypes.sol";

/// @dev Number of states `PreviewScenarios.build` can produce (`0 … COUNT-1`).
/// A file-level constant so both consumers can size their loops without first
/// having a deployed driver to ask.
uint256 constant PREVIEW_STATE_COUNT = 12;

/// @title PreviewScenarios — reachable player states, produced by the contract itself.
/// @notice Every state this driver hands back was WORKED OUT BY `PortalLab`, not
/// written into storage field by field: each scenario starts a game with
/// `startGame` and moves it with `act`, `sync`, a delivered word, `settle` and
/// `vm.warp`, exactly as a player would. `PortalLabHarness.setGame` / `setPortal`
/// / `setCoverage` are deliberately NOT used — a hand-built `Game` can hold a
/// combination the contract never produces, and a corpus of such states proves
/// nothing about `preview`.
///
/// @dev ONE driver, TWO consumers: `script/GenPreviewVectors.s.sol` records the
/// states as golden vectors, and `test/PreviewMatchesSync.t.sol` checks `preview`
/// against an unpaid `sync` on the very same states. They must be looking at the
/// same worlds, so the driving lives here instead of being written twice.
///
/// WHY A CONTRACT AND NOT A LIBRARY. A paid `sync` needs attached value, so the
/// caller needs a balance of its own — and a script contract may not be the
/// subject of `vm.deal` (Foundry refuses `address(this)` inside a script, since a
/// script's address is ephemeral). An ordinary contract may, so the driver is one:
/// it owns the harness, holds the wei, and pays for the crossings itself.
///
/// DETERMINISM. `DeterministicSource` derives its word from `(player, nonce)` with
/// a nonce that advances on every request, so the states depend on the ORDER and
/// NUMBER of requests made before them. Both consumers therefore deploy a fresh
/// driver and call `build` for `i = 0 … COUNT-1` in order, requesting nothing of
/// their own in between; that reproduces the same states on both sides. A consumer
/// that skipped a scenario, or asked for one twice, would get different worlds.
///
/// SEARCHING, NOT FABRICATING. Some required states depend on a draw — a blind
/// rescuer finding the portal empty, a portal of a type whose creature range
/// cannot be zero. Those scenarios RETRY on a fresh player until the draw falls
/// the right way, and revert `ScenarioUnreachable` if it never does, rather than
/// writing the state by hand.
contract PreviewScenarios {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The harness every scenario is played on. Created here so the
    /// request stream that feeds `DeterministicSource` starts empty.
    PortalLabHarness public immutable lab;

    /// @dev Every scenario starts its game at this timestamp, in absolute terms, so
    /// no scenario depends on the clock a previous one left behind.
    uint40 internal constant BASE = 1_000_000;

    /// @dev Game hours of absence that accrue enough spawn pressure for exactly
    /// one portal (`basePressurePerHour` is about a tenth of `spawnCostUnits`).
    uint32 private constant HOURS_ONE_PORTAL = 10;
    /// @dev Game hours of absence that leave the starting hand — three portals
    /// born at hour 0 — open and untouched: no portal lives fewer than five hours
    /// and the next one matures only at hour 10. Short of the first pinned epoch
    /// edge, so the resulting state can still be projected FORWARD. (It was 34
    /// while a per-call spawn cap existed; with births at maturity a 34-hour
    /// absence lets the hand collapse and usually kills a 50-hp run.)
    uint32 private constant HOURS_FULL_HOUSE = 4;
    /// @dev Game hours of absence long enough for the deterministic long-absence
    /// overflow (SPEC §5.5) to fill the lab and end the run with no word at all.
    uint32 private constant HOURS_ABANDONED = 200;
    /// @dev Tries a draw-dependent scenario makes before giving up. (Raised 24 -> 96
    /// with epochHours 36: the blind-empty draw of state 7 needs a Resonant/Energetic
    /// newborn with a zero creature count, which the new epoch indices made rarer.)
    uint256 private constant ATTEMPTS = 96;

    /// @notice A required state could not be produced by real calls within
    /// `ATTEMPTS` tries. Raised instead of writing the state by hand.
    error ScenarioUnreachable(uint256 index);

    constructor() {
        lab = new PortalLabHarness();
    }

    /// @dev The change a paid `sync` hands back.
    receive() external payable {}

    /// @notice Human name of state `i`, used as the vector label.
    function label(uint256 i) external pure returns (string memory) {
        if (i == 0) return "a freshly started game, no time has passed";
        if (i == 1) return "four open portals: the starting hand plus one born after ten hours, one epoch pinned";
        if (i == 2) return "the starting hand: three open portals";
        if (i == 3) return "seventeen hours lived one hour at a time";
        if (i == 4) return "a survey committed, its word still in flight";
        if (i == 5) return "a surveyed portal with the observer still inside";
        if (i == 6) return "an observer and a rescuer inside the same portal";
        if (i == 7) return "a rescuer recovering after a blind entry into an empty portal";
        if (i == 8) return "a paid sync awaiting its word, nothing pinned yet";
        if (i == 9) return "a run the long-absence overflow killed";
        if (i == 10) return "a dead run, settled";
        if (i == 11) return "a seeded state: exactly one open portal, one epoch pinned";
        revert ScenarioUnreachable(i);
    }

    /// @notice Drive `lab` until it holds state `i`, and return whose state it is.
    /// @dev Leaves the chain exactly at that state; the clock stays wherever the
    /// scenario left it. A caller that moves the clock to take a projection is
    /// expected to put it back, or to let the next scenario's absolute `vm.warp`
    /// do it instead.
    function build(uint256 i) external returns (address player) {
        // Paid syncs attach one wei (the test source's fee is 0) and the change
        // comes back here, which `receive` accepts.
        vm.deal(address(this), 1 ether);

        if (i == 0) {
            player = _addr(i, 0);
            _start(player);
        } else if (i == 1) {
            player = _addr(i, 0);
            _startAndLive(player, HOURS_ONE_PORTAL);
        } else if (i == 2) {
            player = _addr(i, 0);
            _startAndLive(player, HOURS_FULL_HOUSE);
        } else if (i == 3) {
            player = _addr(i, 0);
            _startAndLiveHourByHour(player, 17);
        } else if (i == 4) {
            player = _commitSurvey(i);
        } else if (i == 5) {
            player = _commitSurvey(i);
            lab.reveal(player);
        } else if (i == 6) {
            player = _observerAndRescuer(i);
        } else if (i == 7) {
            player = _rescuerRecovering(i);
        } else if (i == 8) {
            player = _addr(i, 0);
            _start(player);
            _warpTo(HOURS_FULL_HOUSE);
            // A paid sync across the still-unpinned edge defers and waits: the
            // world stays where it was and a deferral hangs over the player.
            lab.sync{value: 1}(player);
        } else if (i == 9) {
            player = _addr(i, 0);
            _startAndDie(player);
        } else if (i == 10) {
            player = _addr(i, 0);
            _startAndDie(player);
            lab.settle(player);
        } else if (i == 11) {
            player = _addr(i, 0);
            _oneOpenPortalSeeded(player);
        } else {
            revert ScenarioUnreachable(i);
        }
    }

    /// @notice The moments worth projecting state `g` (coverage `covered`) to.
    /// @dev Five candidates — the stored mark itself, one hour on, the pinned edge,
    /// the first moment past it, and far beyond — deduplicated, because on a state
    /// sitting exactly at its edge several of them coincide. `n` says how many of
    /// `ts` / `names` are filled.
    function moments(Game memory g, uint32 covered, Config memory c)
        public
        pure
        returns (uint40[5] memory ts, string[5] memory names, uint256 n)
    {
        uint256 sph = c.secPerHour;
        uint256 hStored = g.hoursElapsed;
        // Last game hour the world may be aged into: the end of the last pinned
        // epoch, never behind where the world already stands. With nothing pinned
        // (`covered == 0`) the edge IS the current hour — the world cannot move.
        uint256 edge = covered == 0 ? hStored : uint256(covered) * uint256(c.epochHours) - 1;
        if (edge < hStored) edge = hStored;

        uint40[5] memory cand = [
            g.lastTickAt,
            uint40(uint256(g.startedAt) + (hStored + 1) * sph),
            uint40(uint256(g.startedAt) + edge * sph),
            uint40(uint256(g.startedAt) + (edge + 1) * sph),
            uint40(uint256(g.startedAt) + (edge + 5000) * sph)
        ];
        // Assigned one by one rather than as an array literal: a literal made of
        // string literals has no common type in Solidity and does not compile.
        string[5] memory candNames;
        candNames[0] = "the stored mark";
        candNames[1] = "one hour on";
        candNames[2] = "the pinned edge";
        candNames[3] = "one hour past the edge";
        candNames[4] = "five thousand hours past the edge";

        for (uint256 i = 0; i < 5; i++) {
            bool seen = false;
            for (uint256 j = 0; j < n; j++) {
                if (ts[j] == cand[i]) seen = true;
            }
            if (seen) continue;
            ts[n] = cand[i];
            names[n] = candNames[i];
            n += 1;
        }
    }

    // ── driving ──────────────────────────────────────────────────────────────

    /// @dev A distinct address per (state, attempt), so a retry never inherits the
    /// previous try's game.
    function _addr(uint256 state, uint256 attempt) private pure returns (address) {
        return address(uint160(0x5000_0000 + state * 0x1_0000 + attempt));
    }

    /// @dev Start `player`'s game at `BASE`.
    function _start(address player) private {
        vm.warp(BASE);
        vm.prank(player);
        lab.startGame();
    }

    /// @dev Move the clock to game hour `h` of a game started at `BASE`.
    function _warpTo(uint32 h) private {
        vm.warp(uint256(BASE) + uint256(h) * uint256(lab.config().secPerHour));
    }

    /// @dev Carry `player`'s world to the live timestamp, paying for a word when it
    /// hits the pinned-epoch edge, and deliver that word at once: no time passes
    /// between the request and the delivery, so the catch-up always applies.
    function _advance(address player) private {
        lab.sync{value: 1}(player);
        if (lab.getPending(player).active) lab.reveal(player);
    }

    /// @dev SEEDED, not played: the starting hand is three portals, so no sequence
    /// of real calls leaves exactly one open (a close needs time and costs hp).
    /// Starts a game for real (and lets the hand be born), then keeps one portal of the hand and empties the
    /// other slots through the harness setters, and pins one epoch to a fixed
    /// word. Appended LAST, so the request stream of states 0-10 is untouched.
    function _oneOpenPortalSeeded(address player) private {
        // Lived HOURS_FULL_HOUSE hours: the starting hand is open (as in state 2).
        _startAndLive(player, HOURS_FULL_HOUSE);
        Portal[MAX_OPEN_PORTALS] memory ps = lab.getPortals(player);
        bool kept;
        for (uint8 slot = 0; slot < MAX_OPEN_PORTALS; slot++) {
            if (ps[slot].status == PortalStatus.Empty) continue;
            if (!kept) {
                kept = true;
                continue;
            }
            Portal memory none;
            lab.setPortal(player, slot, none);
        }
        require(kept, "PreviewScenarios: no portal in the starting hand");
        Game memory g = lab.getGame(player);
        g.openPortals = 1;
        lab.setGame(player, g);
        // setGame pins a coverage of its own; put a single epoch back after it.
        lab.setCoverage(player, uint256(keccak256("preview-seeded-one-open")), 1);
    }

    /// @dev Start a game and live `h` game hours away from the keyboard, returning
    /// in a single crossing.
    function _startAndLive(address player, uint32 h) private {
        _start(player);
        _warpTo(h);
        _advance(player);
    }

    /// @dev Start a game and live `h` game hours, one hour per catch-up.
    function _startAndLiveHourByHour(address player, uint32 h) private {
        _start(player);
        for (uint32 k = 1; k <= h; k++) {
            _warpTo(k);
            _advance(player);
        }
    }

    /// @dev Start a game and leave it alone long enough for the deterministic
    /// long-absence overflow to end it. No word is needed, and none is asked for.
    function _startAndDie(address player) private {
        _start(player);
        _warpTo(HOURS_ABANDONED);
        lab.sync(player);
        require(lab.getGame(player).finished, "PreviewScenarios: the abandoned lab survived");
    }

    /// @dev Live into a world of open portals, then commit a survey on one that is
    /// not deaf, and stop there — the word is still in flight. A deaf portal is
    /// skipped because its first survey only narrows the ranges and would leave
    /// `surveyed` false, which is a different state from the one wanted.
    function _commitSurvey(uint256 state) private returns (address) {
        for (uint256 a = 0; a < ATTEMPTS; a++) {
            address player = _addr(state, a);
            _startAndLive(player, HOURS_FULL_HOUSE);
            (uint8 slot, bool ok) = _pick(lab.getPortals(player), false);
            if (!ok) continue;
            if (lab.canAct(player, slot, Action.SendObserver) != Refusal.None) continue;
            vm.prank(player);
            lab.act(slot, Action.SendObserver);
            if (!lab.getPending(player).active) continue;
            return player;
        }
        revert ScenarioUnreachable(state);
    }

    /// @dev Survey a portal whose creature range cannot be empty, then send a
    /// rescuer into the SAME portal, so one slot holds both crew members.
    function _observerAndRescuer(uint256 state) private returns (address) {
        for (uint256 a = 0; a < ATTEMPTS; a++) {
            address player = _addr(state, a);
            _startAndLive(player, HOURS_FULL_HOUSE);
            (uint8 slot, bool ok) = _pick(lab.getPortals(player), true);
            if (!ok) continue;
            if (lab.canAct(player, slot, Action.SendObserver) != Refusal.None) continue;
            vm.prank(player);
            lab.act(slot, Action.SendObserver);
            lab.reveal(player);
            if (!lab.getPortals(player)[slot].surveyed) continue;
            // The exact risk only exists now; a critical reading forbids sending
            // anyone in, which is a legitimate outcome of the draw — try again.
            if (lab.canAct(player, slot, Action.SendRescuer) != Refusal.None) continue;
            vm.prank(player);
            lab.act(slot, Action.SendRescuer);
            Portal memory p = lab.getPortals(player)[slot];
            if (p.observerInside && p.rescuerInside) return player;
        }
        revert ScenarioUnreachable(state);
    }

    /// @dev Send rescuers into unsurveyed portals until one of them finds the
    /// portal empty and leaves for recovery, parking a cooldown cell in the game.
    /// A rescuer who DID get in is recalled, so the next portal can be tried.
    /// Lives to the hour the first portal after the hand is born: a blind rescuer
    /// is judged on the cautious end of the ranges, and only a portal born that
    /// very hour still has its type's ranges un-widened (the hand's have drifted
    /// out since hour 0 and read critical).
    function _rescuerRecovering(uint256 state) private returns (address) {
        for (uint256 a = 0; a < ATTEMPTS; a++) {
            address player = _addr(state, a);
            _startAndLive(player, HOURS_ONE_PORTAL);
            // Each try runs in its own call frame (an external self-call), so its
            // memory is released: ATTEMPTS iterations of `getPortals` in one frame
            // exhaust the script's memory (MemoryOOG).
            if (this.tryRecovering(player)) return player;
        }
        revert ScenarioUnreachable(state);
    }

    /// @dev One try of `_rescuerRecovering`, in a frame of its own. Only `this`
    /// may call it.
    function tryRecovering(address player) external returns (bool) {
        require(msg.sender == address(this), "PreviewScenarios: internal");
        for (uint8 slot = 0; slot < MAX_OPEN_PORTALS; slot++) {
            if (lab.getPortals(player)[slot].status == PortalStatus.Empty) continue;
            if (lab.canAct(player, slot, Action.SendRescuer) != Refusal.None) continue;
            vm.prank(player);
            lab.act(slot, Action.SendRescuer);
            if (lab.getPending(player).active) lab.reveal(player);
            if (lab.getGame(player).rescuerReadyAt0 != 0) return true;
            if (lab.canAct(player, slot, Action.RecallRescuer) == Refusal.None) {
                vm.prank(player);
                lab.act(slot, Action.RecallRescuer);
            }
        }
        return false;
    }

    /// @dev First open portal fit for a survey. `needCreatures` demands a type
    /// whose creature range starts above zero (LongLived, Flash), so the survey is
    /// certain to find someone and a rescuer may follow; otherwise any non-deaf
    /// type will do.
    function _pick(Portal[MAX_OPEN_PORTALS] memory ps, bool needCreatures)
        private
        pure
        returns (uint8, bool)
    {
        // LongLived first: it is the roomiest type (30–60 hours, stability 40–90),
        // so its exact risk is the least likely to come back critical and block the
        // rescuer that scenario 6 needs.
        for (uint8 pass = 0; pass < 2; pass++) {
            for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
                if (ps[i].status == PortalStatus.Empty) continue;
                if (ps[i].surveyed || ps[i].surveyPending) continue;
                PortalType t = ps[i].portalType;
                if (pass == 0 && t != PortalType.LongLived) continue;
                if (pass == 1) {
                    if (needCreatures && t != PortalType.Flash) continue;
                    if (!needCreatures && t == PortalType.Deaf) continue;
                }
                return (i, true);
            }
        }
        return (0, false);
    }
}
