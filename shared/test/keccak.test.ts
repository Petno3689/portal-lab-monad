import { describe, it, expect } from "vitest";
import { keccak256 } from "../src/keccak";
import { fromWord } from "../src/effects";

const hex = (x: bigint) => x.toString(16).padStart(64, "0");
const bytes = (s: string) => new TextEncoder().encode(s);

describe("keccak256", () => {
    // Known answers for the ORIGINAL Keccak padding (what Ethereum uses), not SHA3-256.
    it("empty input", () => {
        expect(hex(keccak256(new Uint8Array()))).toBe("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
    });
    it('"abc"', () => {
        expect(hex(keccak256(bytes("abc")))).toBe("4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45");
    });
    it("an input longer than the 136-byte rate (two blocks)", () => {
        // Reference value computed independently with Foundry's keccak256 (cast keccak).
        expect(hex(keccak256(bytes("a".repeat(200))))).toBe(KECCAK_A200);
    });
    it("an input of exactly one rate (136 bytes) pads into a second block", () => {
        expect(hex(keccak256(bytes("a".repeat(136))))).toBe(KECCAK_A136);
    });
});

describe("fromWord", () => {
    it("is keccak256(abi.encode(word, salt)) — word and salt as two 32-byte words", () => {
        const buf = new Uint8Array(64);
        buf[63] = 3; // salt 3, word 0
        expect(fromWord(0n, 3n)).toBe(keccak256(buf));
    });
});

// Reference values from Foundry `cast keccak`; declared below the tests that use them.
const KECCAK_A200 = "96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d";
const KECCAK_A136 = "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e";
