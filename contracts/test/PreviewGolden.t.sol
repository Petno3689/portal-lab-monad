// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    Game,
    Portal,
    PortalType,
    MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

/// @title PreviewGoldenTest — verifies `PortalLab.preview` against the
/// pre-generated vector file shared/test/vectors/preview-vectors.json (format:
/// extension 6 of shared/test/support/vectorFormat.ts).
/// Run `forge script script/GenPreviewVectors.s.sol` first. This test proves the
/// file has not drifted from the contract; the TS test proves the mirror matches
/// the file.
///
/// @dev The real entry point is replayed, not an equivalent library call: each
/// vector's stored world is installed with the harness setters and `preview` is
/// asked for it with the clock wound to the vector's moment. That also covers the
/// wiring `preview` does on the way in — which config it loads, which word and
/// which covered-epoch count it feeds the catch-up — and not only the arithmetic
/// underneath. Installing a world here is not state invention: every world in the
/// file was produced by the contract itself (see script/GenPreviewVectors.s.sol).
///
/// EVERY field of the game and of all twelve portals is compared, not a selection:
/// a partial comparison is a hole that looks like a green test.
contract PreviewGoldenTest is Test {
    string private constant PATH = "../shared/test/vectors/preview-vectors.json";

    /// @dev Whoever the vectors are installed on. Which address it is does not
    /// matter: the whole world is overwritten for every vector.
    address private constant PLAYER = address(0xBEEF);

    PortalLabHarness private lab;

    /// @dev The whole file, read column-wise. Grouped into a struct so the replay
    /// loop does not juggle a dozen separate arrays.
    struct File {
        Game[] g;
        Portal[] pIn;
        uint256[] cfgIdx;
        uint256[] tsIdx;
        uint256[] word;
        uint256[] covered;
        uint256[] nowTs;
        Game[] wantG;
        Portal[] wantP;
        bool[] wantCapped;
        uint256 n;
    }

    function setUp() public {
        lab = new PortalLabHarness();
    }

    function test_GoldenVectors() external {
        File memory f = _read(vm.readFile(PATH));

        assertGe(f.n, 40, "expected at least 40 vectors");
        assertEq(f.pIn.length, f.n * 12, "portalsIn must hold exactly twelve portals per vector");
        assertEq(f.wantP.length, f.n * 12, "portalsOut must hold exactly twelve portals per vector");
        assertEq(f.wantG.length, f.n, "length mismatch: expected game");
        assertEq(f.wantCapped.length, f.n, "length mismatch: cappedShort");

        // The vectors were produced under the parameters of a harness deployment,
        // and they are replayed on another one. If the two ever differ the whole
        // comparison is meaningless, so it is checked rather than assumed.
        _assertParamsMatchDeployment(vm.readFile(PATH));
        _assertCorpusIsNotDegenerate(f);

        for (uint256 i = 0; i < f.n; i++) {
            assertEq(f.cfgIdx[i], 0, "every vector points at the one config");
            assertEq(f.tsIdx[i], 0, "every vector points at the one type-parameter set");
            _replay(f, i);
        }
    }

    // ── reading ──────────────────────────────────────────────────────────────

    function _read(string memory json) private pure returns (File memory f) {
        f.g = VectorCodec.readGames(json, ".vectors[*].game");
        f.n = f.g.length;
        // Two wildcards: the per-vector arrays come back flattened, twelve per
        // vector, in vector order.
        f.pIn = VectorCodec.readPortals(json, ".vectors[*].portalsIn[*]");
        f.cfgIdx = VectorCodec.readUints(json, ".vectors[*].config");
        f.tsIdx = VectorCodec.readUints(json, ".vectors[*].types");
        f.word = VectorCodec.readWordField(json, ".vectors", "epochWord", f.n);
        f.covered = VectorCodec.readUints(json, ".vectors[*].coveredEpochs");
        f.nowTs = VectorCodec.readUints(json, ".vectors[*].nowTs");
        f.wantG = VectorCodec.readGames(json, ".vectors[*].expected.game");
        f.wantP = VectorCodec.readPortals(json, ".vectors[*].expected.portalsOut[*]");
        f.wantCapped = VectorCodec.readBools(json, ".vectors[*].expected.cappedShort");
    }

    // ── guards ───────────────────────────────────────────────────────────────

    /// @dev The file's single config and five type-parameter rows must be the ones
    /// this harness runs on.
    ///
    /// Checked as TEXT rather than by decoding the two header arrays, because a
    /// one-element column cannot be read: `vm.parseJson` on `.configs[*].field`
    /// returns a bare value when the array holds a single entry, and decoding that
    /// as `uint256[]` reverts. Searching for the serialised form is not a weaker
    /// check — the generator writes these objects with the very same encoders, so
    /// the bytes match if and only if every field does.
    function _assertParamsMatchDeployment(string memory json) private view {
        assertTrue(
            vm.contains(json, VectorCodec.configJson(lab.config())),
            "the file was generated under a different config than the harness deploys"
        );
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(
                vm.contains(json, VectorCodec.typeParamsJson(lab.portalTypeParams(PortalType(uint8(i))))),
                string.concat("type-parameter row ", vm.toString(i), " does not match the harness")
            );
        }
    }

    /// @dev A corpus of forty identical trivial rows would pass every comparison
    /// below and prove nothing. Demand that it actually spans the behaviour the
    /// ticket asks for.
    function _assertCorpusIsNotDegenerate(File memory f) private pure {
        bool capped;
        bool reached;
        bool openPortal;
        bool surveyed;
        bool crewInside;
        bool cooldown;
        bool died;
        bool settled;
        bool coveredZero;
        bool coveredSome;
        for (uint256 i = 0; i < f.n; i++) {
            if (f.wantCapped[i]) capped = true;
            else reached = true;
            if (f.wantG[i].openPortals > 0) openPortal = true;
            if (f.wantG[i].finished) died = true;
            if (f.wantG[i].settled) settled = true;
            if (f.covered[i] == 0) coveredZero = true;
            else coveredSome = true;
            if (
                f.wantG[i].rescuerReadyAt0 != 0 || f.wantG[i].rescuerReadyAt1 != 0
                    || f.wantG[i].rescuerReadyAt2 != 0 || f.wantG[i].rescuerReadyAt3 != 0
            ) cooldown = true;
            for (uint256 j = 0; j < 12; j++) {
                Portal memory p = f.wantP[i * 12 + j];
                if (p.surveyed) surveyed = true;
                if (p.observerInside && p.rescuerInside) crewInside = true;
            }
        }
        assertTrue(capped, "no vector stops at the pinned edge");
        assertTrue(reached, "no vector reaches the moment it asked for");
        assertTrue(openPortal, "no vector holds an open portal");
        assertTrue(surveyed, "no vector holds a surveyed portal");
        assertTrue(crewInside, "no vector holds an observer and a rescuer in one portal");
        assertTrue(cooldown, "no vector holds a rescuer in cooldown");
        assertTrue(died, "no vector holds a finished run");
        assertTrue(settled, "no vector holds a settled run");
        assertTrue(coveredZero, "no vector has an unpinned world");
        assertTrue(coveredSome, "no vector has a pinned world");
    }

    // ── replay ───────────────────────────────────────────────────────────────

    /// @dev Install vector `i`'s stored world, ask `preview` for it at the
    /// vector's moment, and compare the whole result.
    function _replay(File memory f, uint256 i) private {
        string memory where = string.concat("vector i=", vm.toString(i));

        // setGame pins a generous coverage and a derived word of its own, so
        // setCoverage must come after it to put the vector's values back.
        lab.setGame(PLAYER, f.g[i]);
        lab.setCoverage(PLAYER, f.word[i], uint32(f.covered[i]));
        for (uint256 j = 0; j < 12; j++) {
            lab.setPortal(PLAYER, uint8(j), f.pIn[i * 12 + j]);
        }

        vm.warp(f.nowTs[i]);
        (Game memory g2, Portal[MAX_OPEN_PORTALS] memory p2, bool capped) = lab.preview(PLAYER);

        assertEq(capped, f.wantCapped[i], string.concat("cappedShort mismatch at ", where));

        if (keccak256(abi.encode(g2)) != keccak256(abi.encode(f.wantG[i]))) {
            assertEq(
                VectorCodec.gameJson(g2),
                VectorCodec.gameJson(f.wantG[i]),
                string.concat("game mismatch at ", where)
            );
        }
        for (uint256 j = 0; j < 12; j++) {
            Portal memory want = f.wantP[i * 12 + j];
            if (keccak256(abi.encode(p2[j])) != keccak256(abi.encode(want))) {
                assertEq(
                    VectorCodec.portalJson(p2[j]),
                    VectorCodec.portalJson(want),
                    string.concat("portal mismatch at ", where, " slot=", vm.toString(j))
                );
            }
        }
    }
}
