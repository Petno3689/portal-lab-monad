import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { epochSeed, spawnPressure, wordFor } from "../src/time";
import { fromWord } from "../src/effects";
import { configFromJson, TimeVectorFile } from "./support/vectorFormat";

const VECTORS_PATH = fileURLToPath(new URL("vectors/time-vectors.json", import.meta.url));

describe("golden vectors — TS mirror matches TimeLib output", () => {
    if (!existsSync(VECTORS_PATH)) {
        throw new Error("time-vectors.json missing: run `forge script script/GenTimeVectors.s.sol` in contracts/");
    }
    const file = JSON.parse(readFileSync(VECTORS_PATH, "utf8")) as TimeVectorFile;
    const configs = file.configs.map(configFromJson);

    it("has both function groups, and enough vectors", () => {
        expect(file.epochSeed.length).toBeGreaterThanOrEqual(20);
        expect(file.spawnPressure.length).toBeGreaterThanOrEqual(30);
    });

    it("epochSeed matches on every vector", () => {
        file.epochSeed.forEach((v, i) => {
            const got = epochSeed(BigInt(v.word), BigInt(v.epoch));
            expect(got, `epochSeed i=${i} label="${v.label}"`).toBe(BigInt(v.expected.seed));
        });
    });

    it("epochSeed never equals keccak256(abi.encode(word, salt)) for salt 0..5", () => {
        file.epochSeed.forEach((v, i) => {
            const seed = epochSeed(BigInt(v.word), BigInt(v.epoch));
            for (let salt = 0n; salt <= 5n; salt++) {
                expect(seed, `epochSeed i=${i} label="${v.label}" salt=${salt}`).not.toBe(fromWord(BigInt(v.word), salt));
            }
        });
    });

    it("spawnPressure matches on every vector", () => {
        file.spawnPressure.forEach((v, i) => {
            const got = spawnPressure(BigInt(v.a), BigInt(v.b), configs[v.config]);
            expect(got, `spawnPressure i=${i} label="${v.label}"`).toBe(BigInt(v.expected.pressure));
        });
    });

    it("wordFor pins epochs below the split to the old word, the rest to the new one", () => {
        expect(wordFor(4n, 111n, 222n, 5n)).toBe(111n);
        expect(wordFor(5n, 111n, 222n, 5n)).toBe(222n);
        expect(wordFor(6n, 111n, 222n, 5n)).toBe(222n);
        expect(wordFor(0n, 111n, 222n, 0n)).toBe(222n);
    });
});
