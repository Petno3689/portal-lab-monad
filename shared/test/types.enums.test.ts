import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Action, PortalStatus, PortalType, Refusal, RiskLevel } from "../src/types";
import * as risk from "../src/risk";

const ENUMS_PATH = fileURLToPath(new URL("vectors/enums.json", import.meta.url));

type EnumJson = Record<string, Record<string, number>>;

/** Own members of a numeric TS enum as name → value (drops the reverse mapping). */
function members(e: object): Record<string, number> {
    return Object.fromEntries(Object.entries(e).filter(([, v]) => typeof v === "number")) as Record<string, number>;
}

describe("enums match the compiled Solidity enums (enums.json)", () => {
    if (!existsSync(ENUMS_PATH)) {
        throw new Error("enums.json missing: run `forge script script/GenRulesVectors.s.sol` in contracts/");
    }
    const sol = JSON.parse(readFileSync(ENUMS_PATH, "utf8")) as EnumJson;

    const mirrors: Record<string, object> = { Action, Refusal, PortalType, PortalStatus, RiskLevel };

    it("covers exactly the enums mirrored here", () => {
        expect(Object.keys(sol).sort()).toEqual(Object.keys(mirrors).sort());
    });

    for (const [name, mirror] of Object.entries(mirrors)) {
        it(`${name}: same members, same integer values`, () => {
            expect(members(mirror)).toEqual(sol[name]);
        });
    }

    it("risk.ts re-exports the same enum objects, not copies", () => {
        expect(risk.RiskLevel).toBe(RiskLevel);
        expect(risk.PortalStatus).toBe(PortalStatus);
    });
});
