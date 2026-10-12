/**
 * Keccak-256 (the pre-NIST padding Ethereum uses, NOT SHA3-256) on bigint lanes.
 *
 * Exists because EffectsLib derives every survey/blind-rescue draw from
 * `keccak256(abi.encode(word, salt))` and the mirror has to reproduce it bit for
 * bit. No dependency is added for ~50 lines; correctness is pinned by known-answer
 * tests (test/keccak.test.ts) and, end to end, by the effects golden vectors.
 */

const MASK = (1n << 64n) - 1n;

const ROUND_CONSTANTS: bigint[] = [
    0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
    0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
    0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
    0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
    0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
    0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

/** Rotation offsets, indexed [x + 5*y]. */
const ROTATIONS: number[] = [
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14,
];

const rotl = (v: bigint, n: number): bigint =>
    n === 0 ? v : ((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK;

function keccakF(s: bigint[]): void {
    for (let round = 0; round < 24; round++) {
        // θ
        const c: bigint[] = [];
        for (let x = 0; x < 5; x++) c.push(s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20]);
        for (let x = 0; x < 5; x++) {
            const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
            for (let y = 0; y < 5; y++) s[x + 5 * y] ^= d;
        }
        // ρ and π
        const b: bigint[] = new Array<bigint>(25).fill(0n);
        for (let x = 0; x < 5; x++) {
            for (let y = 0; y < 5; y++) {
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROTATIONS[x + 5 * y]);
            }
        }
        // χ
        for (let x = 0; x < 5; x++) {
            for (let y = 0; y < 5; y++) {
                s[x + 5 * y] = b[x + 5 * y] ^ (~b[((x + 1) % 5) + 5 * y] & MASK & b[((x + 2) % 5) + 5 * y]);
            }
        }
        // ι
        s[0] ^= ROUND_CONSTANTS[round];
    }
}

/** keccak256 of `data`, returned as a 256-bit unsigned bigint (big-endian reading). */
export function keccak256(data: Uint8Array): bigint {
    const rate = 136; // bytes; 1088-bit rate for a 256-bit output
    const padded = new Uint8Array(Math.ceil((data.length + 1) / rate) * rate);
    padded.set(data);
    padded[data.length] ^= 0x01;
    padded[padded.length - 1] ^= 0x80;

    const state: bigint[] = new Array<bigint>(25).fill(0n);
    for (let off = 0; off < padded.length; off += rate) {
        for (let i = 0; i < rate / 8; i++) {
            let lane = 0n;
            for (let k = 7; k >= 0; k--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + k]);
            state[i] ^= lane;
        }
        keccakF(state);
    }

    // First 32 bytes of the state, lanes little-endian, assembled big-endian.
    let out = 0n;
    for (let i = 0; i < 4; i++) {
        for (let k = 0; k < 8; k++) {
            out = (out << 8n) | ((state[i] >> BigInt(8 * k)) & 0xffn);
        }
    }
    return out;
}
