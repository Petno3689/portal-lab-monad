import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
    applyAction,
    applyBlindRescuerReveal,
    ContractRevert,
    Outcome,
    survey,
    NO_FREE_RESCUER_CELL,
    PANIC_ARITHMETIC,
} from "../src/effects";
import { Action, Game, Portal } from "../src/types";
import {
    configFromJson,
    EffectsVectorFile,
    gameFromJson,
    outcomeFromJson,
    portalFromJson,
    typeParamsFromJson,
} from "./support/vectorFormat";

const VECTORS_PATH = fileURLToPath(new URL("vectors/effects-vectors.json", import.meta.url));

describe("golden vectors — TS mirror matches EffectsLib output", () => {
    if (!existsSync(VECTORS_PATH)) {
        throw new Error("effects-vectors.json missing: run `forge script script/GenEffectsVectors.s.sol` in contracts/");
    }
    const file = JSON.parse(readFileSync(VECTORS_PATH, "utf8")) as EffectsVectorFile;
    const configs = file.configs.map(configFromJson);
    const typeParams = file.typeParams.map(typeParamsFromJson);

    /** Runs `f`; returns its value, or the name of the revert it threw. */
    function attempt<T>(f: () => T): { value: T } | { reverted: string } {
        try {
            return { value: f() };
        } catch (e) {
            if (e instanceof ContractRevert) return { reverted: e.error };
            throw e; // a TypeError or similar is a bug in the mirror, not a contract revert
        }
    }

    /** Asserts revert-or-not exactly as recorded; returns the value when none is expected. */
    function expectRevertState<T>(
        got: { value: T } | { reverted: string },
        want: { reverted: boolean; error: string },
        where: string,
    ): T | undefined {
        if (want.reverted) {
            expect(got, `mirror returned a value where the contract reverts (${want.error}) at ${where}`).toEqual({
                reverted: want.error,
            });
            return undefined;
        }
        expect(got, `mirror reverted where the contract does not, at ${where}`).toHaveProperty("value");
        return (got as { value: T }).value;
    }

    // `toEqual` on bigint-valued objects prints the differing field, which is what
    // a failed vector needs. Enums are plain numbers on both sides.
    const sameGame = (got: Game, want: Game, where: string) => expect(got, `game at ${where}`).toEqual(want);
    const samePortal = (got: Portal, want: Portal, where: string) => expect(got, `portal at ${where}`).toEqual(want);
    const sameOutcome = (got: Outcome, want: Outcome, where: string) => expect(got, `outcome at ${where}`).toEqual(want);

    it("has the three function groups, and enough vectors", () => {
        expect(file.applyAction.length).toBeGreaterThanOrEqual(100);
        expect(file.survey.length).toBeGreaterThanOrEqual(30);
        expect(file.blindReveal.length).toBeGreaterThanOrEqual(20);
        expect(file.applyAction.length + file.survey.length + file.blindReveal.length).toBeGreaterThanOrEqual(400);
    });

    it("applyAction matches on every vector (state after, outcome, reverts)", () => {
        file.applyAction.forEach((v, i) => {
            const where = `applyAction i=${i} label="${v.label}" action=${Action[v.action]}`;
            const got = attempt(() =>
                applyAction(
                    gameFromJson(v.game),
                    portalFromJson(v.portal),
                    configs[v.config],
                    typeParams[v.tp],
                    v.action as Action,
                ),
            );
            const r = expectRevertState(got, v.expected, where);
            if (r === undefined) return;
            sameGame(r.game, gameFromJson(v.expected.game), where);
            samePortal(r.portal, portalFromJson(v.expected.portal), where);
            sameOutcome(r.outcome, outcomeFromJson(v.expected.outcome), where);
        });
    });

    it("survey matches on every vector (state after, precise flag, reverts)", () => {
        file.survey.forEach((v, i) => {
            const where = `survey i=${i} label="${v.label}"`;
            const got = attempt(() => survey(portalFromJson(v.portal), configs[v.config], typeParams[v.tp], BigInt(v.word)));
            const r = expectRevertState(got, v.expected, where);
            if (r === undefined) return;
            samePortal(r.portal, portalFromJson(v.expected.portal), where);
            expect(r.precise, `precise flag at ${where}`).toBe(v.expected.precise);
        });
    });

    it("applyBlindRescuerReveal matches on every vector (state after, outcome, reverts)", () => {
        file.blindReveal.forEach((v, i) => {
            const where = `blindReveal i=${i} label="${v.label}"`;
            const got = attempt(() =>
                applyBlindRescuerReveal(gameFromJson(v.game), portalFromJson(v.portal), configs[v.config], BigInt(v.word)),
            );
            const r = expectRevertState(got, v.expected, where);
            if (r === undefined) return;
            sameGame(r.game, gameFromJson(v.expected.game), where);
            samePortal(r.portal, portalFromJson(v.expected.portal), where);
            sameOutcome(r.outcome, outcomeFromJson(v.expected.outcome), where);
        });
    });

    it("the mirror does not mutate its inputs", () => {
        const v = file.applyAction[0];
        const g = gameFromJson(v.game);
        const p = portalFromJson(v.portal);
        applyAction(g, p, configs[v.config], typeParams[v.tp], Action.Close);
        expect(g).toEqual(gameFromJson(v.game));
        expect(p).toEqual(portalFromJson(v.portal));
    });

    it("every Action appears among the applyAction vectors", () => {
        const seen = new Set(file.applyAction.map((v) => v.action));
        const missing = Object.values(Action).filter((x): x is Action => typeof x === "number" && !seen.has(x));
        expect(missing.map((m) => Action[m])).toEqual([]);
    });

    it("both kinds of revert are present in the set, and the mirror knows only those names", () => {
        const all = [...file.applyAction, ...file.survey, ...file.blindReveal];
        const names = new Set(all.filter((v) => v.expected.reverted).map((v) => v.expected.error));
        expect([...names].sort()).toEqual([NO_FREE_RESCUER_CELL, PANIC_ARITHMETIC].sort());
        // A non-reverted row has no error name.
        expect(all.filter((v) => !v.expected.reverted && v.expected.error !== "")).toEqual([]);
    });

    it("survey has both exact and narrowing results; reveal has both a miss and an entry", () => {
        const ok = file.survey.filter((v) => !v.expected.reverted);
        expect(ok.some((v) => v.expected.precise)).toBe(true);
        expect(ok.some((v) => !v.expected.precise)).toBe(true);
        const rv = file.blindReveal.filter((v) => !v.expected.reverted);
        expect(rv.some((v) => (v.expected.outcome as { rescuerBlindMiss: boolean }).rescuerBlindMiss)).toBe(true);
        expect(rv.some((v) => !(v.expected.outcome as { rescuerBlindMiss: boolean }).rescuerBlindMiss)).toBe(true);
    });
});
