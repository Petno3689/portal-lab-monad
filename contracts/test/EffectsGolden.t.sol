// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EffectsLib} from "../src/EffectsLib.sol";
import {Game, Portal, Config, PortalTypeParams, Action} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";
import {EffectsHarness} from "./utils/EffectsHarness.sol";

/// @title EffectsGoldenTest — verifies EffectsLib against the pre-generated vector file
/// shared/test/vectors/effects-vectors.json (format: shared/test/support/vectorFormat.ts).
/// Run `forge script script/GenEffectsVectors.s.sol` first. This test proves the file
/// has not drifted from the contract; the TS test proves the mirror matches the file.
///
/// Every call goes through EffectsHarness so that a revert is catchable and the
/// library's in-place mutation cannot leak into the vector inputs.
contract EffectsGoldenTest is Test {
    string private constant PATH = "../shared/test/vectors/effects-vectors.json";

    EffectsHarness private h;
    Config[] private cfgs;
    PortalTypeParams[] private tps;

    uint256 private sawNoFreeCell;
    uint256 private sawPanic;

    function setUp() public {
        h = new EffectsHarness();
    }

    function test_GoldenVectors() external {
        string memory json = vm.readFile(PATH);
        Config[] memory cs = VectorCodec.readConfigs(json, ".configs[*]");
        PortalTypeParams[] memory ts = VectorCodec.readTypeParams(json, ".typeParams[*]");
        for (uint256 i = 0; i < cs.length; i++) {
            cfgs.push(cs[i]);
        }
        for (uint256 i = 0; i < ts.length; i++) {
            tps.push(ts[i]);
        }

        uint256 nApply = _applyAction(json);
        uint256 nSurvey = _survey(json);
        uint256 nReveal = _reveal(json);

        assertGe(nApply + nSurvey + nReveal, 400, "expected at least 400 vectors");
        assertGt(sawNoFreeCell, 0, "no NoFreeRescuerCell revert in the set");
        assertGt(sawPanic, 0, "no Panic(0x11) revert in the set");
    }

    function _sameGame(Game memory a, Game memory b) private pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _samePortal(Portal memory a, Portal memory b) private pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _sameOutcome(EffectsLib.Outcome memory a, EffectsLib.Outcome memory b) private pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    /// @dev Compares a call's revert (or not) with the recorded one. Returns true when
    /// the row is a revert row and was verified, so the caller skips the state check.
    function _checkRevert(bool want, string memory wantErr, bool got, bytes memory err, string memory where)
        private
        returns (bool)
    {
        assertEq(got, want, string.concat("revert flag mismatch at ", where));
        if (!got) return false;
        string memory name = VectorCodec.errorName(err);
        assertEq(name, wantErr, string.concat("revert kind mismatch at ", where));
        if (keccak256(bytes(name)) == keccak256(bytes("NoFreeRescuerCell"))) sawNoFreeCell++;
        else sawPanic++;
        return true;
    }

    function _applyAction(string memory json) private returns (uint256 n) {
        Game[] memory gs = VectorCodec.readGames(json, ".applyAction[*].game");
        Portal[] memory ps = VectorCodec.readPortals(json, ".applyAction[*].portal");
        uint256[] memory cfgIdx = VectorCodec.readUints(json, ".applyAction[*].config");
        uint256[] memory tpIdx = VectorCodec.readUints(json, ".applyAction[*].tp");
        uint256[] memory actions = VectorCodec.readUints(json, ".applyAction[*].action");
        bool[] memory wantRev = VectorCodec.readBools(json, ".applyAction[*].expected.reverted");
        string[] memory wantErr = VectorCodec.readStrings(json, ".applyAction[*].expected.error");
        Game[] memory wantG = VectorCodec.readGames(json, ".applyAction[*].expected.game");
        Portal[] memory wantP = VectorCodec.readPortals(json, ".applyAction[*].expected.portal");
        EffectsLib.Outcome[] memory wantO = VectorCodec.readOutcomes(json, ".applyAction[*].expected.outcome");

        n = gs.length;
        assertGe(n, 100, "too few applyAction vectors");
        assertEq(ps.length, n, "length mismatch: portal");
        assertEq(wantRev.length, n, "length mismatch: reverted");
        assertEq(wantG.length, n, "length mismatch: expected game");
        assertEq(wantO.length, n, "length mismatch: expected outcome");

        bool[9] memory seenAction;
        for (uint256 i = 0; i < n; i++) {
            string memory where = string.concat("applyAction i=", vm.toString(i), " action=", vm.toString(actions[i]));
            seenAction[actions[i]] = true;
            try h.applyAction(gs[i], ps[i], cfgs[cfgIdx[i]], tps[tpIdx[i]], Action(actions[i])) returns (
                Game memory g2, Portal memory p2, EffectsLib.Outcome memory o2
            ) {
                _checkRevert(wantRev[i], wantErr[i], false, "", where);
                _assertState(g2, p2, o2, wantG[i], wantP[i], wantO[i], where);
            } catch (bytes memory err) {
                _checkRevert(wantRev[i], wantErr[i], true, err, where);
            }
        }
        for (uint256 a = 0; a < 9; a++) {
            assertTrue(seenAction[a], string.concat("action never exercised: ", vm.toString(a)));
        }
    }

    function _assertState(
        Game memory g2,
        Portal memory p2,
        EffectsLib.Outcome memory o2,
        Game memory wantG,
        Portal memory wantP,
        EffectsLib.Outcome memory wantO,
        string memory where
    ) private pure {
        if (!_sameGame(g2, wantG)) {
            assertEq(VectorCodec.gameJson(g2), VectorCodec.gameJson(wantG), string.concat("game mismatch at ", where));
        }
        if (!_samePortal(p2, wantP)) {
            assertEq(VectorCodec.portalJson(p2), VectorCodec.portalJson(wantP), string.concat("portal mismatch at ", where));
        }
        if (!_sameOutcome(o2, wantO)) {
            assertEq(VectorCodec.outcomeJson(o2), VectorCodec.outcomeJson(wantO), string.concat("outcome mismatch at ", where));
        }
    }

    function _survey(string memory json) private returns (uint256 n) {
        Portal[] memory ps = VectorCodec.readPortals(json, ".survey[*].portal");
        uint256[] memory cfgIdx = VectorCodec.readUints(json, ".survey[*].config");
        uint256[] memory tpIdx = VectorCodec.readUints(json, ".survey[*].tp");
        uint256[] memory words = VectorCodec.readWords(json, ".survey", ps.length);
        bool[] memory wantRev = VectorCodec.readBools(json, ".survey[*].expected.reverted");
        string[] memory wantErr = VectorCodec.readStrings(json, ".survey[*].expected.error");
        Portal[] memory wantP = VectorCodec.readPortals(json, ".survey[*].expected.portal");
        bool[] memory wantPrecise = VectorCodec.readBools(json, ".survey[*].expected.precise");

        n = ps.length;
        assertGe(n, 30, "too few survey vectors");
        assertEq(words.length, n, "length mismatch: word");
        assertEq(wantP.length, n, "length mismatch: expected portal");

        bool sawPrecise;
        bool sawNarrow;
        for (uint256 i = 0; i < n; i++) {
            string memory where = string.concat("survey i=", vm.toString(i));
            try h.survey(ps[i], cfgs[cfgIdx[i]], tps[tpIdx[i]], words[i]) returns (Portal memory p2, bool precise) {
                _checkRevert(wantRev[i], wantErr[i], false, "", where);
                if (!_samePortal(p2, wantP[i])) {
                    assertEq(VectorCodec.portalJson(p2), VectorCodec.portalJson(wantP[i]), string.concat("portal mismatch at ", where));
                }
                assertEq(precise, wantPrecise[i], string.concat("precise mismatch at ", where));
                if (precise) sawPrecise = true;
                else sawNarrow = true;
            } catch (bytes memory err) {
                _checkRevert(wantRev[i], wantErr[i], true, err, where);
            }
        }
        assertTrue(sawPrecise && sawNarrow, "survey: both exact and narrowing results must appear");
    }

    function _reveal(string memory json) private returns (uint256 n) {
        Game[] memory gs = VectorCodec.readGames(json, ".blindReveal[*].game");
        Portal[] memory ps = VectorCodec.readPortals(json, ".blindReveal[*].portal");
        uint256[] memory cfgIdx = VectorCodec.readUints(json, ".blindReveal[*].config");
        uint256[] memory words = VectorCodec.readWords(json, ".blindReveal", gs.length);
        bool[] memory wantRev = VectorCodec.readBools(json, ".blindReveal[*].expected.reverted");
        string[] memory wantErr = VectorCodec.readStrings(json, ".blindReveal[*].expected.error");
        Game[] memory wantG = VectorCodec.readGames(json, ".blindReveal[*].expected.game");
        Portal[] memory wantP = VectorCodec.readPortals(json, ".blindReveal[*].expected.portal");
        EffectsLib.Outcome[] memory wantO = VectorCodec.readOutcomes(json, ".blindReveal[*].expected.outcome");

        n = gs.length;
        assertGe(n, 20, "too few blindReveal vectors");
        assertEq(words.length, n, "length mismatch: word");
        assertEq(wantO.length, n, "length mismatch: expected outcome");

        bool sawMiss;
        bool sawEnter;
        for (uint256 i = 0; i < n; i++) {
            string memory where = string.concat("blindReveal i=", vm.toString(i));
            try h.applyBlindRescuerReveal(gs[i], ps[i], cfgs[cfgIdx[i]], words[i]) returns (
                Game memory g2, Portal memory p2, EffectsLib.Outcome memory o2
            ) {
                _checkRevert(wantRev[i], wantErr[i], false, "", where);
                _assertState(g2, p2, o2, wantG[i], wantP[i], wantO[i], where);
                if (o2.rescuerBlindMiss) sawMiss = true;
                else sawEnter = true;
            } catch (bytes memory err) {
                _checkRevert(wantRev[i], wantErr[i], true, err, where);
            }
        }
        assertTrue(sawMiss && sawEnter, "blindReveal: both a miss and an entry must appear");
    }
}
