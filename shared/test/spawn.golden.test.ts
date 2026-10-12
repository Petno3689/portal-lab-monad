import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { ContractRevert, PANIC_ARITHMETIC } from "../src/effects";
import { catchUp } from "../src/time";
import { MAX_OPEN_PORTALS } from "../src/types";
import {
    SpawnVectorFile,
    collapseFromJson,
    configFromJson,
    gameFromJson,
    portalFromJson,
    spawnFromJson,
    typeSetFromJson,
} from "./support/vectorFormat";

const VECTORS_PATH = fileURLToPath(new URL("vectors/spawn-vectors.json", import.meta.url));

describe("golden vectors — TS mirror matches TimeLib.catchUp step 5 (pressure and spawns)", () => {
    if (!existsSync(VECTORS_PATH)) {
        throw new Error("spawn-vectors.json missing: run `forge script script/GenSpawnVectors.s.sol` in contracts/");
    }
    const file = JSON.parse(readFileSync(VECTORS_PATH, "utf8")) as SpawnVectorFile;
    const configs = file.configs.map(configFromJson);

    type Row = SpawnVectorFile["vectors"][number] | SpawnVectorFile["refusals"][number];

    const run = (v: Row) =>
        catchUp(
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

    it("has enough vectors, each carrying a full twelve-portal world", () => {
        expect(file.vectors.length).toBeGreaterThanOrEqual(40);
        expect(file.refusals.length).toBeGreaterThanOrEqual(3);
        expect(file.configs.length).toBeGreaterThan(0);
        expect(file.typeParams.length % 5).toBe(0);
        [...file.vectors, ...file.refusals].forEach((v, i) => {
            expect(BigInt(v.portalsIn.length), `portalsIn at i=${i}`).toBe(MAX_OPEN_PORTALS);
            expect(v.types * 5 + 5, `types index at i=${i}`).toBeLessThanOrEqual(file.typeParams.length);
        });
        file.vectors.forEach((v, i) => {
            expect(BigInt(v.expected.portalsOut.length), `portalsOut at i=${i}`).toBe(MAX_OPEN_PORTALS);
        });
    });

    // `toEqual` on bigint-valued objects prints the differing field, which is what
    // a failed vector needs. Every field of the game and of all twelve portals is
    // compared, plus every collapse and every spawn — a selection would be a hole
    // that looks like a green test.
    it("catchUp matches on every vector (game, all twelve portals, events, spawns, cappedShort)", () => {
        file.vectors.forEach((v, i) => {
            const where = `i=${i} label="${v.label}"`;
            const got = run(v);
            expect(got.game, `game at ${where}`).toEqual(gameFromJson(v.expected.game));
            expect(got.portals, `portals at ${where}`).toEqual(v.expected.portalsOut.map(portalFromJson));
            expect(got.events, `events at ${where}`).toEqual(v.expected.events.map(collapseFromJson));
            expect(got.spawns, `spawns at ${where}`).toEqual(v.expected.spawns.map(spawnFromJson));
            expect(got.cappedShort, `cappedShort at ${where}`).toBe(v.expected.cappedShort);
        });
    });

    it("this file is about step 5: the corpus really does spawn, in both branches", () => {
        const total = file.vectors.reduce((n, v) => n + v.expected.spawns.length, 0);
        expect(total).toBeGreaterThanOrEqual(20);
        const spawned = file.vectors.filter((v) => v.expected.spawns.length > 0);
        expect(spawned.some((v) => (v.expected.game as { finished: boolean }).finished)).toBe(true);
        expect(spawned.some((v) => !(v.expected.game as { finished: boolean }).finished)).toBe(true);
        // Pressure is the whole point, so no vector may be a zero-pressure config.
        file.vectors.forEach((v, i) => {
            const c = configs[v.config];
            expect(c.basePressurePerHour + c.pressureRampPerHour, `pressure at i=${i}`).toBeGreaterThan(0n);
        });
    });

    it("falls over exactly where the contract panics, and with the same revert", () => {
        file.refusals.forEach((v, i) => {
            const where = `refusal i=${i} label="${v.label}"`;
            expect(v.expected.reverted, `a refusal row must expect a revert at ${where}`).toBe(true);
            let caught: unknown;
            try {
                run(v);
            } catch (e) {
                caught = e;
            }
            expect(caught, `the mirror returned a value where the contract reverts, at ${where}`).toBeInstanceOf(
                ContractRevert,
            );
            // Not merely "it threw": the SAME kind of revert.
            expect((caught as ContractRevert).error, `revert kind at ${where}`).toBe(v.expected.error);
        });
        // The one kind this file records, named here so a new one cannot slip in
        // unnoticed.
        expect([...new Set(file.refusals.map((v) => v.expected.error))]).toEqual([PANIC_ARITHMETIC]);
    });

    it("the mirror does not mutate its inputs, spawns and all", () => {
        // A vector that actually spawns, so an in-place implementation would be
        // caught: the one with the most spawns.
        let pick = 0;
        file.vectors.forEach((v, i) => {
            if (v.expected.spawns.length > file.vectors[pick].expected.spawns.length) pick = i;
        });
        const v = file.vectors[pick];
        expect(v.expected.spawns.length).toBeGreaterThan(0);

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
});
