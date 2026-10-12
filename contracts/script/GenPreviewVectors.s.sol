// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    Game,
    Portal,
    Config,
    PortalTypeParams,
    PortalType,
    PortalStatus,
    MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "../test/utils/VectorCodec.sol";
import {PortalLabHarness} from "../test/utils/PortalLabHarness.sol";
import {PreviewScenarios, PREVIEW_STATE_COUNT} from "../test/utils/PreviewScenarios.sol";

/// @notice Generates the golden vectors for `PortalLab.preview`:
///   ../shared/test/vectors/preview-vectors.json
/// Run from contracts/:  forge script script/GenPreviewVectors.s.sol
/// No RPC, no broadcast. The file format is documented in
/// shared/test/support/vectorFormat.ts (extension 6).
///
/// ── What makes this corpus different ────────────────────────────────────────
/// Every earlier generator BUILT its states: it filled the fields of a `Game` and
/// of twelve `Portal`s directly. That is fine for a pure library, whose contract
/// is "given these fields, return that" — but it says nothing about whether the
/// fields can occur together. Such a state may be unreachable, and a reachable one
/// may never appear.
///
/// Here the states are WORKED OUT BY THE CONTRACT. A `PortalLabHarness` is
/// deployed over a `DeterministicSource` and games are driven through the real
/// entry points — `startGame`, `act` with lawful actions, `sync`, a delivered
/// word, `settle` — with the clock wound forward between the steps. After each
/// step the player's whole stored state is read back and recorded. The driving
/// itself lives in test/utils/PreviewScenarios.sol, because
/// test/PreviewMatchesSync.t.sol checks the same states against an unpaid `sync`
/// and the two must be looking at the same worlds.
///
/// `config` and `types` are indices, as always, but the values behind them are
/// READ OUT OF THE DEPLOYED HARNESS (`config()`, `portalTypeParams()`) rather
/// than repeated from `GameConfig` — a vector must carry the parameters the state
/// was actually produced under, not parameters that merely ought to match.
///
/// ── Shape of the file ───────────────────────────────────────────────────────
///   { "configs": [<Config>], "typeParams": [<PortalTypeParams> x5],
///     "vectors": [ { label, game, portalsIn (12), config, types,
///                    epochWord (string), coveredEpochs, nowTs,
///                    expected: { game, portalsOut (12), cappedShort } } ] }
///
/// Several projections are taken off every state: exactly on the stored mark, an
/// hour on, at the pinned edge, one hour past it (where `cappedShort` turns true)
/// and far beyond.
///
/// Coverage: every state and moment the ticket requires is registered by name
/// (`_reg`) and marked by the vectors that reach it; the run ABORTS if any case
/// is reached by none.
contract GenPreviewVectors is Script {
    string private constant PATH = "../shared/test/vectors/preview-vectors.json";

    /// @dev Eleven states, at most five projections each.
    uint256 private constant CAPACITY = PREVIEW_STATE_COUNT * 5;

    /// @dev One recorded projection: the stored state it was taken from, the
    /// moment it was taken at, and what `preview` returned.
    struct Vec {
        string label;
        Game g;
        Portal[MAX_OPEN_PORTALS] p;
        uint256 word;
        uint32 covered;
        uint40 nowTs;
        Game rg;
        Portal[MAX_OPEN_PORTALS] rp;
        bool capped;
    }

    /// @dev Coverage registry: a fixed list of case names and a hit counter each.
    struct Cov {
        string[] names;
        uint256[] counts;
        uint256 n;
    }

    function run() external {
        // The driver owns the harness and pays for its own crossings: a script
        // contract may not be the subject of `vm.deal` (its address is ephemeral),
        // so the wei has to live somewhere that is not this contract.
        PreviewScenarios drv = new PreviewScenarios();
        PortalLabHarness lab = drv.lab();
        Config memory c = lab.config();

        Vec[] memory vs = new Vec[](CAPACITY);
        Cov memory cv = _register();
        uint256 n = 0;

        // In order, 0 … COUNT-1, with no randomness requested in between: that is
        // what makes the states reproducible for the second consumer of this
        // driver (see PreviewScenarios' note on determinism).
        for (uint256 i = 0; i < PREVIEW_STATE_COUNT; i++) {
            address player = drv.build(i);
            n = _snap(drv, lab, vs, n, cv, drv.label(i), player, c);
        }

        require(n > 0, "not a single projection recorded");
        _requireCoverage(cv);

        vm.writeFile(PATH, _head(lab));
        _write(vs, n);
        vm.writeLine(PATH, "]}");

        console.log("preview vectors written:", n);
        console.log("distinct states behind them:", PREVIEW_STATE_COUNT);
        console.log("coverage (hits per case):");
        for (uint256 i = 0; i < cv.n; i++) {
            console.log(string.concat("  ", vm.toString(cv.counts[i]), "  ", cv.names[i]));
        }
    }

    // ── recording ───────────────────────────────────────────────────────────

    /// @dev Read `player`'s whole stored state, then project it onto each moment
    /// `PreviewScenarios.moments` names, appending one vector per moment.
    ///
    /// The clock is wound to each moment because `preview` reads `block.timestamp`
    /// — it takes no moment of its own. It is a view, so the winding changes
    /// nothing; the clock is put back before returning all the same, so the next
    /// scenario starts from where this one left off.
    function _snap(
        PreviewScenarios drv,
        PortalLabHarness lab,
        Vec[] memory vs,
        uint256 n,
        Cov memory cv,
        string memory lbl,
        address player,
        Config memory c
    ) private returns (uint256) {
        uint256 saved = block.timestamp;

        Game memory g = lab.getGame(player);
        Portal[MAX_OPEN_PORTALS] memory ps = lab.getPortals(player);
        uint256 word = lab.epochWordOf(player);
        uint32 covered = lab.getPending(player).coveredEpochs;

        // Read straight off the player rather than inferred from the vector: a
        // deferral lives in `Pending`, which no preview vector carries (`preview`
        // does not read it beyond `coveredEpochs`), so the fields alone cannot tell
        // a pending state from a quiet one.
        bool deferred = lab.getPending(player).active;

        _tagState(cv, g, ps, word, covered, deferred);

        (uint40[5] memory ts, string[5] memory names, uint256 k) = drv.moments(g, covered, c);
        for (uint256 j = 0; j < k; j++) {
            vm.warp(ts[j]);
            (Game memory rg, Portal[MAX_OPEN_PORTALS] memory rp, bool capped) = lab.preview(player);

            Vec memory v = vs[n];
            v.label = string.concat(lbl, " @ ", names[j]);
            // The stored world is read AGAIN, per vector, rather than handing every
            // vector of this state the one snapshot `g` / `ps` read above: a memory
            // assignment in Solidity is a second reference, not a copy (CLAUDE.md),
            // and a shared reference is the kind of quiet coupling that makes a
            // generator record something other than what it means to. Each call
            // returns its own memory; `g` / `ps` are used only to choose the moments
            // and to tag coverage.
            v.g = lab.getGame(player);
            v.p = lab.getPortals(player);
            v.word = word;
            v.covered = covered;
            v.nowTs = ts[j];
            v.rg = rg;
            v.rp = rp;
            v.capped = capped;

            _tagMoment(cv, v);
            n += 1;
        }

        vm.warp(saved);
        return n;
    }

    // ── coverage ────────────────────────────────────────────────────────────

    function _reg(Cov memory cv, string memory name) private pure {
        cv.names[cv.n] = name;
        cv.n++;
    }

    /// @dev Every case the ticket requires. `_mark` with a name not in this list
    /// reverts, so a typo cannot quietly invent a case nobody checks.
    function _register() private pure returns (Cov memory cv) {
        cv.names = new string[](32);
        cv.counts = new uint256[](32);

        _reg(cv, "state: a freshly started game, no hour lived yet");
        _reg(cv, "state: exactly one open portal");
        _reg(cv, "state: several open portals");
        _reg(cv, "state: a surveyed portal");
        _reg(cv, "state: an unsurveyed portal");
        _reg(cv, "state: an observer inside a portal");
        _reg(cv, "state: a rescuer inside a portal");
        _reg(cv, "state: an observer and a rescuer inside the same portal");
        _reg(cv, "state: a rescuer in cooldown after a blind entry");
        _reg(cv, "state: a deferred action outstanding");
        _reg(cv, "state: the run ended in death");
        _reg(cv, "state: the run ended and was settled");
        _reg(cv, "state: coveredEpochs == 0");
        _reg(cv, "state: coveredEpochs > 0");
        _reg(cv, "state: epochWord == 0");
        _reg(cv, "state: epochWord != 0");

        _reg(cv, "moment: the projection stops at the pinned edge (cappedShort)");
        _reg(cv, "moment: the projection reaches the moment asked for");
        _reg(cv, "moment: exactly on the stored mark, and nothing changes");
        _reg(cv, "moment: far past the edge");
    }

    function _mark(Cov memory cv, bool cond, string memory name) private pure {
        if (!cond) return;
        bytes32 h = keccak256(bytes(name));
        for (uint256 i = 0; i < cv.n; i++) {
            if (keccak256(bytes(cv.names[i])) == h) {
                cv.counts[i]++;
                return;
            }
        }
        revert(string.concat("unregistered coverage case: ", name));
    }

    function _requireCoverage(Cov memory cv) private pure {
        for (uint256 i = 0; i < cv.n; i++) {
            require(cv.counts[i] > 0, string.concat("case not covered by any state: ", cv.names[i]));
        }
    }

    /// @dev Tag what the STORED state holds — once per state, not once per moment.
    function _tagState(
        Cov memory cv,
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory ps,
        uint256 word,
        uint32 covered,
        bool deferred
    ) private pure {
        uint256 open = 0;
        bool surveyed = false;
        bool unsurveyed = false;
        bool observer = false;
        bool rescuer = false;
        bool both = false;
        for (uint256 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (ps[i].status == PortalStatus.Empty) continue;
            open += 1;
            if (ps[i].surveyed) surveyed = true;
            else unsurveyed = true;
            if (ps[i].observerInside) observer = true;
            if (ps[i].rescuerInside) rescuer = true;
            if (ps[i].observerInside && ps[i].rescuerInside) both = true;
        }

        _mark(cv, g.startedAt != 0 && g.hoursElapsed == 0 && open == 0 && !g.finished,
            "state: a freshly started game, no hour lived yet");
        _mark(cv, open == 1, "state: exactly one open portal");
        _mark(cv, open > 1, "state: several open portals");
        _mark(cv, surveyed, "state: a surveyed portal");
        _mark(cv, unsurveyed, "state: an unsurveyed portal");
        _mark(cv, observer, "state: an observer inside a portal");
        _mark(cv, rescuer, "state: a rescuer inside a portal");
        _mark(cv, both, "state: an observer and a rescuer inside the same portal");
        _mark(cv, g.rescuerReadyAt0 != 0 || g.rescuerReadyAt1 != 0 || g.rescuerReadyAt2 != 0
            || g.rescuerReadyAt3 != 0, "state: a rescuer in cooldown after a blind entry");
        _mark(cv, deferred, "state: a deferred action outstanding");
        _mark(cv, g.finished && !g.settled, "state: the run ended in death");
        _mark(cv, g.finished && g.settled, "state: the run ended and was settled");
        _mark(cv, covered == 0, "state: coveredEpochs == 0");
        _mark(cv, covered > 0, "state: coveredEpochs > 0");
        _mark(cv, word == 0, "state: epochWord == 0");
        _mark(cv, word != 0, "state: epochWord != 0");
    }

    /// @dev Tag what the PROJECTION did.
    function _tagMoment(Cov memory cv, Vec memory v) private pure {
        _mark(cv, v.capped, "moment: the projection stops at the pinned edge (cappedShort)");
        // Reached the asked-for moment AND actually moved to get there: on a state
        // already standing at `nowTs` nothing was projected at all.
        _mark(cv, !v.capped && !v.rg.finished && v.rg.lastTickAt == v.nowTs && v.nowTs > v.g.lastTickAt,
            "moment: the projection reaches the moment asked for");
        _mark(cv, v.nowTs == v.g.lastTickAt && _same(v.g, v.rg) && _same12(v.p, v.rp),
            "moment: exactly on the stored mark, and nothing changes");
        _mark(cv, v.nowTs > uint256(v.g.lastTickAt) + 1000, "moment: far past the edge");
    }

    function _same(Game memory a, Game memory b) private pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _same12(Portal[MAX_OPEN_PORTALS] memory a, Portal[MAX_OPEN_PORTALS] memory b)
        private
        pure
        returns (bool)
    {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    // ── output ──────────────────────────────────────────────────────────────

    /// @dev The one config and the five type-parameter rows the harness was
    /// deployed with, read back out of it.
    function _head(PortalLabHarness lab) private view returns (string memory) {
        string memory s = string.concat('{"configs":[', VectorCodec.configJson(lab.config()), '],"typeParams":[');
        for (uint256 i = 0; i < 5; i++) {
            s = string.concat(
                s, i == 0 ? "" : ",", VectorCodec.typeParamsJson(lab.portalTypeParams(PortalType(uint8(i))))
            );
        }
        return string.concat(s, '],"vectors":[');
    }

    function _write(Vec[] memory vs, uint256 n) private {
        for (uint256 i = 0; i < n; i++) {
            // Each line builds hundreds of throw-away strings and EVM memory is
            // never freed; rewinding the free-memory pointer after the write keeps
            // the run inside Foundry's memory cap. Nothing built inside the
            // iteration is used after it. (Same idiom as GenSpawnVectors.)
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            vm.writeLine(PATH, _line(vs[i], i + 1 == n));
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
        }
    }

    function _portalsJson(Portal[MAX_OPEN_PORTALS] memory ps) private pure returns (string memory s) {
        s = "[";
        for (uint256 i = 0; i < MAX_OPEN_PORTALS; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.portalJson(ps[i]));
        }
        s = string.concat(s, "]");
    }

    function _line(Vec memory v, bool last) private pure returns (string memory) {
        string memory inputs = string.concat(
            '{"label":"', v.label, '",',
            '"game":', VectorCodec.gameJson(v.g), ",",
            '"portalsIn":', _portalsJson(v.p), ",",
            VectorCodec.kv("config", 0), ",",
            VectorCodec.kv("types", 0), ",",
            VectorCodec.ks("epochWord", v.word), ",",
            VectorCodec.kv("coveredEpochs", v.covered), ",",
            VectorCodec.kv("nowTs", v.nowTs), ","
        );
        string memory expected = string.concat(
            '"expected":{',
            '"game":', VectorCodec.gameJson(v.rg), ",",
            '"portalsOut":', _portalsJson(v.rp), ",",
            VectorCodec.kb("cappedShort", v.capped),
            "}}"
        );
        return string.concat(inputs, expected, last ? "" : ",");
    }
}
