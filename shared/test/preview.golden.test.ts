import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { preview, StoredPlayer } from "../src/preview";
import { MAX_OPEN_PORTALS } from "../src/types";
import {
    PreviewVectorFile,
    configFromJson,
    gameFromJson,
    portalFromJson,
    typeSetFromJson,
} from "./support/vectorFormat";

const VECTORS_PATH = fileURLToPath(new URL("vectors/preview-vectors.json", import.meta.url));

describe("golden vectors — TS mirror matches PortalLab.preview output", () => {
    if (!existsSync(VECTORS_PATH)) {
        throw new Error(
            "preview-vectors.json missing: run `forge script script/GenPreviewVectors.s.sol` in contracts/",
        );
    }
    const file = JSON.parse(readFileSync(VECTORS_PATH, "utf8")) as PreviewVectorFile;
    const configs = file.configs.map(configFromJson);

    const storedOf = (i: number): StoredPlayer => {
        const v = file.vectors[i];
        return {
            game: gameFromJson(v.game),
            portals: v.portalsIn.map(portalFromJson),
            epochWord: BigInt(v.epochWord),
            coveredEpochs: BigInt(v.coveredEpochs),
        };
    };

    const run = (i: number) => {
        const v = file.vectors[i];
        return preview(
            storedOf(i),
            configs[v.config],
            typeSetFromJson(file.typeParams, v.types),
            BigInt(v.nowTs),
        );
    };

    it("has enough vectors, each carrying a full twelve-portal world", () => {
        expect(file.vectors.length).toBeGreaterThanOrEqual(40);
        expect(file.configs.length).toBe(1);
        expect(file.typeParams.length).toBe(5);
        file.vectors.forEach((v, i) => {
            expect(BigInt(v.portalsIn.length), `portalsIn at i=${i}`).toBe(MAX_OPEN_PORTALS);
            expect(BigInt(v.expected.portalsOut.length), `portalsOut at i=${i}`).toBe(MAX_OPEN_PORTALS);
            expect(v.config, `config index at i=${i}`).toBe(0);
            expect(v.types, `types index at i=${i}`).toBe(0);
        });
    });

    // `toEqual` on bigint-valued objects prints the differing field, which is what
    // a failed vector needs. Every field of the game and of all twelve portals is
    // compared — a selection would be a hole that looks like a green test.
    it("preview matches on every vector (game, all twelve portals, cappedShort)", () => {
        file.vectors.forEach((v, i) => {
            const where = `i=${i} label="${v.label}"`;
            const got = run(i);
            expect(got.game, `game at ${where}`).toEqual(gameFromJson(v.expected.game));
            expect(got.portals, `portals at ${where}`).toEqual(v.expected.portalsOut.map(portalFromJson));
            expect(got.cappedShort, `cappedShort at ${where}`).toBe(v.expected.cappedShort);
        });
    });

    // The corpus is meant to span the states the ticket lists. Forty copies of one
    // trivial row would satisfy the comparison above and prove nothing, so the
    // span itself is asserted — on the file, not on the mirror.
    it("the corpus spans the states it is supposed to", () => {
        const out = file.vectors.map((v) => ({
            game: gameFromJson(v.expected.game),
            portals: v.expected.portalsOut.map(portalFromJson),
            covered: BigInt(v.coveredEpochs),
            word: BigInt(v.epochWord),
            capped: v.expected.cappedShort,
        }));

        expect(out.some((o) => o.capped), "a projection that stops at the pinned edge").toBe(true);
        expect(out.some((o) => !o.capped), "a projection that reaches its moment").toBe(true);
        expect(out.some((o) => o.covered === 0n), "an unpinned world").toBe(true);
        expect(out.some((o) => o.covered > 0n), "a pinned world").toBe(true);
        expect(out.some((o) => o.word === 0n), "a world with no word yet").toBe(true);
        expect(out.some((o) => o.word !== 0n), "a world with a word").toBe(true);
        expect(out.some((o) => o.game.openPortals === 1n), "exactly one open portal").toBe(true);
        expect(out.some((o) => o.game.openPortals > 1n), "several open portals").toBe(true);
        expect(out.some((o) => o.game.finished && !o.game.settled), "a dead run").toBe(true);
        expect(out.some((o) => o.game.finished && o.game.settled), "a settled run").toBe(true);
        expect(
            out.some(
                (o) =>
                    o.game.rescuerReadyAt0 !== 0n ||
                    o.game.rescuerReadyAt1 !== 0n ||
                    o.game.rescuerReadyAt2 !== 0n ||
                    o.game.rescuerReadyAt3 !== 0n,
            ),
            "a rescuer in cooldown",
        ).toBe(true);
        expect(out.some((o) => o.portals.some((p) => p.surveyed)), "a surveyed portal").toBe(true);
        expect(
            out.some((o) => o.portals.some((p) => p.status !== 0 && !p.surveyed)),
            "an unsurveyed portal",
        ).toBe(true);
        expect(
            out.some((o) => o.portals.some((p) => p.observerInside && p.rescuerInside)),
            "an observer and a rescuer in one portal",
        ).toBe(true);
        expect(out.some((o) => o.portals.some((p) => p.surveyPending)), "a survey still in flight").toBe(
            true,
        );
    });

    // A projection asked for the moment the world was already stamped at must
    // return that world untouched. The file holds such vectors by construction
    // (the "stored mark" moment); this pins the behaviour rather than the file.
    it("a projection onto the stored mark leaves a living world alone", () => {
        let seen = 0;
        file.vectors.forEach((v, i) => {
            const stored = storedOf(i);
            if (BigInt(v.nowTs) !== stored.game.lastTickAt) return;
            if (stored.game.finished) return;
            const got = run(i);
            if (got.game.hoursElapsed !== stored.game.hoursElapsed) return;
            expect(got.game, `game at i=${i}`).toEqual(stored.game);
            expect(got.portals, `portals at i=${i}`).toEqual(stored.portals);
            expect(got.cappedShort, `cappedShort at i=${i}`).toBe(false);
            seen += 1;
        });
        expect(seen, "no vector projects a living world onto its own stored mark").toBeGreaterThan(0);
    });

    it("the mirror does not mutate its inputs", () => {
        // A vector whose world actually moves, so an in-place implementation would
        // be caught: pick the one that advances the most game hours.
        let pick = 0;
        let best = -1n;
        file.vectors.forEach((v, i) => {
            const moved = gameFromJson(v.expected.game).hoursElapsed - gameFromJson(v.game).hoursElapsed;
            if (moved > best) {
                best = moved;
                pick = i;
            }
        });
        expect(best).toBeGreaterThan(0n);

        const v = file.vectors[pick];
        const stored = storedOf(pick);
        preview(stored, configs[v.config], typeSetFromJson(file.typeParams, v.types), BigInt(v.nowTs));
        expect(stored.game).toEqual(gameFromJson(v.game));
        expect(stored.portals).toEqual(v.portalsIn.map(portalFromJson));
    });

    it("rejects a world that is not twelve portals wide", () => {
        const v = file.vectors[0];
        const stored = storedOf(0);
        expect(() =>
            preview(
                { ...stored, portals: stored.portals.slice(0, 11) },
                configs[v.config],
                typeSetFromJson(file.typeParams, v.types),
                BigInt(v.nowTs),
            ),
        ).toThrow(/expected 12 portals/);
        expect(() =>
            preview(
                stored,
                configs[v.config],
                typeSetFromJson(file.typeParams, v.types).slice(0, 4),
                BigInt(v.nowTs),
            ),
        ).toThrow(/expected 5 PortalTypeParams/);
    });
});
