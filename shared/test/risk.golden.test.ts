import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { score, levelOf } from "../src/risk";

const VECTORS_PATH = fileURLToPath(new URL("vectors/risk-vectors.json", import.meta.url));

describe("golden vectors — TS mirror matches RiskLib output", () => {
    it("risk-vectors.json exists and every row matches", () => {
        if (!existsSync(VECTORS_PATH)) {
            throw new Error(
                "Golden vectors missing: run forge script script/GenRiskVectors.s.sol in contracts/"
            );
        }

        const data = JSON.parse(readFileSync(VECTORS_PATH, "utf8")) as {
            stability: number[];
            energy: number[];
            hours: number[];
            lives: number[];
            score: number[];
            level: number[];
        };

        const len = data.stability.length;
        expect(len).toBeGreaterThanOrEqual(1000);
        expect(data.energy.length).toBe(len);
        expect(data.hours.length).toBe(len);
        expect(data.lives.length).toBe(len);
        expect(data.score.length).toBe(len);
        expect(data.level.length).toBe(len);

        for (let i = 0; i < len; i++) {
            const s = score(data.stability[i], data.energy[i], data.hours[i], data.lives[i]);
            const lvl = levelOf(s);

            expect(s, `score mismatch at i=${i} stability=${data.stability[i]} energy=${data.energy[i]} hours=${data.hours[i]} lives=${data.lives[i]}`).toBe(data.score[i]);
            expect(lvl, `level mismatch at i=${i} stability=${data.stability[i]} energy=${data.energy[i]} hours=${data.hours[i]} lives=${data.lives[i]}`).toBe(data.level[i]);
        }
    });
});
