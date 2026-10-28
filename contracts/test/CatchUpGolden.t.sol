// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {Game, Portal, Config, PortalTypeParams} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";

/// @title CatchUpGoldenTest — verifies `TimeLib.catchUp` against the pre-generated
/// vector file shared/test/vectors/catchup-vectors.json (format: extension 4 of
/// shared/test/support/vectorFormat.ts).
/// Run `forge script script/GenCatchUpVectors.s.sol` first. This test proves the
/// file has not drifted from the contract; the TS test proves the mirror matches
/// the file.
///
/// EVERY field of the game and of all twelve portals is compared, not a selection:
/// a partial comparison is a hole that looks like a green test.
contract CatchUpGoldenTest is Test {
    string private constant PATH = "../shared/test/vectors/catchup-vectors.json";

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
        bool[] wantCapped;
        uint256 n;
    }

    function test_GoldenVectors() external view {
        string memory json = vm.readFile(PATH);
        File memory f = _read(json);

        assertGe(f.n, 40, "expected at least 40 vectors");
        assertEq(f.pIn.length, f.n * 12, "portalsIn must hold exactly twelve portals per vector");
        assertEq(f.wantP.length, f.n * 12, "portalsOut must hold exactly twelve portals per vector");
        assertEq(f.wantG.length, f.n, "length mismatch: expected game");
        assertEq(f.wantCapped.length, f.n, "length mismatch: cappedShort");

        // Every vector in this file is built on a zero-pressure config, so step 5
        // never spawns and the `spawns` arrays are all empty. A path that matches
        // nothing makes `vm.parseJson` return zero bytes — which is the assertion.
        assertEq(
            vm.parseJson(json, ".vectors[*].expected.spawns[*].slot").length,
            0,
            "this file must record no spawns: step 5 is meant to be inert here"
        );

        uint256 evOffset;
        for (uint256 i = 0; i < f.n; i++) {
            evOffset = _replay(f, i, evOffset);
        }
        assertEq(evOffset, f.wantEv.length, "the file records collapse events the library never produced");
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
        f.wantEv = VectorCodec.readCollapses(json, ".vectors[*].expected.events[*]");
        f.wantCapped = VectorCodec.readBools(json, ".vectors[*].expected.cappedShort");
    }

    function _set(PortalTypeParams[] memory tps, uint256 idx) private pure returns (PortalTypeParams[5] memory out) {
        for (uint256 i = 0; i < 5; i++) {
            out[i] = tps[idx * 5 + i];
        }
    }

    // ── replay ───────────────────────────────────────────────────────────────

    /// @dev Runs vector `i` and compares the whole result. The collapse events of
    /// all vectors sit in ONE flat column, so the caller threads a running offset
    /// through: vector `i` owns the `eventCount` entries starting at `evOffset`,
    /// and the final offset must land exactly on the column's end.
    function _replay(File memory f, uint256 i, uint256 evOffset) private pure returns (uint256) {
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
            ,
            uint8 spawnCount,
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

        assertEq(spawnCount, 0, string.concat("step 5 spawned at ", where));
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
        return evOffset + evN;
    }
}
