/**
 * TypeScript mirror of TimeLib.sol — lazy time: ageing the world to `now` by
 * formula (SPEC §5, §7).
 *
 * Source of truth is contracts/src/TimeLib.sol and nothing else. Where this file
 * and the Solidity disagree, the mirror is wrong. The order of operations inside
 * `catchUp` is kept step for step with the contract: where the order is visible in
 * the result (the cooldown sweep before the walk, the segment's resource regen
 * before its overflow, ageing the survivors before spawning) it must not be
 * rearranged or "simplified".
 *
 * ── Argument mutation ───────────────────────────────────────────────────────
 *
 * NO EXPORTED FUNCTION HERE TOUCHES ITS ARGUMENTS. Every one returns fresh
 * objects, the same convention effects.ts follows, and it is worth stating
 * plainly because the contract does the opposite: `catchUp` takes `Game memory`
 * and `Portal[12] memory`, which Solidity passes BY REFERENCE, and ages them in
 * place — the values it returns ARE its arguments. In TypeScript an object
 * argument is a reference too, so a mirror that aged `g0` in place would quietly
 * corrupt the caller's state. Instead `catchUp` shallow-copies the game and every
 * portal up front (one level is enough: each field is a bigint, a boolean or an
 * enum) and works on the copies. A caller may keep using the object it passed in.
 *
 * The one exception is the module-private `spawn`, which mirrors the contract's
 * private `_spawn` and writes into the game and the portal array it is handed —
 * exactly as the Solidity does. It is never reachable from outside, and the only
 * thing ever handed to it is the pair of COPIES `catchUp` already made, so the
 * guarantee above still holds for every caller.
 *
 * Arithmetic is bigint throughout; division truncates, as in Solidity. Every
 * narrowing cast the contract writes (`uint8(x)`, `uint16(x)`, …) is mirrored
 * explicitly by `trunc`; every uint256 subtraction that could underflow goes
 * through `subChecked` and every addition into a narrow field through
 * `addChecked`, both of which throw `ContractRevert` where Solidity panics.
 */

import {
    SPAWN_DEBT_MAX,
    addChecked,
    emptyPortal,
    rescuerReadyAt,
    setRescuerReadyAt,
    subChecked,
    trunc,
} from "./effects";
import { keccak256 } from "./keccak";
import {
    Config,
    Game,
    MAX_OPEN_PORTALS,
    MAX_RESCUERS,
    Portal,
    PortalStatus,
    PortalType,
    PortalTypeParams,
} from "./types";

/** Mirror of TimeLib.EPOCH_DOMAIN (22 ASCII bytes). */
const EPOCH_DOMAIN = "portal-lab/spawn-epoch";

/**
 * Mirror of TimeLib.SALT_TYPE / SALT_HOURS / SALT_NAME — the three sub-draws of
 * one spawn. They start at 3 because the survey (effects.ts) uses 0/1/2.
 */
const SALT_TYPE = 3n;
const SALT_HOURS = 4n;
const SALT_NAME = 5n;

/** Mirror of PortalLabTypes.NAME_POOL_SIZE. */
const NAME_POOL_SIZE = 24n;

/** 32-byte big-endian encoding of a uint256 into `buf` at `offset`. */
function putWord(buf: Uint8Array, offset: number, value: bigint): void {
    for (let i = 0; i < 32; i++) {
        buf[offset + 31 - i] = Number((value >> BigInt(8 * i)) & 0xffn);
    }
}

/**
 * abi.encode(string tag, uint256 a, uint256 b): the string is dynamic, so the
 * head is three words (offset 0x60, a, b) and the tail is the length word and
 * the bytes left-aligned, zero-padded to 32. 160 bytes for a tag of <= 32 bytes.
 */
function encodeTagWordWord(tag: string, a: bigint, b: bigint): Uint8Array {
    const bytes = new TextEncoder().encode(tag);
    if (bytes.length === 0 || bytes.length > 32) {
        throw new Error("encodeTagWordWord: the tag must be 1..32 bytes (one data word)");
    }
    const buf = new Uint8Array(160);
    putWord(buf, 0, 0x60n);
    putWord(buf, 32, a);
    putWord(buf, 64, b);
    putWord(buf, 96, BigInt(bytes.length));
    buf.set(bytes, 128);
    return buf;
}

/** Mirror of TimeLib.epochSeed: keccak256(abi.encode(EPOCH_DOMAIN, word, epoch)). */
export function epochSeed(word: bigint, epoch: bigint): bigint {
    return keccak256(encodeTagWordWord(EPOCH_DOMAIN, word, epoch));
}

/**
 * Mirror of TimeLib._spawnDraw: one spawn sub-draw,
 * `keccak256(abi.encode(uint256 seed, uint32 spawnId, uint8 salt))`.
 *
 * All three values are STATIC types, so the encoding is simply three 32-byte
 * big-endian words, each left-padded — unlike `epochSeed`, whose leading string
 * tag forces an offset head and a length-prefixed tail. 96 bytes, no head, no
 * tail. Getting this wrong would not fail loudly: it would hash a different
 * preimage and silently draw a different portal.
 */
export function spawnDraw(seed: bigint, spawnId: bigint, salt: bigint): bigint {
    const buf = new Uint8Array(96);
    putWord(buf, 0, seed);
    putWord(buf, 32, spawnId);
    putWord(buf, 64, salt);
    return keccak256(buf);
}

/**
 * Mirror of TimeLib.spawnPressure: pressure accrued over game hours [a, b).
 * Closed form, no loop over hours. `(a + b - 1) * n` is always even.
 */
export function spawnPressure(a: bigint, b: bigint, c: Config): bigint {
    if (b <= a) return 0n;
    const n = b - a;
    const tri = ((a + b - 1n) * n) / 2n;
    return c.basePressurePerHour * n + c.pressureRampPerHour * tri;
}

/** Mirror of TimeLib._wordFor: the old word pins epochs below the split, the new one the rest. */
export function wordFor(epoch: bigint, oldWord: bigint, newWord: bigint, splitCoveredEpochs: bigint): bigint {
    return epoch < splitCoveredEpochs ? oldWord : newWord;
}

// ── catchUp ──────────────────────────────────────────────────────────────────

/** Mirror of TimeLib.Collapse — one portal collapse that happened during catch-up. */
export interface Collapse {
    slot: bigint;
    deaths: bigint;
    hpLost: bigint;
    atHour: bigint;
}

/** Mirror of TimeLib.Spawn — one portal that appeared during catch-up. */
export interface Spawn {
    slot: bigint;
    portalType: PortalType;
    nameIndex: bigint;
    atHour: bigint;
}

/**
 * What `catchUp` gives back. `events` and `spawns` hold EXACTLY the records that
 * happened: the contract returns fixed-size arrays plus a count, and the tail of
 * those arrays is meaningless, so it has no counterpart here.
 */
export interface CatchUpResult {
    game: Game;
    portals: Portal[];
    events: Collapse[];
    spawns: Spawn[];
    cappedShort: boolean;
}

/**
 * Mirror of TimeLib.catchUp: bring `g0` and `portals0` forward to `nowTs`.
 *
 * @param portals0 exactly MAX_OPEN_PORTALS (12) portals — the contract's fixed array.
 * @param types one PortalTypeParams per PortalType, in enum order (five entries).
 */
export function catchUp(
    g0: Game,
    portals0: readonly Portal[],
    c: Config,
    types: readonly PortalTypeParams[],
    oldWord: bigint,
    newWord: bigint,
    storedCoveredEpochs: bigint,
    maxCoveredEpochs: bigint,
    nowTs: bigint,
): CatchUpResult {
    if (BigInt(portals0.length) !== MAX_OPEN_PORTALS) {
        throw new Error(`catchUp: expected ${MAX_OPEN_PORTALS} portals, got ${portals0.length}`);
    }
    if (types.length !== 5) {
        throw new Error(`catchUp: expected 5 PortalTypeParams, got ${types.length}`);
    }

    const g: Game = { ...g0 };
    const portals: Portal[] = portals0.map((p) => ({ ...p }));
    const events: Collapse[] = [];
    const spawns: Spawn[] = [];

    // 1. No game, already finished, or clock before game start: nothing to age.
    if (g.startedAt === 0n || g.finished || nowTs < g.startedAt) {
        return { game: g, portals, events, spawns, cappedShort: false };
    }

    const sph = c.secPerHour;
    const eph = c.epochHours;
    const hNow = subChecked(nowTs, g.startedAt) / sph;
    let cursor = subChecked(g.lastTickAt, g.startedAt) / sph; // == g.hoursElapsed
    const windowStart = cursor; // saved: the walk mutates `cursor`

    // How far the world may be aged for RANDOM spawns: only into epochs pinned to
    // a word. `hWalkEnd` is the last such hour, never behind where the world
    // already is.
    let hWalkEnd: bigint;
    if (maxCoveredEpochs === 0n) {
        hWalkEnd = windowStart; // nothing pinned yet: the world cannot advance
    } else {
        const maxAdvanceHour = subChecked(maxCoveredEpochs * eph, 1n);
        hWalkEnd = hNow < maxAdvanceHour ? hNow : maxAdvanceHour;
        if (hWalkEnd < windowStart) hWalkEnd = windowStart;
    }
    const cappedShort = hWalkEnd < hNow;

    // 1b. Release rescuers whose recovery cooldown has matured (SPEC §4.3). A
    //     COMPARISON against the advanced hour, never a per-hour loop.
    //     `rescuersFree += 1` cannot overflow its uint8: the guard caps it at
    //     `rescuersTotal`, itself a uint8.
    for (let i = 0n; i < MAX_RESCUERS; i++) {
        const readyAt = rescuerReadyAt(g, i);
        if (readyAt !== 0n && readyAt <= hWalkEnd) {
            setRescuerReadyAt(g, i, 0n);
            if (g.rescuersFree < c.rescuersTotal) g.rescuersFree += 1n;
        }
    }

    // 2. Collect collapse events (occupied portals whose collapse hour has
    //    arrived) and tally the currently-open portals and their power yield.
    const evSlot: bigint[] = [];
    const evHour: bigint[] = [];
    let openCount = 0n;
    let yieldSum = 0n;
    for (let i = 0; i < Number(MAX_OPEN_PORTALS); i++) {
        const p = portals[i];
        if (p.status === PortalStatus.Empty) continue;
        openCount += 1n;
        yieldSum += types[p.portalType].powerYieldPerHour;
        // collapse hour == h(snapshotAt) + hoursToCollapse == h(collapseAt).
        const ch = subChecked(p.snapshotAt, g.startedAt) / sph + p.hoursToCollapse;
        if (ch <= hWalkEnd) {
            evSlot.push(BigInt(i));
            evHour.push(ch);
        }
    }
    // Occupancy at the START of the window, taken HERE — before the walk — for
    // step 5's fill threshold `(12 - openStart) * spawnCostUnits`. It is NOT the
    // same number as `openCount`, which keeps dropping as the walk below collapses
    // portals; reading the post-walk count instead would lower the threshold and
    // declare an abandoned lab full too early.
    const openStart = openCount;

    // 3. Insertion sort events by hour ascending (stable, <= 12 elements). The
    //    stability is observable: two portals due in the same hour must come out
    //    in slot order, which is the order step 2 collected them in.
    const evN = evSlot.length;
    for (let a = 1; a < evN; a++) {
        const slotA = evSlot[a];
        const hourA = evHour[a];
        let b = a;
        while (b > 0 && evHour[b - 1] > hourA) {
            evHour[b] = evHour[b - 1];
            evSlot[b] = evSlot[b - 1];
            b -= 1;
        }
        evHour[b] = hourA;
        evSlot[b] = slotA;
    }

    // 4. Walk the timeline in segments: cursor -> each event hour -> hWalkEnd.
    //    O(events) segments, never O(hours).
    let died = false;
    let deathHour = 0n;
    for (let k = 0; k <= evN; k++) {
        const segEnd = k < evN ? evHour[k] : hWalkEnd;
        const delta = segEnd > cursor ? segEnd - cursor : 0n; // game hours in this segment

        if (delta > 0n) {
            // Resource: regen plus the yield of every open portal.
            const rate = c.powerRegenPerHour + yieldSum;
            let np = g.power + rate * delta;
            if (np > c.powerMax) np = c.powerMax;
            g.power = trunc(np, 16);

            // Overflow: only when exactly 12 portals are open.
            if (openCount === MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0n) {
                const ov = c.hpOverflowPerHour;
                const hToDeath = (g.hp + ov - 1n) / ov; // ceil(hp / ov)
                if (hToDeath <= delta) {
                    died = true;
                    deathHour = cursor + hToDeath;
                    g.hp = 0n;
                    break;
                }
                // hToDeath > delta => ov*delta < hp, so no underflow.
                g.hp = trunc(g.hp - ov * delta, 16);
            }
        }

        if (segEnd > cursor) cursor = segEnd;

        // At the event moment: collapse the portal.
        if (k < evN) {
            const s = Number(evSlot[k]);
            const p = portals[s];
            // Read all needed fields BEFORE blanking the slot.
            let deaths = p.creaturesKnown ? p.creatures : (p.creaturesLo + p.creaturesHi) / 2n;
            if (p.observerInside) deaths += 1n;
            if (p.rescuerInside) deaths += 1n;
            const yld = types[p.portalType].powerYieldPerHour;

            // An empty collapse still costs hpEmptyCollapse — it is the keeper's
            // failure, unlike closing an empty portal (free, §4.4).
            const hpLost = deaths > 0n ? c.hpCollapseBase + c.hpCollapsePerDeath * deaths : c.hpEmptyCollapse;

            const hpBefore = g.hp;
            const actualLost = hpBefore > hpLost ? hpLost : hpBefore; // min(loss, hp before the hit)

            // `deaths` truncates to uint8 in the event while the HP charge is for
            // all of them: two different numbers, deliberately.
            events.push({
                slot: evSlot[k],
                deaths: trunc(deaths, 8),
                hpLost: trunc(actualLost, 16),
                atHour: trunc(evHour[k], 32),
            });

            g.hp = trunc(hpBefore - actualLost, 16);

            // Crew inside dies and does NOT return to the pool (§4.3). The slot is
            // freed: a fresh zeroed portal (status == Empty).
            portals[s] = emptyPortal();
            openCount -= 1n;
            yieldSum -= yld;

            if (g.hp === 0n) {
                died = true;
                deathHour = evHour[k];
                break;
            }
        }
    }

    g.openPortals = trunc(openCount, 8);

    // 5. Pressure & spawns. Only meaningful while the run survived the walk above
    //    — a death there already ended it, and spawnDebt is irrelevant to a
    //    finished game.
    if (!died) {
        const debt0 = g.spawnDebt;

        // Long-absence overflow: a DETERMINISTIC death that needs NO word, so it
        // is evaluated over the FULL window `[windowStart, hNow]` even when the
        // covered edge is nearer — the cap gates the RANDOM spawns only. THE TWO
        // LIMITS BELOW ARE DIFFERENT ON PURPOSE: `hNow` here, `hWalkEnd` in the
        // survival accrual further down. Writing both against the covered edge
        // would diverge from the chain on exactly the commonest input there is —
        // a player who stayed away a long time.
        const fullRaw = debt0 + spawnPressure(windowStart, hNow, c);
        const needed = (MAX_OPEN_PORTALS - openStart) * c.spawnCostUnits;
        if (openStart < MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0n && fullRaw >= needed) {
            const hFill = fillHour(windowStart, hNow, debt0, needed, c);
            const ov = c.hpOverflowPerHour;
            const hToDeath = (g.hp + ov - 1n) / ov; // ceil(hp / ov)
            const dh = hFill + hToDeath;
            if (dh <= hNow) {
                g.spawnDebt = fullRaw > SPAWN_DEBT_MAX ? SPAWN_DEBT_MAX : trunc(fullRaw, 32);
                // Create up to maxSpawnsPerTx REAL portals (the rest are pointless
                // — the player is dead), then freeze at death. Both arguments are
                // narrowed by the contract before `_spawn` sees them.
                spawns.push(
                    ...spawn(
                        g,
                        portals,
                        c,
                        types,
                        oldWord,
                        newWord,
                        storedCoveredEpochs,
                        trunc(hFill, 32),
                        trunc(g.startedAt + hFill * sph, 40),
                    ),
                );
                g.hp = 0n;
                died = true;
                deathHour = dh;
            }
        }
        if (!died) {
            // Survived: accrue only the COVERED span into spawnDebt. The uncovered
            // tail (hWalkEnd..hNow) is not yet lived — it accrues on the next call
            // once a word pins its epochs. No pressure is lost.
            const raw = debt0 + spawnPressure(windowStart, hWalkEnd, c);
            g.spawnDebt = raw > SPAWN_DEBT_MAX ? SPAWN_DEBT_MAX : trunc(raw, 32);
        }
    }

    // 6. Commit.
    if (died) {
        // Freeze the world at the moment of death — survivors are NOT aged, and
        // the stamp is `nowTs`, not the covered edge.
        g.finished = true;
        g.diedAtHour = trunc(deathHour, 32);
        g.hoursElapsed = trunc(deathHour, 32);
        g.lastTickAt = nowTs;
    } else {
        // When the world could not reach `nowTs` (capped at the pinned edge),
        // stamp time at the EDGE hour, not `nowTs`, so the next call resumes from
        // the edge and the uncovered tail is not skipped.
        const effTs = cappedShort ? trunc(g.startedAt + hWalkEnd * sph, 40) : nowTs;
        g.hoursElapsed = trunc(hWalkEnd, 32);
        g.lastTickAt = effTs;
        // Age each survivor by e = hWalkEnd - h(snapshotAt) and re-snapshot.
        for (let i = 0; i < Number(MAX_OPEN_PORTALS); i++) {
            const p = portals[i];
            if (p.status === PortalStatus.Empty) continue;
            const hSnap = subChecked(p.snapshotAt, g.startedAt) / sph;
            const e = subChecked(hWalkEnd, hSnap); // survivors have hoursToCollapse > e
            if (p.surveyed) {
                const deg = types[p.portalType].degradePerHour * e;
                p.stability = p.stability > deg ? trunc(p.stability - deg, 8) : 0n;
            } else {
                // Unsurveyed: knowledge decays — the energy and stability ranges
                // drift outward by rangeWidenPerHour on each bound per game hour.
                // The CREATURES range is deliberately left untouched.
                const widen = c.rangeWidenPerHour * e;
                p.energyLo = p.energyLo > widen ? trunc(p.energyLo - widen, 8) : 0n;
                const eHi = p.energyHi + widen;
                p.energyHi = eHi > 100n ? 100n : trunc(eHi, 8);
                p.stabilityLo = p.stabilityLo > widen ? trunc(p.stabilityLo - widen, 8) : 0n;
                const sHi = p.stabilityHi + widen;
                p.stabilityHi = sHi > 100n ? 100n : trunc(sHi, 8);
            }
            p.hoursToCollapse = p.hoursToCollapse > e ? trunc(p.hoursToCollapse - e, 16) : 0n;
            p.snapshotAt = effTs;
        }

        // Lazy spawns: create up to maxSpawnsPerTx portals from the accrued
        // pressure into the first free slots (SPEC §7), at the edge hour
        // `hWalkEnd`, whose epoch is pinned by construction. New portals carry
        // snapshotAt = effTs, so the ageing loop above — which ran FIRST, and must
        // keep running first — would leave them untouched even if it saw them.
        // Only when the world actually advanced, exactly as the contract does:
        // repeated calls at one moment must not spend the accrued debt.
        if (hWalkEnd > windowStart) {
            spawns.push(
                ...spawn(g, portals, c, types, oldWord, newWord, storedCoveredEpochs, trunc(hWalkEnd, 32), effTs),
            );
        }
    }

    return { game: g, portals, events, spawns, cappedShort };
}

/**
 * Mirror of TimeLib._fillHour: the smallest hour count `hh` in
 * `[0, hNow - windowStart]` for which `debt0 + spawnPressure(windowStart,
 * windowStart + hh) >= needed`, returned as the ABSOLUTE game hour
 * `windowStart + hh`.
 *
 * `hNow - windowStart` is a uint256 subtraction in the contract, so a call with a
 * `lastTickAt` AHEAD of `nowTs` panics here rather than searching a bogus range —
 * `subChecked` reproduces that. A real game never gets there; a caller holding a
 * stale timestamp can.
 *
 * The 64-iteration cap is the contract's own guard and is mirrored verbatim. With
 * hours in a uint32 the loop converges in at most 32 steps, so the cap NEVER
 * binds and never shapes the result — it is reproduced because it is there, not
 * because it does anything.
 */
function fillHour(windowStart: bigint, hNow: bigint, debt0: bigint, needed: bigint, c: Config): bigint {
    let lo = 0n;
    let hi = subChecked(hNow, windowStart);
    for (let it = 0; it < 64 && lo < hi; it++) {
        const mid = (lo + hi) / 2n;
        if (debt0 + spawnPressure(windowStart, windowStart + mid, c) >= needed) {
            hi = mid;
        } else {
            lo = mid + 1n;
        }
    }
    return windowStart + lo;
}

/**
 * Mirror of TimeLib._spawn: create up to
 * `min(spawnDebt / spawnCostUnits, maxSpawnsPerTx)` portals into the first free
 * slots, spending `spawnCostUnits` of pressure each, and return the spawn records.
 *
 * The MOMENT a portal appears is deterministic; only its CONTENTS are random, and
 * they derive from the portal's EPOCH SEED — `epochSeed(wordFor(epoch), epoch)`
 * with `epoch = spawnedAtHour / epochHours` — not from a per-game counter. The
 * player cannot pre-compute the word of a future epoch, so they cannot schedule a
 * run beyond the current one. `rngNonce` is still bumped per portal: it no longer
 * feeds the spawn draw, but the bump keeps the nonce stream the blind-rescue path
 * reads unchanged.
 *
 * `g` and `portals` are WRITTEN THROUGH, as the Solidity writes through its
 * memory arguments — see the note on argument mutation in the file header. Both
 * are `catchUp`'s own copies.
 */
function spawn(
    g: Game,
    portals: Portal[],
    c: Config,
    types: readonly PortalTypeParams[],
    oldWord: bigint,
    newWord: bigint,
    storedCoveredEpochs: bigint,
    spawnedAtHour: bigint,
    nowTs: bigint,
): Spawn[] {
    const out: Spawn[] = [];

    const cost = c.spawnCostUnits;
    if (cost === 0n) return out; // configuration guards cost > 0
    const affordable = g.spawnDebt / cost;
    const budget = affordable < c.maxSpawnsPerTx ? affordable : c.maxSpawnsPerTx;

    // Seed for this spawn hour's epoch, pinned by the old/new word split.
    const epoch = spawnedAtHour / c.epochHours;
    const seed = epochSeed(wordFor(epoch, oldWord, newWord, storedCoveredEpochs), epoch);

    for (let i = 0; i < Number(MAX_OPEN_PORTALS) && BigInt(out.length) < budget; i++) {
        if (portals[i].status !== PortalStatus.Empty) continue;

        g.rngNonce = addChecked(g.rngNonce, 1n, 32); // vestigial for spawns; preserves the nonce stream
        g.spawnCount = addChecked(g.spawnCount, 1n, 32);
        const spawnId = g.spawnCount; // discriminator: unique per spawn within the epoch

        const portalType = Number(spawnDraw(seed, spawnId, SALT_TYPE) % 5n) as PortalType;
        const tp = types[portalType];

        // Exact, always-public collapse time inside the type's range.
        const span = subChecked(tp.hoursMax, tp.hoursMin) + 1n;
        const htc = trunc(tp.hoursMin + (spawnDraw(seed, spawnId, SALT_HOURS) % span), 16);
        const nameIndex = trunc(spawnDraw(seed, spawnId, SALT_NAME) % NAME_POOL_SIZE, 16);

        // Built FRESH from zeros, never copied from another portal: `surveyed`,
        // `surveyPending`, the crew flags and the exact values all stay at their
        // defaults, so the portal is unsurveyed and empty of people.
        const np = emptyPortal();
        np.id = trunc(spawnId, 16);
        np.portalType = portalType;
        np.nameIndex = nameIndex;
        np.status = PortalStatus.Open;
        np.hoursToCollapse = htc;
        np.spawnedAtHour = spawnedAtHour;
        np.snapshotAt = nowTs;
        np.energyLo = tp.energyMin;
        np.energyHi = tp.energyMax;
        np.stabilityLo = tp.stabilityMin;
        np.stabilityHi = tp.stabilityMax;
        np.creaturesLo = tp.creaturesMin;
        np.creaturesHi = tp.creaturesMax;
        portals[i] = np;

        g.openPortals = addChecked(g.openPortals, 1n, 8);
        g.spawnDebt = subChecked(g.spawnDebt, cost); // budget <= debt/cost, so this cannot underflow

        out.push({ slot: BigInt(i), portalType, nameIndex, atHour: spawnedAtHour });
    }

    return out;
}
