import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { catchUp } from "../src/time";
import { MAX_OPEN_PORTALS } from "../src/types";
import {
    CatchUpVectorFile,
    collapseFromJson,
    configFromJson,
    gameFromJson,
    portalFromJson,
    typeSetFromJson,
} from "./support/vectorFormat";

const VECTORS_PATH = fileURLToPath(new URL("vectors/catchup-vectors.json", import.meta.url));

describe("golden vectors — TS mirror matches TimeLib.catchUp output", () => {
    if (!existsSync(VECTORS_PATH)) {
        throw new Error("catchup-vectors.json missing: run `forge script script/GenCatchUpVectors.s.sol` in contracts/");
    }
    const file = JSON.parse(readFileSync(VECTORS_PATH, "utf8")) as CatchUpVectorFile;
    const configs = file.configs.map(configFromJson);

    const run = (i: number) => {
        const v = file.vectors[i];
        return catchUp(
            gameFromJson(v.game),
            v.portalsIn.map(portalFromJson),
            configs[v.config],
            typeSetFromJson(file.typeParams, v.types),
            BigInt(v.oldWord),
            BigInt(v.newWord),
            BigInt(v.storedCoveredEpochs),
            BigInt(v.maxCoveredEpochs),
            BigInt(v.nowTs),
        );
    };

    it("has enough vectors, each carrying a full twelve-portal world", () => {
        expect(file.vectors.length).toBeGreaterThanOrEqual(40);
        expect(file.configs.length).toBeGreaterThan(0);
        expect(file.typeParams.length % 5).toBe(0);
        file.vectors.forEach((v, i) => {
            expect(BigInt(v.portalsIn.length), `portalsIn at i=${i}`).toBe(MAX_OPEN_PORTALS);
            expect(BigInt(v.expected.portalsOut.length), `portalsOut at i=${i}`).toBe(MAX_OPEN_PORTALS);
            expect(v.types * 5 + 5, `types index at i=${i}`).toBeLessThanOrEqual(file.typeParams.length);
        });
    });

    // `toEqual` on bigint-valued objects prints the differing field, which is what
    // a failed vector needs. Every field of the game and of all twelve portals is
    // compared — a selection would be a hole that looks like a green test.
    it("catchUp matches on every vector (game, all twelve portals, events, spawns, cappedShort)", () => {
        file.vectors.forEach((v, i) => {
            const where = `i=${i} label="${v.label}"`;
            const got = run(i);
            expect(got.game, `game at ${where}`).toEqual(gameFromJson(v.expected.game));
            expect(got.portals, `portals at ${where}`).toEqual(v.expected.portalsOut.map(portalFromJson));
            expect(got.events, `events at ${where}`).toEqual(v.expected.events.map(collapseFromJson));
            expect(got.spawns, `spawns at ${where}`).toEqual([]);
            expect(got.cappedShort, `cappedShort at ${where}`).toBe(v.expected.cappedShort);
        });
    });

    it("the file records no spawns at all: step 5 is inert on these configs", () => {
        const total = file.vectors.reduce((n, v) => n + v.expected.spawns.length, 0);
        expect(total).toBe(0);
        file.vectors.forEach((v, i) => {
            const c = configs[v.config];
            expect(c.basePressurePerHour, `basePressurePerHour at i=${i}`).toBe(0n);
            expect(c.pressureRampPerHour, `pressureRampPerHour at i=${i}`).toBe(0n);
            expect(gameFromJson(v.game).spawnDebt, `spawnDebt at i=${i}`).toBe(0n);
        });
    });

    it("the mirror does not mutate its inputs", () => {
        // A vector whose world actually moves, so an in-place implementation would
        // be caught: the one with the most collapses.
        let pick = 0;
        file.vectors.forEach((v, i) => {
            if (v.expected.events.length > file.vectors[pick].expected.events.length) pick = i;
        });
        const v = file.vectors[pick];
        expect(v.expected.events.length).toBeGreaterThan(0);

        const g = gameFromJson(v.game);
        const ps = v.portalsIn.map(portalFromJson);
        catchUp(
            g,
            ps,
            configs[v.config],
            typeSetFromJson(file.typeParams, v.types),
            BigInt(v.oldWord),
            BigInt(v.newWord),
            BigInt(v.storedCoveredEpochs),
            BigInt(v.maxCoveredEpochs),
            BigInt(v.nowTs),
        );
        expect(g).toEqual(gameFromJson(v.game));
        expect(ps).toEqual(v.portalsIn.map(portalFromJson));
    });

    it("rejects a world that is not twelve portals wide", () => {
        const v = file.vectors[0];
        const args = [
            configs[v.config],
            typeSetFromJson(file.typeParams, v.types),
            BigInt(v.oldWord),
            BigInt(v.newWord),
            BigInt(v.storedCoveredEpochs),
            BigInt(v.maxCoveredEpochs),
            BigInt(v.nowTs),
        ] as const;
        expect(() => catchUp(gameFromJson(v.game), v.portalsIn.map(portalFromJson).slice(0, 11), ...args)).toThrow(
            /expected 12 portals/,
        );
        expect(() =>
            catchUp(
                gameFromJson(v.game),
                v.portalsIn.map(portalFromJson),
                configs[v.config],
                typeSetFromJson(file.typeParams, v.types).slice(0, 4),
                BigInt(v.oldWord),
                BigInt(v.newWord),
                BigInt(v.storedCoveredEpochs),
                BigInt(v.maxCoveredEpochs),
                BigInt(v.nowTs),
            ),
        ).toThrow(/expected 5 PortalTypeParams/);
    });
});
