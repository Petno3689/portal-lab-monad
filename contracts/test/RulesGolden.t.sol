// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RulesLib} from "../src/RulesLib.sol";
import {Game, Portal, Config, Action, Refusal} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";

/// @title RulesGoldenTest — verifies RulesLib against the pre-generated vector file
/// shared/test/vectors/rules-vectors.json (format: shared/test/support/vectorFormat.ts).
/// Run `forge script script/GenRulesVectors.s.sol` first. This test proves the file
/// has not drifted from the contract; the TS test proves the mirror matches the file.
contract RulesGoldenTest is Test {
    string private constant PATH = "../shared/test/vectors/rules-vectors.json";

    function test_GoldenVectors() external view {
        string memory json = vm.readFile(PATH);

        Config[] memory cfgs = VectorCodec.readConfigs(json, ".configs[*]");
        Game[] memory gs = VectorCodec.readGames(json, ".vectors[*].game");
        Portal[] memory ps = VectorCodec.readPortals(json, ".vectors[*].portal");
        uint256[] memory cfgIdx = abi.decode(vm.parseJson(json, ".vectors[*].config"), (uint256[]));
        uint256[] memory slots = abi.decode(vm.parseJson(json, ".vectors[*].slot"), (uint256[]));
        uint256[] memory actions = abi.decode(vm.parseJson(json, ".vectors[*].action"), (uint256[]));
        uint256[] memory wantRefusal = abi.decode(vm.parseJson(json, ".vectors[*].expected.refusal"), (uint256[]));
        uint256[] memory wantCost = abi.decode(vm.parseJson(json, ".vectors[*].expected.cost"), (uint256[]));

        uint256 n = gs.length;
        assertGe(n, 1000, "expected at least 1000 vectors");
        assertEq(ps.length, n, "length mismatch: portal");
        assertEq(cfgIdx.length, n, "length mismatch: config");
        assertEq(slots.length, n, "length mismatch: slot");
        assertEq(actions.length, n, "length mismatch: action");
        assertEq(wantRefusal.length, n, "length mismatch: refusal");
        assertEq(wantCost.length, n, "length mismatch: cost");

        bool[17] memory seenRefusal;
        bool[9] memory seenAction;

        for (uint256 i = 0; i < n; i++) {
            Config memory c = cfgs[cfgIdx[i]];
            Action a = Action(actions[i]);
            Refusal r = RulesLib.check(gs[i], ps[i], c, uint8(slots[i]), a);

            assertEq(
                uint8(r),
                uint8(wantRefusal[i]),
                string.concat("refusal mismatch at i=", vm.toString(i), " action=", vm.toString(actions[i]))
            );
            assertEq(
                uint256(RulesLib.cost(c, a)),
                wantCost[i],
                string.concat("cost mismatch at i=", vm.toString(i), " action=", vm.toString(actions[i]))
            );
            seenRefusal[uint8(r)] = true;
            seenAction[uint8(a)] = true;
        }

        // Coverage: every code the check can return, and every action, is in the set.
        // RandomnessTimeout is not a rule refusal — `check` never returns it.
        for (uint256 r = 0; r < 17; r++) {
            if (r == uint256(Refusal.RandomnessTimeout)) continue;
            assertTrue(seenRefusal[r], string.concat("refusal never exercised: ", vm.toString(r)));
        }
        for (uint256 a = 0; a < 9; a++) {
            assertTrue(seenAction[a], string.concat("action never exercised: ", vm.toString(a)));
        }
    }
}
