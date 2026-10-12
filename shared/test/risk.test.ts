import { describe, it, expect } from "vitest";
import { score, levelOf, portalRisk, breakdown, divHalfUp, S, RiskLevel, PortalStatus } from "../src/risk";
import type { PortalLike } from "../src/risk";

// ── score: anchor cases ───────────────────────────────────────────────────────

describe("score — anchor cases", () => {
    it("100/0/48/0 → 0", () => expect(score(100, 0, 48, 0)).toBe(0));
    it("0/100/0/5 → 100", () => expect(score(0, 100, 0, 5)).toBe(100));
    it("50/50/24/0 → 50", () => expect(score(50, 50, 24, 0)).toBe(50));
    it("10/80/2/3 → 97", () => expect(score(10, 80, 2, 3)).toBe(97));
    it("40/40/6/1 → 71", () => expect(score(40, 40, 6, 1)).toBe(71));
});

// ── score: level boundaries (no factors) ─────────────────────────────────────

describe("score — level boundaries (no factors)", () => {
    it("42/0/48/0 → 29 (Low)", () => {
        expect(score(42, 0, 48, 0)).toBe(29);
        expect(levelOf(29)).toBe(RiskLevel.Low);
    });
    it("40/0/48/0 → 30 (Medium)", () => {
        expect(score(40, 0, 48, 0)).toBe(30);
        expect(levelOf(30)).toBe(RiskLevel.Medium);
    });
    it("20/62/48/0 → 59 (Medium)", () => {
        expect(score(20, 62, 48, 0)).toBe(59);
        expect(levelOf(59)).toBe(RiskLevel.Medium);
    });
    it("20/65/48/0 → 60 (High)", () => {
        expect(score(20, 65, 48, 0)).toBe(60);
        expect(levelOf(60)).toBe(RiskLevel.High);
    });
    it("0/83/48/0 → 84 (High)", () => {
        expect(score(0, 83, 48, 0)).toBe(84);
        expect(levelOf(84)).toBe(RiskLevel.High);
    });
    it("0/88/48/0 → 85 (Critical)", () => {
        expect(score(0, 88, 48, 0)).toBe(85);
        expect(levelOf(85)).toBe(RiskLevel.Critical);
    });
});

// ── score: exact halves round up ─────────────────────────────────────────────

describe("score — exact halves round up", () => {
    it("41/0/48/0 → 30", () => expect(score(41, 0, 48, 0)).toBe(30));
    it("20/15/12/0 → 60", () => expect(score(20, 15, 12, 0)).toBe(60));
    it("21/100/12/0 → 85", () => expect(score(21, 100, 12, 0)).toBe(85));
});

// ── score: gate 84/85 with factors ───────────────────────────────────────────

describe("score — gate 84/85 with factors", () => {
    it("20/37/2/0 → 84 (High)", () => {
        expect(score(20, 37, 2, 0)).toBe(84);
        expect(levelOf(84)).toBe(RiskLevel.High);
    });
    it("20/43/2/0 → 85 (Critical)", () => {
        expect(score(20, 43, 2, 0)).toBe(85);
        expect(levelOf(85)).toBe(RiskLevel.Critical);
    });
    it("20/64/6/1 → 84 (High)", () => {
        expect(score(20, 64, 6, 1)).toBe(84);
        expect(levelOf(84)).toBe(RiskLevel.High);
    });
    it("20/69/6/1 → 85 (Critical)", () => {
        expect(score(20, 69, 6, 1)).toBe(85);
        expect(levelOf(85)).toBe(RiskLevel.Critical);
    });
    it("3/0/6/1 → 84 (High)", () => {
        expect(score(3, 0, 6, 1)).toBe(84);
        expect(levelOf(84)).toBe(RiskLevel.High);
    });
    it("0/0/6/1 → 85 (Critical)", () => {
        expect(score(0, 0, 6, 1)).toBe(85);
        expect(levelOf(85)).toBe(RiskLevel.Critical);
    });
});

// ── score: hours beyond the 48-window ────────────────────────────────────────

describe("score — hours beyond window", () => {
    it("100/0/60/0 → 0", () => expect(score(100, 0, 60, 0)).toBe(0));
    it("100/0/1000/0 → 0", () => expect(score(100, 0, 1000, 0)).toBe(0));
});

// ── score: mutation-check vectors ────────────────────────────────────────────

describe("score — base rounding must be half-up", () => {
    it("20/0/14/2 → 62", () => expect(score(20, 0, 14, 2)).toBe(62));
    it("20/75/8/2 → 83", () => expect(score(20, 75, 8, 2)).toBe(83));
});

// ── levelOf ──────────────────────────────────────────────────────────────────

describe("levelOf", () => {
    it("0 → Low", () => expect(levelOf(0)).toBe(RiskLevel.Low));
    it("29 → Low", () => expect(levelOf(29)).toBe(RiskLevel.Low));
    it("30 → Medium", () => expect(levelOf(30)).toBe(RiskLevel.Medium));
    it("59 → Medium", () => expect(levelOf(59)).toBe(RiskLevel.Medium));
    it("60 → High", () => expect(levelOf(60)).toBe(RiskLevel.High));
    it("84 → High", () => expect(levelOf(84)).toBe(RiskLevel.High));
    it("85 → Critical", () => expect(levelOf(85)).toBe(RiskLevel.Critical));
    it("100 → Critical", () => expect(levelOf(100)).toBe(RiskLevel.Critical));
});

// ── portalRisk ────────────────────────────────────────────────────────────────

describe("portalRisk", () => {
    it("Empty slot → score 0, None", () => {
        const p: PortalLike = { status: PortalStatus.Empty, surveyed: false, stability: 0, energy: 0, hoursToCollapse: 0, creatures: 0, observerInside: false, rescuerInside: false };
        expect(portalRisk(p)).toEqual({ score: 0, level: RiskLevel.None });
    });

    it("Unsurveyed portal → score 0, Unknown (non-zero fields ignored)", () => {
        const p: PortalLike = { status: PortalStatus.Open, surveyed: false, stability: 10, energy: 90, hoursToCollapse: 2, creatures: 3, observerInside: false, rescuerInside: false };
        expect(portalRisk(p)).toEqual({ score: 0, level: RiskLevel.Unknown });
    });

    it("Observer inside counts as 1 life → same as 1 creature → 71", () => {
        const withObserver: PortalLike = { status: PortalStatus.Open, surveyed: true, stability: 40, energy: 40, hoursToCollapse: 6, creatures: 0, observerInside: true, rescuerInside: false };
        const withCreature: PortalLike = { status: PortalStatus.Open, surveyed: true, stability: 40, energy: 40, hoursToCollapse: 6, creatures: 1, observerInside: false, rescuerInside: false };
        expect(portalRisk(withObserver)).toEqual({ score: 71, level: RiskLevel.High });
        expect(portalRisk(withCreature)).toEqual({ score: 71, level: RiskLevel.High });
    });
});

// ── score: input validation ───────────────────────────────────────────────────

describe("score — input validation", () => {
    it("stability 101 throws", () => expect(() => score(101, 0, 48, 0)).toThrow());
    it("energy 101 throws", () => expect(() => score(0, 101, 48, 0)).toThrow());
    it("fractional stability throws", () => expect(() => score(10.5, 0, 48, 0)).toThrow());
    it("fractional energy throws", () => expect(() => score(0, 10.5, 48, 0)).toThrow());
    it("fractional hours throws", () => expect(() => score(50, 50, 1.5, 0)).toThrow());
});

// ── breakdown: invariant on 1000 inputs ──────────────────────────────────────

describe("breakdown — invariant: steps[2].after matches score", () => {
    it("holds for 1000 deterministic inputs", () => {
        for (let i = 0; i < 1000; i++) {
            const st = (i * 7 + 3) % 101;
            const en = (i * 13 + 5) % 101;
            const h = (i * 17 + 7) % 201;
            const lv = (i * 3 + 1) % 11;
            const p: PortalLike = {
                status: PortalStatus.Open, surveyed: true,
                stability: st, energy: en, hoursToCollapse: h,
                creatures: lv, observerInside: false, rescuerInside: false,
            };
            const bd = breakdown(p);
            const expected = score(st, en, h, lv);

            // Verify bd.score via the invariant formula.
            const afterR = bd.steps[2].after;
            const capped = afterR > 100n * S ? 100n : divHalfUp(afterR, S);
            expect(Number(capped)).toBe(expected);

            // Verify bd.score field too.
            expect(bd.score).toBe(expected);
        }
    });
});

// ── breakdown: labels and notes ──────────────────────────────────────────────

describe("breakdown — labels and notes", () => {
    it("all three steps applied (10/80/2/3)", () => {
        const p: PortalLike = {
            status: PortalStatus.Open, surveyed: true,
            stability: 10, energy: 80, hoursToCollapse: 2,
            creatures: 3, observerInside: false, rescuerInside: false,
        };
        const bd = breakdown(p);
        expect(bd.known).toBe(true);
        expect(bd.score).toBe(97);

        expect(bd.steps[0].label).toBe("Портал вот-вот схлопнется");
        expect(bd.steps[0].applied).toBe(true);
        expect(bd.steps[0].sharePct).toBe(45);
        expect(bd.steps[0].note).toBe("До схлопывания не больше 2 часов");

        expect(bd.steps[1].label).toBe("Критическая нестабильность");
        expect(bd.steps[1].applied).toBe(true);
        expect(bd.steps[1].sharePct).toBe(35);
        expect(bd.steps[1].note).toBe("Стабильность 10 ниже 20");

        expect(bd.steps[2].label).toBe("Внутри живые");
        expect(bd.steps[2].applied).toBe(true);
        expect(bd.steps[2].sharePct).toBe(20); // min(30, 8 + 4*3) = 20
        expect(bd.steps[2].note).toBe("Внутри живых: 3");

        expect(bd.dominant?.label).toBe("Портал вот-вот схлопнется");
    });

    it("no steps applied (100/0/48/0)", () => {
        const p: PortalLike = {
            status: PortalStatus.Open, surveyed: true,
            stability: 100, energy: 0, hoursToCollapse: 48,
            creatures: 0, observerInside: false, rescuerInside: false,
        };
        const bd = breakdown(p);
        expect(bd.known).toBe(true);
        expect(bd.score).toBe(0);

        expect(bd.steps[0].label).toBe("Запас времени");
        expect(bd.steps[0].applied).toBe(false);
        expect(bd.steps[0].sharePct).toBe(0);
        expect(bd.steps[0].note).toBe("До схлопывания ещё 48 ч — фактор не сработал");

        expect(bd.steps[1].label).toBe("Критическая нестабильность");
        expect(bd.steps[1].applied).toBe(false);
        expect(bd.steps[1].note).toBe("Стабильность 100 — не ниже 20");

        expect(bd.steps[2].label).toBe("Внутри живые");
        expect(bd.steps[2].applied).toBe(false);
        expect(bd.steps[2].note).toBe("Внутри никого нет");

        expect(bd.dominant).toBeNull();
    });
});
