// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {Config} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "../test/utils/VectorCodec.sol";

/// @notice Generates the golden vectors for the TimeLib TS mirror (the two pure
/// helpers `epochSeed` and `spawnPressure`):
///   ../shared/test/vectors/time-vectors.json
/// Run from contracts/:  forge script script/GenTimeVectors.s.sol
/// No RPC, no broadcast.
///
/// File shape (same conventions as effects-vectors.json, see
/// shared/test/support/vectorFormat.ts):
///   { "configs": [...],
///     "epochSeed":     [ { label, word, epoch, expected: { seed } } ],
///     "spawnPressure": [ { label, a, b, config, expected: { pressure } } ] }
/// word / epoch / seed / pressure are uint256-wide and written as decimal STRINGS;
/// `a`, `b` are game hours (uint32 on chain) and plain numbers.
///
/// Coverage: every required case is registered by name (`_register`) and marked by
/// the vectors that reach it; the run aborts if any case is reached by none.
contract GenTimeVectors is Script {
    string private constant PATH = "../shared/test/vectors/time-vectors.json";

    uint256 private constant MAX32 = 4294967295;
    uint256 private constant RANDOM_WORDS = 8;
    uint256 private constant RANDOM_PRESSURE = 24;
    uint256 private constant CAPACITY = 128;

    struct SeedVec {
        string label;
        uint256 word;
        uint256 epoch;
        uint256 seed;
    }

    struct PressVec {
        string label;
        uint256 a;
        uint256 b;
        uint8 cfg;
        uint256 pressure;
    }

    struct Cov {
        string[] names;
        uint256[] counts;
        uint256 n;
    }

    function run() external {
        Config[] memory cfgs = _configs();

        SeedVec[] memory sv = new SeedVec[](CAPACITY);
        PressVec[] memory pv = new PressVec[](CAPACITY);
        uint256 nS = _buildSeeds(sv);
        uint256 nP = _buildPressure(pv);

        for (uint256 i = 0; i < nS; i++) {
            sv[i].seed = TimeLib.epochSeed(sv[i].word, sv[i].epoch);
        }
        for (uint256 i = 0; i < nP; i++) {
            pv[i].pressure = TimeLib.spawnPressure(pv[i].a, pv[i].b, cfgs[pv[i].cfg]);
            // The `/2` in the closed form stands on this invariant.
            if (pv[i].b > pv[i].a) {
                uint256 prod = (pv[i].a + pv[i].b - 1) * (pv[i].b - pv[i].a);
                require(prod % 2 == 0, string.concat("(a + b - 1) * n is odd for vector: ", pv[i].label));
            }
        }

        Cov memory cv = _register();
        _tagSeeds(cv, sv, nS);
        _tagPressure(cv, pv, nP, cfgs);
        _requireCoverage(cv);

        vm.writeFile(PATH, _head(cfgs));
        _writeSeeds(sv, nS);
        vm.writeLine(PATH, '],"spawnPressure":[');
        _writePressure(pv, nP);
        vm.writeLine(PATH, "]}");

        console.log("time vectors written (epochSeed / spawnPressure):", nS, nP);
        console.log("coverage (hits per case):");
        for (uint256 i = 0; i < cv.n; i++) {
            console.log(string.concat("  ", vm.toString(cv.counts[i]), "  ", cv.names[i]));
        }
    }

    // ── configs ──────────────────────────────────────────────────────────────

    /// @dev 0 — deployed; 1 — base 0; 2 — ramp 0; 3 — both 0; 4 — both uint32 max.
    function _configs() private pure returns (Config[] memory cfgs) {
        cfgs = new Config[](5);
        cfgs[0] = GameConfig.config();

        Config memory c1 = GameConfig.config();
        c1.basePressurePerHour = 0;
        cfgs[1] = c1;

        Config memory c2 = GameConfig.config();
        c2.pressureRampPerHour = 0;
        cfgs[2] = c2;

        Config memory c3 = GameConfig.config();
        c3.basePressurePerHour = 0;
        c3.pressureRampPerHour = 0;
        cfgs[3] = c3;

        Config memory c4 = GameConfig.config();
        c4.basePressurePerHour = uint32(MAX32);
        c4.pressureRampPerHour = uint32(MAX32);
        cfgs[4] = c4;
    }

    // ── inputs ───────────────────────────────────────────────────────────────

    function _r(uint256 i, string memory tag) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("portal-lab-time-v1", i, tag)));
    }

    function _s(SeedVec[] memory vs, uint256 n, string memory label, uint256 word, uint256 epoch)
        private
        pure
        returns (uint256)
    {
        vs[n].label = label;
        vs[n].word = word;
        vs[n].epoch = epoch;
        return n + 1;
    }

    function _buildSeeds(SeedVec[] memory vs) private pure returns (uint256 n) {
        uint256 maxWord = type(uint256).max;
        n = _s(vs, n, "word 0, epoch 0", 0, 0);
        n = _s(vs, n, "word 0, epoch 1", 0, 1);
        n = _s(vs, n, "word 0, epoch 12", 0, 12);
        n = _s(vs, n, "word 0, epoch uint32 max", 0, MAX32);
        n = _s(vs, n, "word uint256 max, epoch 0", maxWord, 0);
        n = _s(vs, n, "word uint256 max, epoch 1", maxWord, 1);
        n = _s(vs, n, "word uint256 max, epoch uint32 max", maxWord, MAX32);
        n = _s(vs, n, "word 1, epoch 0", 1, 0);
        n = _s(vs, n, "word 1, epoch 1", 1, 1);
        n = _s(vs, n, "word 22, epoch 22 (word == epoch)", 22, 22);
        // Same word, adjacent epochs: the seed must change.
        uint256 w = _r(900, "adjacent");
        n = _s(vs, n, "adjacent epochs, same word (epoch 41)", w, 41);
        n = _s(vs, n, "adjacent epochs, same word (epoch 42)", w, 42);
        n = _s(vs, n, "adjacent epochs, same word (epoch 43)", w, 43);
        for (uint256 i = 0; i < RANDOM_WORDS; i++) {
            n = _s(vs, n, "random", _r(i, "word"), _r(i, "epoch") % (MAX32 + 1));
        }
    }

    function _p(PressVec[] memory vs, uint256 n, string memory label, uint256 a, uint256 b, uint8 cfg)
        private
        pure
        returns (uint256)
    {
        vs[n].label = label;
        vs[n].a = a;
        vs[n].b = b;
        vs[n].cfg = cfg;
        return n + 1;
    }

    function _buildPressure(PressVec[] memory vs) private pure returns (uint256 n) {
        // Empty and degenerate windows.
        n = _p(vs, n, "b < a", 10, 3, 0);
        n = _p(vs, n, "b < a by one", 6, 5, 0);
        n = _p(vs, n, "b < a, a uint32 max, b 0", MAX32, 0, 0);
        n = _p(vs, n, "b == a", 10, 10, 0);
        n = _p(vs, n, "b == a == 0", 0, 0, 0);
        n = _p(vs, n, "b == a + 1", 7, 8, 0);
        n = _p(vs, n, "b == a + 1 from zero", 0, 1, 0);
        // Ordinary windows, even and odd length.
        n = _p(vs, n, "n even (2)", 3, 5, 0);
        n = _p(vs, n, "n even (100)", 100, 200, 0);
        n = _p(vs, n, "n odd (3)", 4, 7, 0);
        n = _p(vs, n, "n odd (101)", 100, 201, 0);
        n = _p(vs, n, "a = 0, n even", 0, 10, 0);
        n = _p(vs, n, "a = 0, n odd", 0, 11, 0);
        n = _p(vs, n, "a = 0, long window", 0, 1000, 0);
        // The uint32 ceiling.
        n = _p(vs, n, "a = 0, b uint32 max", 0, MAX32, 0);
        n = _p(vs, n, "a and b uint32 max", MAX32, MAX32, 0);
        n = _p(vs, n, "a = uint32 max - 1, b uint32 max", MAX32 - 1, MAX32, 0);
        n = _p(vs, n, "a = uint32 max - 2, b uint32 max", MAX32 - 2, MAX32, 0);
        n = _p(vs, n, "a = 1, b uint32 max (n even)", 1, MAX32, 0);
        // Configs with a zeroed term.
        n = _p(vs, n, "base 0, n even", 0, 24, 1);
        n = _p(vs, n, "base 0, n odd", 10, 35, 1);
        n = _p(vs, n, "ramp 0, n even", 0, 24, 2);
        n = _p(vs, n, "ramp 0, n odd", 10, 35, 2);
        n = _p(vs, n, "base 0 and ramp 0", 0, 24, 3);
        n = _p(vs, n, "base 0 and ramp 0, long", 5, 100000, 3);
        // Both coefficients at uint32 max: the result needs more than 64 bits.
        n = _p(vs, n, "max coefficients, a = 0, b uint32 max", 0, MAX32, 4);
        n = _p(vs, n, "max coefficients, last hour", MAX32 - 1, MAX32, 4);
        n = _p(vs, n, "max coefficients, b < a", 9, 2, 4);
        for (uint256 i = 0; i < RANDOM_PRESSURE; i++) {
            uint256 a = _r(i, "a") % (MAX32 + 1);
            uint256 b = _r(i, "b") % (MAX32 + 1);
            if (i % 3 == 0) b = a + _r(i, "len") % 5000 > MAX32 ? MAX32 : a + _r(i, "len") % 5000;
            n = _p(vs, n, "random", a, b, uint8(_r(i, "cfg") % 5));
        }
    }

    // ── coverage ─────────────────────────────────────────────────────────────

    function _reg(Cov memory cv, string memory name) private pure {
        cv.names[cv.n] = name;
        cv.n++;
    }

    function _register() private pure returns (Cov memory cv) {
        cv.names = new string[](40);
        cv.counts = new uint256[](40);

        _reg(cv, "epochSeed: word 0");
        _reg(cv, "epochSeed: word uint256 max");
        _reg(cv, "epochSeed: epoch 0");
        _reg(cv, "epochSeed: epoch 1");
        _reg(cv, "epochSeed: epoch uint32 max");
        _reg(cv, "epochSeed: at least three random words (above 2^128)");
        _reg(cv, "epochSeed: same word, adjacent epochs, seeds differ");

        _reg(cv, "spawnPressure: b < a");
        _reg(cv, "spawnPressure: b == a");
        _reg(cv, "spawnPressure: b == a + 1");
        _reg(cv, "spawnPressure: a == 0, b > a");
        _reg(cv, "spawnPressure: a and b both uint32 max");
        _reg(cv, "spawnPressure: b uint32 max, a below it");
        _reg(cv, "spawnPressure: n even");
        _reg(cv, "spawnPressure: n odd, n > 1");
        _reg(cv, "spawnPressure: basePressurePerHour == 0, n > 0");
        _reg(cv, "spawnPressure: pressureRampPerHour == 0, n > 0");
        _reg(cv, "spawnPressure: both coefficients 0, n > 0");
        _reg(cv, "spawnPressure: result needs more than 64 bits");
        _reg(cv, "spawnPressure: deployed config, nonzero result");
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
        revert(string.concat("unregistered coverage tag: ", name));
    }

    function _requireCoverage(Cov memory cv) private pure {
        for (uint256 i = 0; i < cv.n; i++) {
            require(cv.counts[i] > 0, string.concat("case not covered by any vector: ", cv.names[i]));
        }
    }

    function _tagSeeds(Cov memory cv, SeedVec[] memory vs, uint256 n) private pure {
        uint256 randoms;
        for (uint256 i = 0; i < n; i++) {
            SeedVec memory v = vs[i];
            _mark(cv, v.word == 0, "epochSeed: word 0");
            _mark(cv, v.word == type(uint256).max, "epochSeed: word uint256 max");
            _mark(cv, v.epoch == 0, "epochSeed: epoch 0");
            _mark(cv, v.epoch == 1, "epochSeed: epoch 1");
            _mark(cv, v.epoch == MAX32, "epochSeed: epoch uint32 max");
            if (v.word > type(uint128).max) randoms++;
            for (uint256 j = 0; j < n; j++) {
                _mark(
                    cv,
                    vs[j].word == v.word && vs[j].epoch == v.epoch + 1 && vs[j].seed != v.seed,
                    "epochSeed: same word, adjacent epochs, seeds differ"
                );
            }
        }
        _mark(cv, randoms >= 3, "epochSeed: at least three random words (above 2^128)");
    }

    function _tagPressure(Cov memory cv, PressVec[] memory vs, uint256 n, Config[] memory cfgs) private pure {
        for (uint256 i = 0; i < n; i++) {
            PressVec memory v = vs[i];
            Config memory c = cfgs[v.cfg];
            bool live = v.b > v.a;
            uint256 len = live ? v.b - v.a : 0;

            _mark(cv, v.b < v.a, "spawnPressure: b < a");
            _mark(cv, v.b == v.a, "spawnPressure: b == a");
            _mark(cv, v.b == v.a + 1, "spawnPressure: b == a + 1");
            _mark(cv, v.a == 0 && live, "spawnPressure: a == 0, b > a");
            _mark(cv, v.a == MAX32 && v.b == MAX32, "spawnPressure: a and b both uint32 max");
            _mark(cv, v.b == MAX32 && v.a < MAX32, "spawnPressure: b uint32 max, a below it");
            _mark(cv, live && len % 2 == 0, "spawnPressure: n even");
            _mark(cv, live && len % 2 == 1 && len > 1, "spawnPressure: n odd, n > 1");
            _mark(cv, live && c.basePressurePerHour == 0, "spawnPressure: basePressurePerHour == 0, n > 0");
            _mark(cv, live && c.pressureRampPerHour == 0, "spawnPressure: pressureRampPerHour == 0, n > 0");
            _mark(
                cv,
                live && c.basePressurePerHour == 0 && c.pressureRampPerHour == 0,
                "spawnPressure: both coefficients 0, n > 0"
            );
            _mark(cv, v.pressure > type(uint64).max, "spawnPressure: result needs more than 64 bits");
            _mark(cv, v.cfg == 0 && v.pressure > 0, "spawnPressure: deployed config, nonzero result");
        }
    }

    // ── output ───────────────────────────────────────────────────────────────

    function _head(Config[] memory cfgs) private pure returns (string memory) {
        string memory s = '{"configs":[';
        for (uint256 i = 0; i < cfgs.length; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.configJson(cfgs[i]));
        }
        return string.concat(s, '],"epochSeed":[');
    }

    function _writeSeeds(SeedVec[] memory vs, uint256 n) private {
        for (uint256 i = 0; i < n; i++) {
            // Rewind the free-memory pointer after each write (same idiom as
            // GenEffectsVectors._writeGroup): nothing built inside the iteration
            // is used after it.
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            vm.writeLine(PATH, _seedLine(vs[i], i + 1 == n));
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
        }
    }

    function _writePressure(PressVec[] memory vs, uint256 n) private {
        for (uint256 i = 0; i < n; i++) {
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            vm.writeLine(PATH, _pressureLine(vs[i], i + 1 == n));
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
        }
    }

    function _seedLine(SeedVec memory v, bool last) private pure returns (string memory) {
        return string.concat(
            '{"label":"', v.label, '",',
            VectorCodec.ks("word", v.word), ",",
            VectorCodec.ks("epoch", v.epoch), ",",
            '"expected":{', VectorCodec.ks("seed", v.seed), "}}",
            last ? "" : ","
        );
    }

    function _pressureLine(PressVec memory v, bool last) private pure returns (string memory) {
        return string.concat(
            '{"label":"', v.label, '",',
            VectorCodec.kv("a", v.a), ",",
            VectorCodec.kv("b", v.b), ",",
            VectorCodec.kv("config", v.cfg), ",",
            '"expected":{', VectorCodec.ks("pressure", v.pressure), "}}",
            last ? "" : ","
        );
    }
}
