// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiskLib} from "../src/RiskLib.sol";
import {RiskLevel} from "../src/PortalLabTypes.sol";

/// @title RiskGoldenTest — verifies RiskLib against the pre-generated vector
/// file shared/test/vectors/risk-vectors.json. Run GenRiskVectors.s.sol first.
contract RiskGoldenTest is Test {
    function test_GoldenVectors() external {
        string memory json = vm.readFile("../shared/test/vectors/risk-vectors.json");

        uint256[] memory stab = vm.parseJsonUintArray(json, ".stability");
        uint256[] memory en = vm.parseJsonUintArray(json, ".energy");
        uint256[] memory hrs = vm.parseJsonUintArray(json, ".hours");
        uint256[] memory lv = vm.parseJsonUintArray(json, ".lives");
        uint256[] memory expectedScore = vm.parseJsonUintArray(json, ".score");
        uint256[] memory expectedLevel = vm.parseJsonUintArray(json, ".level");

        uint256 len = stab.length;
        assertEq(len, en.length, "length mismatch: energy");
        assertEq(len, hrs.length, "length mismatch: hours");
        assertEq(len, lv.length, "length mismatch: lives");
        assertEq(len, expectedScore.length, "length mismatch: score");
        assertEq(len, expectedLevel.length, "length mismatch: level");
        assertGe(len, 1000, "expected at least 1000 vectors");

        for (uint256 i = 0; i < len; i++) {
            uint8 s = RiskLib.score(uint8(stab[i]), uint8(en[i]), uint16(hrs[i]), uint8(lv[i]));
            RiskLevel lvl = RiskLib.levelOf(s);

            assertEq(
                s,
                uint8(expectedScore[i]),
                string.concat(
                    "score mismatch at i=", vm.toString(i),
                    " stability=", vm.toString(stab[i]),
                    " energy=", vm.toString(en[i]),
                    " hours=", vm.toString(hrs[i]),
                    " lives=", vm.toString(lv[i])
                )
            );
            assertEq(
                uint8(lvl),
                uint8(expectedLevel[i]),
                string.concat(
                    "level mismatch at i=", vm.toString(i),
                    " stability=", vm.toString(stab[i]),
                    " energy=", vm.toString(en[i]),
                    " hours=", vm.toString(hrs[i]),
                    " lives=", vm.toString(lv[i])
                )
            );
        }
    }
}
