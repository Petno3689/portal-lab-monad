// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {Game, Portal, Config, PortalTypeParams} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";
import {TimeHarness} from "./utils/TimeHarness.sol";

/// @title SpawnGoldenTest — verifies step 5 of `TimeLib.catchUp` (pressure, the
/// deterministic long-absence death and the spawns both branches pay for) against
/// the pre-generated vector file shared/test/vectors/spawn-vectors.json (format:
/// extension 5 of shared/test/support/vectorFormat.ts).
/// Run `forge script script/GenSpawnVectors.s.sol` first. This test proves the file
/// has not drifted from the contract; the TS test proves the mirror matches the file.
///
/// EVERY field of the game and of all twelve portals is compared, plus every
/// collapse and every spawn event and `cappedShort` — not a selection: a partial
/// comparison is a hole that looks like a green test.
///
/// The `refusals` section is replayed through TimeHarness, the only way to catch a
/// revert raised inside an internal library function.
contract SpawnGoldenTest is Test {
    string private constant PATH = "../shared/test/vectors/spawn-vectors.json";

    /// @dev The whole file, read column-wise. Grouped into a struct so the replay
    /// loop does not juggle a dozen separate arrays.
    struct File {
        Config[] cfgs;
        PortalTypeParams[] tps;
        Game[] g;
        Portal[] pIn;
        uint256[] cfgIdx;
        uint256[] tsIdx;
        uint256[] oldWord;
        uint256[] newWord;
        uint256[] stored;
        uint256[] maxCov;
        uint256[] nowTs;
        Game[] wantG;
        Portal[] wantP;
        TimeLib.Collapse[] wantEv;
        TimeLib.Spawn[] wantSp;
        bool[] wantCapped;
        uint256 n;
    }

    /// @dev The refusal section: inputs plus the expected revert.
    struct Refusals {
        Game[] g;
        Portal[] pIn;
        uint256[] cfgIdx;
        uint256[] tsIdx;
        uint256[] oldWord;
        uint256[] newWord;
        uint256[] stored;
        uint256[] maxCov;
        uint256[] nowTs;
        bool[] wantRev;
        string[] wantErr;
        uint256 n;
    }

    TimeHarness private h;

    function setUp() public {
        h = new TimeHarness();
    }

    function test_GoldenVectors() external view {
        string memory json = vm.readFile(PATH);
        File memory f = _read(json);

        assertGe(f.n, 40, "expected at least 40 vectors");
        assertEq(f.pIn.length, f.n * 12, "portalsIn must hold exactly twelve portals per vector");
        assertEq(f.wantP.length, f.n * 12, "portalsOut must hold exactly twelve portals per vector");
        assertEq(f.wantG.length, f.n, "length mismatch: expected game");
        assertEq(f.wantCapped.length, f.n, "length mismatch: cappedShort");
        // The point of this file: unlike catchup-vectors.json, step 5 does fire here.
        assertGe(f.wantSp.length, 20, "this file must record spawns: step 5 is the subject");

        uint256 evOffset;
        uint256 spOffset;
        for (uint256 i = 0; i < f.n; i++) {
            (evOffset, spOffset) = _replay(f, i, evOffset, spOffset);
        }
        assertEq(evOffset, f.wantEv.length, "the file records collapse events the library never produced");
        assertEq(spOffset, f.wantSp.length, "the file records spawns the library never produced");
    }

    function test_Refusals() external view {
        string memory json = vm.readFile(PATH);
        Config[] memory cfgs = VectorCodec.readConfigs(json, ".configs[*]");
        PortalTypeParams[] memory tps = VectorCodec.readTypeParams(json, ".typeParams[*]");
        Refusals memory r = _readRefusals(json);

        assertGe(r.n, 3, "expected at least three refusal vectors");
        assertEq(r.pIn.length, r.n * 12, "refusal portalsIn must hold exactly twelve portals per vector");
        assertEq(r.wantErr.length, r.n, "length mismatch: refusal error");

        for (uint256 i = 0; i < r.n; i++) {
            string memory where = string.concat("refusal i=", vm.toString(i));
            assertTrue(r.wantRev[i], string.concat("a refusal row must expect a revert at ", where));

            Portal[12] memory pIn;
            for (uint256 j = 0; j < 12; j++) {
                pIn[j] = r.pIn[i * 12 + j];
            }

            try h.catchUp(
                r.g[i],
                pIn,
                cfgs[r.cfgIdx[i]],
                _set(tps, r.tsIdx[i]),
                r.oldWord[i],
                r.newWord[i],
                uint32(r.stored[i]),
                uint32(r.maxCov[i]),
                uint40(r.nowTs[i])
            ) {
                revert(string.concat("the library did not revert at ", where));
            } catch (bytes memory err) {
                // Not merely "it reverted": the SAME kind of revert.
                assertEq(VectorCodec.errorName(err), r.wantErr[i], string.concat("revert kind mismatch at ", where));
            }
        }
    }

    // ── reading ──────────────────────────────────────────────────────────────

    function _read(string memory json) private pure returns (File memory f) {
        f.cfgs = VectorCodec.readConfigs(json, ".configs[*]");
        f.tps = VectorCodec.readTypeParams(json, ".typeParams[*]");
        f.g = VectorCodec.readGames(json, ".vectors[*].game");
        f.n = f.g.length;
        // Two wildcards: the per-vector arrays come back flattened, twelve per
        // vector, in vector order.
        f.pIn = VectorCodec.readPortals(json, ".vectors[*].portalsIn[*]");
        f.cfgIdx = VectorCodec.readUints(json, ".vectors[*].config");
        f.tsIdx = VectorCodec.readUints(json, ".vectors[*].types");
        f.oldWord = VectorCodec.readWordField(json, ".vectors", "oldWord", f.n);
        f.newWord = VectorCodec.readWordField(json, ".vectors", "newWord", f.n);
        f.stored = VectorCodec.readUints(json, ".vectors[*].storedCoveredEpochs");
        f.maxCov = VectorCodec.readUints(json, ".vectors[*].maxCoveredEpochs");
        f.nowTs = VectorCodec.readUints(json, ".vectors[*].nowTs");
        f.wantG = VectorCodec.readGames(json, ".vectors[*].expected.game");
        f.wantP = VectorCodec.readPortals(json, ".vectors[*].expected.portalsOut[*]");
        // A path matching NOTHING (every vector's array empty) makes `vm.parseJson`
        // return zero bytes, which the column decoder cannot read — so ask first.
        if (vm.parseJson(json, ".vectors[*].expected.events[*].slot").length > 0) {
            f.wantEv = VectorCodec.readCollapses(json, ".vectors[*].expected.events[*]");
        }
        if (vm.parseJson(json, ".vectors[*].expected.spawns[*].slot").length > 0) {
            f.wantSp = VectorCodec.readSpawns(json, ".vectors[*].expected.spawns[*]");
        }
        f.wantCapped = VectorCodec.readBools(json, ".vectors[*].expected.cappedShort");
    }

    function _readRefusals(string memory json) private pure returns (Refusals memory r) {
        r.g = VectorCodec.readGames(json, ".refusals[*].game");
        r.n = r.g.length;
        r.pIn = VectorCodec.readPortals(json, ".refusals[*].portalsIn[*]");
        r.cfgIdx = VectorCodec.readUints(json, ".refusals[*].config");
        r.tsIdx = VectorCodec.readUints(json, ".refusals[*].types");
        r.oldWord = VectorCodec.readWordField(json, ".refusals", "oldWord", r.n);
        r.newWord = VectorCodec.readWordField(json, ".refusals", "newWord", r.n);
        r.stored = VectorCodec.readUints(json, ".refusals[*].storedCoveredEpochs");
        r.maxCov = VectorCodec.readUints(json, ".refusals[*].maxCoveredEpochs");
        r.nowTs = VectorCodec.readUints(json, ".refusals[*].nowTs");
        r.wantRev = VectorCodec.readBools(json, ".refusals[*].expected.reverted");
        r.wantErr = VectorCodec.readStrings(json, ".refusals[*].expected.error");
    }

    function _set(PortalTypeParams[] memory tps, uint256 idx) private pure returns (PortalTypeParams[5] memory out) {
        for (uint256 i = 0; i < 5; i++) {
            out[i] = tps[idx * 5 + i];
        }
    }

    // ── replay ───────────────────────────────────────────────────────────────

    /// @dev Runs vector `i` and compares the whole result. The collapse and spawn
    /// events of all vectors sit in ONE flat column each, so the caller threads a
    /// running offset through: vector `i` owns the entries starting at its offset,
    /// and the final offsets must land exactly on the columns' ends.
    function _replay(File memory f, uint256 i, uint256 evOffset, uint256 spOffset)
        private
        pure
        returns (uint256, uint256)
    {
        string memory where = string.concat("vector i=", vm.toString(i));

        Portal[12] memory pIn;
        for (uint256 j = 0; j < 12; j++) {
            pIn[j] = f.pIn[i * 12 + j];
        }

        (
            Game memory g2,
            Portal[12] memory p2,
            TimeLib.Collapse[64] memory ev,
            uint8 evN,
            TimeLib.Spawn[64] memory sp,
            uint8 spN,
            bool capped
        ) = TimeLib.catchUp(
            f.g[i],
            pIn,
            f.cfgs[f.cfgIdx[i]],
            _set(f.tps, f.tsIdx[i]),
            f.oldWord[i],
            f.newWord[i],
            uint32(f.stored[i]),
            uint32(f.maxCov[i]),
            uint40(f.nowTs[i])
        );

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

        assertLe(evOffset + evN, f.wantEv.length, string.concat("the file is short of collapse events at ", where));
        for (uint256 k = 0; k < evN; k++) {
            TimeLib.Collapse memory want = f.wantEv[evOffset + k];
            string memory at = string.concat(where, " event k=", vm.toString(k));
            assertEq(ev[k].slot, want.slot, string.concat("event slot mismatch at ", at));
            assertEq(ev[k].deaths, want.deaths, string.concat("event deaths mismatch at ", at));
            assertEq(ev[k].hpLost, want.hpLost, string.concat("event hpLost mismatch at ", at));
            assertEq(ev[k].atHour, want.atHour, string.concat("event atHour mismatch at ", at));
        }

        assertLe(spOffset + spN, f.wantSp.length, string.concat("the file is short of spawns at ", where));
        for (uint256 k = 0; k < spN; k++) {
            TimeLib.Spawn memory want = f.wantSp[spOffset + k];
            string memory at = string.concat(where, " spawn k=", vm.toString(k));
            assertEq(sp[k].slot, want.slot, string.concat("spawn slot mismatch at ", at));
            assertEq(uint8(sp[k].portalType), uint8(want.portalType), string.concat("spawn type mismatch at ", at));
            assertEq(sp[k].nameIndex, want.nameIndex, string.concat("spawn nameIndex mismatch at ", at));
            assertEq(sp[k].atHour, want.atHour, string.concat("spawn atHour mismatch at ", at));
        }

        return (evOffset + evN, spOffset + spN);
    }
}
