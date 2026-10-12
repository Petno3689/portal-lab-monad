// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {Config} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "./utils/VectorCodec.sol";

/// @title TimeSeedGoldenTest — verifies TimeLib.epochSeed / spawnPressure against the
/// pre-generated file shared/test/vectors/time-vectors.json.
/// Run `forge script script/GenTimeVectors.s.sol` first. This test proves the file has
/// not drifted from the contract; the TS test proves the mirror matches the file.
contract TimeSeedGoldenTest is Test {
    string private constant PATH = "../shared/test/vectors/time-vectors.json";

    function _word(string memory json, string memory path) private pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function test_EpochSeedGolden() external view {
        string memory json = vm.readFile(PATH);
        uint256 n = abi.decode(vm.parseJson(json, ".epochSeed[*].label"), (string[])).length;
        assertGe(n, 20, "too few epochSeed vectors");

        for (uint256 i = 0; i < n; i++) {
            string memory row = string.concat(".epochSeed[", vm.toString(i), "]");
            uint256 word = _word(json, string.concat(row, ".word"));
            uint256 epoch = _word(json, string.concat(row, ".epoch"));
            uint256 want = _word(json, string.concat(row, ".expected.seed"));
            string memory where = string.concat("epochSeed i=", vm.toString(i));

            uint256 got = TimeLib.epochSeed(word, epoch);
            assertEq(got, want, string.concat("seed mismatch at ", where));

            // Domain separation: never a survey draw keccak256(abi.encode(word, salt)).
            for (uint256 salt = 0; salt <= 5; salt++) {
                assertTrue(
                    got != uint256(keccak256(abi.encode(word, uint8(salt)))),
                    string.concat("epoch seed equals a salt-draw at ", where)
                );
            }
        }
    }

    function test_SpawnPressureGolden() external view {
        string memory json = vm.readFile(PATH);
        Config[] memory cfgs = VectorCodec.readConfigs(json, ".configs[*]");
        uint256[] memory as_ = VectorCodec.readUints(json, ".spawnPressure[*].a");
        uint256[] memory bs = VectorCodec.readUints(json, ".spawnPressure[*].b");
        uint256[] memory cfgIdx = VectorCodec.readUints(json, ".spawnPressure[*].config");
        uint256 n = as_.length;
        assertGe(n, 30, "too few spawnPressure vectors");
        assertEq(bs.length, n, "length mismatch: b");
        assertEq(cfgIdx.length, n, "length mismatch: config");

        for (uint256 i = 0; i < n; i++) {
            string memory path = string.concat(".spawnPressure[", vm.toString(i), "].expected.pressure");
            uint256 want = _word(json, path);
            uint256 got = TimeLib.spawnPressure(as_[i], bs[i], cfgs[cfgIdx[i]]);
            assertEq(got, want, string.concat("pressure mismatch at spawnPressure i=", vm.toString(i)));
        }
    }
}
