import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { check, cost } from "../src/rules";
import { Action, Refusal } from "../src/types";
import { configFromJson, gameFromJson, portalFromJson, RulesVectorFile } from "./support/vectorFormat";

const VECTORS_PATH = fileURLToPath(new URL("vectors/rules-vectors.json", import.meta.url));

/** Not a rule refusal; RulesLib.check never returns it (see PortalLabTypes.sol). */
const NEVER_FROM_CHECK = new Set<Refusal>([Refusal.RandomnessTimeout]);

describe("golden vectors — TS mirror matches RulesLib output", () => {
    if (!existsSync(VECTORS_PATH)) {
        throw new Error("rules-vectors.json missing: run `forge script script/GenRulesVectors.s.sol` in contracts/");
    }
    const file = JSON.parse(readFileSync(VECTORS_PATH, "utf8")) as RulesVectorFile;
    const configs = file.configs.map(configFromJson);

    it("has at least 1000 vectors", () => {
        expect(file.vectors.length).toBeGreaterThanOrEqual(1000);
    });

    it("check and cost match on every vector", () => {
        file.vectors.forEach((v, i) => {
            const game = gameFromJson(v.game);
            const portal = portalFromJson(v.portal);
            const a = v.action as Action;
            const where = `i=${i} label="${v.label}" action=${Action[a]}`;

            const got = check(game, portal, configs[v.config], BigInt(v.slot), a);
            expect(Refusal[got], `refusal mismatch at ${where}`).toBe(Refusal[v.expected.refusal]);
            expect(cost(configs[v.config], a), `cost mismatch at ${where}`).toBe(BigInt(v.expected.cost));
        });
    });

    it("every Action appears in the set", () => {
        const seen = new Set(file.vectors.map((v) => v.action));
        const missing = Object.values(Action).filter((x): x is Action => typeof x === "number" && !seen.has(x));
        expect(missing.map((m) => Action[m])).toEqual([]);
    });

    it("every Refusal that check can return appears in the set", () => {
        const seen = new Set(file.vectors.map((v) => v.expected.refusal));
        const missing = Object.values(Refusal).filter(
            (x): x is Refusal => typeof x === "number" && !NEVER_FROM_CHECK.has(x) && !seen.has(x),
        );
        expect(missing.map((m) => Refusal[m])).toEqual([]);
    });

    it("the mirror itself never returns RandomnessTimeout", () => {
        const seen = new Set(file.vectors.map((v) => v.expected.refusal));
        expect(seen.has(Refusal.RandomnessTimeout)).toBe(false);
    });
});
