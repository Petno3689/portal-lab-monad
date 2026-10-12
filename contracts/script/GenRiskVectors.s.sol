// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {RiskLib} from "../src/RiskLib.sol";
import {RiskLevel} from "../src/PortalLabTypes.sol";

/// @notice Generates risk-vectors.json with deterministic test vectors for the
/// TS mirror. Run once: `forge script script/GenRiskVectors.s.sol` from
/// contracts/. No RPC, no broadcast.
contract GenRiskVectors is Script {
    uint256 private constant RANDOM_COUNT = 1000;
    uint256 private constant EXPLICIT_COUNT = 24;

    struct Vecs {
        uint256[] stability;
        uint256[] energy;
        uint256[] hrs;
        uint256[] lives;
        uint256[] score;
        uint256[] level;
    }

    function run() external {
        uint256 n = RANDOM_COUNT + EXPLICIT_COUNT;
        Vecs memory v = Vecs({
            stability: new uint256[](n),
            energy: new uint256[](n),
            hrs: new uint256[](n),
            lives: new uint256[](n),
            score: new uint256[](n),
            level: new uint256[](n)
        });

        // 1 000 deterministic vectors: different byte ranges of the hash.
        for (uint256 i = 0; i < RANDOM_COUNT; i++) {
            uint256 x = uint256(keccak256(abi.encode("portal-lab-risk-v1", i)));
            uint8 st = uint8(x % 101);
            uint8 en = uint8((x >> 8) % 101);
            uint16 h = uint16((x >> 16) % 201);
            uint8 lv = uint8((x >> 32) % 11);
            v.stability[i] = st;
            v.energy[i] = en;
            v.hrs[i] = h;
            v.lives[i] = lv;
            uint8 s = RiskLib.score(st, en, h, lv);
            v.score[i] = s;
            v.level[i] = uint8(RiskLib.levelOf(s));
        }

        // Explicit vectors from RiskLib tests (ticket 1.2).
        uint256 j = RANDOM_COUNT;

        // Anchor cases.
        _fill(v, j, 100, 0, 48, 0); j++;
        _fill(v, j, 0, 100, 0, 5); j++;
        _fill(v, j, 50, 50, 24, 0); j++;
        _fill(v, j, 10, 80, 2, 3); j++;
        _fill(v, j, 40, 40, 6, 1); j++;

        // Level boundaries (no factors).
        _fill(v, j, 42, 0, 48, 0); j++;
        _fill(v, j, 40, 0, 48, 0); j++;
        _fill(v, j, 20, 62, 48, 0); j++;
        _fill(v, j, 20, 65, 48, 0); j++;
        _fill(v, j, 0, 83, 48, 0); j++;
        _fill(v, j, 0, 88, 48, 0); j++;

        // Exact halves (round-up boundary).
        _fill(v, j, 41, 0, 48, 0); j++;
        _fill(v, j, 20, 15, 12, 0); j++;
        _fill(v, j, 21, 100, 12, 0); j++;

        // Gate 84/85 with factors.
        _fill(v, j, 20, 37, 2, 0); j++;
        _fill(v, j, 20, 43, 2, 0); j++;
        _fill(v, j, 20, 64, 6, 1); j++;
        _fill(v, j, 20, 69, 6, 1); j++;
        _fill(v, j, 3, 0, 6, 1); j++;
        _fill(v, j, 0, 0, 6, 1); j++;

        // Hours beyond the 48-window.
        _fill(v, j, 100, 0, 60, 0); j++;
        _fill(v, j, 100, 0, 1000, 0); j++;

        // Mutation-check vectors (base rounding must be half-up).
        _fill(v, j, 20, 0, 14, 2); j++;
        _fill(v, j, 20, 75, 8, 2); j++;

        string memory obj = "v";
        vm.serializeUint(obj, "stability", v.stability);
        vm.serializeUint(obj, "energy", v.energy);
        vm.serializeUint(obj, "hours", v.hrs);
        vm.serializeUint(obj, "lives", v.lives);
        vm.serializeUint(obj, "score", v.score);
        string memory json = vm.serializeUint(obj, "level", v.level);

        vm.writeJson(json, "../shared/test/vectors/risk-vectors.json");
    }

    function _fill(Vecs memory v, uint256 i, uint8 st, uint8 en, uint16 h, uint8 lv) private pure {
        v.stability[i] = st;
        v.energy[i] = en;
        v.hrs[i] = h;
        v.lives[i] = lv;
        uint8 s = RiskLib.score(st, en, h, lv);
        v.score[i] = s;
        v.level[i] = uint8(RiskLib.levelOf(s));
    }
}
