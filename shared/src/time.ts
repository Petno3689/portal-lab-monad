/**
 * TypeScript mirror of TimeLib.sol — lazy time: ageing the world to `now` by
 * formula (SPEC §5, §7).
 *
 * Source of truth is contracts/src/TimeLib.sol and nothing else. Where this file
 * and the Solidity disagree, the mirror is wrong. The order of operations inside
 * `catchUp` is kept step for step with the contract: where the order is visible in
 * the result (collapses and births walked in ONE chronological pass with a
 * collapse first at an equal hour, a segment's resource regen before its
 * overflow, the rescuer release AFTER the walk at the stamped hour, ageing the
 * survivors last) it must not be rearranged or "simplified".
 *
 * The algorithm: a portal is born at the hour its pressure matures (and a slot is
 * free), not at the hour of the call that ages the world, so one catch-up to `c`
 * equals a catch-up to `b` followed by one to `c`. The world is walked by EVENTS
 * (collapses of stored portals and of portals born in the window, and births),
 * never by hours; an event fuse of MAX_CATCHUP_EVENTS stops a walk that would
 * process more, and the next call continues from where it stopped. A clock behind
 * `lastTickAt` is clamped to it.
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
 * The module-private helpers (`advance`, `collapse`, `birth`) write into the game,
 * the portal array and the walk state they are handed — exactly as the Solidity
 * private functions write through their memory arguments. They are never
 * reachable from outside, and the only things ever handed to them are the copies
 * `catchUp` already made, so the guarantee above still holds for every caller.
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
    MAX_CATCHUP_EVENTS,
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

/** Mirror of TimeLib.NONE: "no such hour" — an empty slot's collapse hour, no birth pending. */
const NONE = (1n << 256n) - 1n;

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

/** Mirror of TimeLib.Walk — the working state of one walk. */
interface Walk {
    sph: bigint; // seconds per game hour
    h0: bigint; // window start: h(lastTickAt)
    hEnd: bigint; // last hour the world may reach: hNow, or the pinned edge
    hNow: bigint; // h(nowTs)
    debt0: bigint; // stored spawnDebt at the window start
    aEnd: bigint; // A(hEnd): the pressure available at the end of the walk
    cursor: bigint; // the walk has lived up to this hour
    births: bigint; // portals born in this window
    nextMature: bigint; // hour the (births+1)-th portal's pressure matures (NONE: not by hEnd)
    openCount: bigint; // portals open at `cursor`
    yieldSum: bigint; // their power yield per hour
    nEv: bigint; // events processed (collapses + births)
    colSlot: bigint; // slot of the next collapse
    colNext: bigint; // its hour (NONE: no portal open)
    birthsOk: boolean; // births allowed: a portal costs pressure and [h0, hEnd] is pinned
    died: boolean;
    deathHour: bigint;
    oldWord: bigint;
    newWord: bigint;
    split: bigint; // storedCoveredEpochs
    seedEpoch: bigint; // epoch whose seed is cached in `seed` (NONE: nothing cached)
    seed: bigint;
}

/**
 * Mirror of TimeLib.catchUp: bring `g0` and `portals0` forward to `nowTs`,
 * birthing only into epochs pinned to a word.
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

    // A clock behind lastTickAt means no time has passed: the result equals the
    // call at lastTickAt.
    if (nowTs < g.lastTickAt) nowTs = g.lastTickAt;

    const w: Walk = {
        sph: c.secPerHour,
        h0: 0n,
        hEnd: 0n,
        hNow: 0n,
        debt0: g.spawnDebt,
        aEnd: 0n,
        cursor: 0n,
        births: 0n,
        nextMature: NONE,
        openCount: 0n,
        yieldSum: 0n,
        nEv: 0n,
        colSlot: 0n,
        colNext: NONE,
        birthsOk: false,
        died: false,
        deathHour: 0n,
        oldWord,
        newWord,
        split: storedCoveredEpochs,
        seedEpoch: NONE,
        seed: 0n,
    };
    w.hNow = subChecked(nowTs, g.startedAt) / w.sph;
    w.h0 = subChecked(g.lastTickAt, g.startedAt) / w.sph; // == g.hoursElapsed
    w.cursor = w.h0;

    // How far the world may be walked: only through epochs pinned to a word
    // (epoch e is pinned iff e < maxCoveredEpochs). With nothing pinned the world
    // stays where it is. Births are allowed only when every hour of [h0, hEnd]
    // lies in a pinned epoch, and only when a portal costs pressure.
    const edge = maxCoveredEpochs === 0n ? w.h0 : subChecked(maxCoveredEpochs * c.epochHours, 1n);
    w.birthsOk = maxCoveredEpochs > 0n && w.h0 <= edge && c.spawnCostUnits > 0n;
    const room = edge > w.h0 ? edge - w.h0 : 0n;
    const ahead = subChecked(w.hNow, w.h0); // nowTs >= lastTickAt after the clamp
    w.hEnd = w.h0 + (ahead < room ? ahead : room);
    let cappedShort = w.hEnd < w.hNow;
    w.aEnd = w.debt0 + spawnPressure(w.h0, w.hEnd, c);

    // 2. Collapse hour of every occupied slot, the open count and the yield.
    const colHour: bigint[] = [];
    for (let i = 0; i < Number(MAX_OPEN_PORTALS); i++) {
        const p = portals[i];
        if (p.status === PortalStatus.Empty) {
            colHour.push(NONE);
            continue;
        }
        w.openCount += 1n;
        w.yieldSum += types[p.portalType].powerYieldPerHour;
        // collapse hour == h(snapshotAt) + hoursToCollapse == h(collapseAt).
        colHour.push(subChecked(p.snapshotAt, g.startedAt) / w.sph + p.hoursToCollapse);
    }
    findNextCollapse(colHour, w);

    // 3. One chronological pass over the events. O(events), never O(hours).
    w.nextMature = w.birthsOk ? matureHour(w, c, w.h0) : NONE;
    const fuse = walk(g, portals, colHour, w, c, types, events, spawns);
    // The last segment, to the end of the window. After a blown fuse the walk
    // stops at the hour of the last processed event instead.
    if (!w.died && !fuse) advance(g, w, c, w.hEnd);
    if (fuse) cappedShort = true;
    const hStop = fuse ? w.cursor : w.hEnd;

    // 4. Beyond the pinned edge (§5.5): the world cannot be walked there (no word,
    //    so no births), but the abandoned-lab overflow needs no word. From the
    //    state at hEnd, find the hour the remaining pressure would fill the lab;
    //    if the ensuing overflow is lethal by hNow, the run ends then. No portal
    //    is created in the tail. A lab already full at hEnd is not considered.
    //    Not applied after a blown fuse.
    let tailDeath = false;
    if (!w.died && !fuse && cappedShort && c.hpOverflowPerHour > 0n && w.openCount < MAX_OPEN_PORTALS) {
        const debtE = subChecked(w.aEnd, w.births * c.spawnCostUnits);
        const needed = (MAX_OPEN_PORTALS - w.openCount) * c.spawnCostUnits;
        if (debtE + spawnPressure(w.hEnd, w.hNow, c) >= needed) {
            const hFill = firstHour(w.hEnd, w.hEnd, w.hNow, debtE, needed, c);
            const ov = c.hpOverflowPerHour;
            const dh = hFill + (g.hp + ov - 1n) / ov; // + ceil(hp / ov)
            if (dh <= w.hNow) {
                w.died = true;
                w.deathHour = dh;
                tailDeath = true;
            }
        }
    }

    // 5. Commit. `hFreeze` is the hour the stored world is stamped at; spawn debt
    //    is the pressure available then, less what the births spent.
    let hFreeze: bigint;
    let effTs: bigint;
    if (w.died) {
        // A walk death freezes the world at the death hour (never behind the
        // window start); a tail death freezes it at the edge it never got past.
        hFreeze = tailDeath ? w.hEnd : w.deathHour > w.h0 ? w.deathHour : w.h0;
        effTs = trunc(g.startedAt + hFreeze * w.sph, 40);
        g.hp = 0n;
        g.finished = true;
        g.diedAtHour = trunc(w.deathHour, 32);
        g.hoursElapsed = trunc(w.deathHour, 32);
        // The clock of a finished game stops at its death, whoever looks later.
        g.lastTickAt = trunc(g.startedAt + w.deathHour * w.sph, 40);
    } else {
        hFreeze = hStop;
        // A world that could not reach `nowTs` is stamped at the hour it stopped,
        // NOT `nowTs`, so the next call resumes from there.
        effTs = cappedShort ? trunc(g.startedAt + hStop * w.sph, 40) : nowTs;
        g.hoursElapsed = trunc(hStop, 32);
        g.lastTickAt = effTs;
    }
    const debtOut = subChecked(available(w, c, hFreeze), w.births * c.spawnCostUnits);
    g.spawnDebt = debtOut > SPAWN_DEBT_MAX ? SPAWN_DEBT_MAX : trunc(debtOut, 32);
    g.openPortals = trunc(w.openCount, 8);

    // Release rescuers whose recovery cooldown has matured by the stamped hour
    // (SPEC §4.3). A COMPARISON against that hour, never a per-hour loop.
    // `rescuersFree` is capped at `rescuersTotal`, itself a uint8.
    for (let i = 0n; i < MAX_RESCUERS; i++) {
        const readyAt = rescuerReadyAt(g, i);
        if (readyAt !== 0n && readyAt <= hFreeze) {
            setRescuerReadyAt(g, i, 0n);
            if (g.rescuersFree < c.rescuersTotal) g.rescuersFree += 1n;
        }
    }

    ageAll(g, portals, c, types, w.sph, hFreeze, effTs);

    return { game: g, portals, events, spawns, cappedShort };
}

/**
 * Mirror of TimeLib._walk: collapses and births in chronological order until the
 * window is exhausted, the run dies, or the fuse blows. Returns true when the
 * fuse stopped it.
 */
function walk(
    g: Game,
    portals: Portal[],
    colHour: bigint[],
    w: Walk,
    c: Config,
    types: readonly PortalTypeParams[],
    events: Collapse[],
    spawns: Spawn[],
): boolean {
    for (;;) {
        const ch = w.colNext;
        let bh = NONE;
        if (w.nextMature !== NONE && w.openCount < MAX_OPEN_PORTALS) {
            bh = w.nextMature > w.cursor ? w.nextMature : w.cursor;
        }
        // At an equal hour the collapse goes first (`ch <= bh`).
        const isCollapse = ch <= w.hEnd && ch <= bh;
        if (!isCollapse && bh > w.hEnd) return false; // nothing more inside the window
        if (w.nEv === MAX_CATCHUP_EVENTS) return true;
        advance(g, w, c, isCollapse ? ch : bh);
        if (w.died) return false;
        if (isCollapse) {
            collapse(g, portals, colHour, w, c, types, events, w.colSlot, ch);
            if (w.died) return false;
        } else {
            birth(g, portals, colHour, w, c, types, spawns, bh);
            w.nextMature = matureHour(w, c, w.nextMature);
        }
        w.nEv += 1n;
    }
}

/** Mirror of TimeLib._available: `A(h) = debt0 + spawnPressure(h0, h)`, not saturated. */
function available(w: Walk, c: Config, h: bigint): bigint {
    return w.debt0 + spawnPressure(w.h0, h, c);
}

/**
 * Mirror of TimeLib._firstHour: the smallest hour `h` in `[lo, hi]` with
 * `have + spawnPressure(from, h) >= target`. The caller guarantees the predicate
 * holds at `hi`.
 *
 * No per-hour scan: the estimate `lo + ceil(shortfall / r)` caps `hi`, one
 * evaluation at `hi - 1` confirms it, otherwise a binary search capped at 64
 * iterations finishes — all exactly as the contract does it.
 */
function firstHour(from: bigint, lo: bigint, hi: bigint, have: bigint, target: bigint, c: Config): bigint {
    const atLo = have + spawnPressure(from, lo, c);
    if (atLo >= target) return lo;
    const r = c.basePressurePerHour + c.pressureRampPerHour * lo;
    if (r > 0n) {
        const cap = lo + (target - atLo + r - 1n) / r;
        if (cap < hi) hi = cap;
    }
    // Invariant: the predicate fails at lo and holds at hi.
    if (subChecked(hi, lo) > 1n && have + spawnPressure(from, hi - 1n, c) < target) return hi;
    for (let it = 0; it < 64 && subChecked(hi, lo) > 1n; it++) {
        const mid = (lo + hi) / 2n;
        if (have + spawnPressure(from, mid, c) >= target) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    return hi;
}

/**
 * Mirror of TimeLib._matureHour: the smallest hour with `A(h) >= (births + 1) *
 * spawnCostUnits`, or NONE if it does not mature by `hEnd`.
 */
function matureHour(w: Walk, c: Config, from: bigint): bigint {
    const target = (w.births + 1n) * c.spawnCostUnits;
    if (w.aEnd < target) return NONE;
    return firstHour(w.h0, from, w.hEnd, w.debt0, target, c);
}

/**
 * Mirror of TimeLib._findNextCollapse: the earliest collapse among the occupied
 * slots into `colSlot` / `colNext`; ties go to the lower slot. NONE when every
 * slot is empty.
 */
function findNextCollapse(colHour: readonly bigint[], w: Walk): void {
    let hour = NONE;
    let slot = 0n;
    for (let i = 0; i < colHour.length; i++) {
        if (colHour[i] < hour) {
            hour = colHour[i];
            slot = BigInt(i);
        }
    }
    w.colSlot = slot;
    w.colNext = hour;
}

/**
 * Mirror of TimeLib._advance: live the segment `cursor -> to` — power regen plus
 * the open portals' yield (capped at powerMax), and the overflow drain while
 * exactly twelve are open, with death inside the segment.
 */
function advance(g: Game, w: Walk, c: Config, to: bigint): void {
    if (to <= w.cursor) return;
    const delta = to - w.cursor;

    const np = g.power + (c.powerRegenPerHour + w.yieldSum) * delta;
    g.power = np > c.powerMax ? c.powerMax : trunc(np, 16);

    if (w.openCount === MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0n) {
        const ov = c.hpOverflowPerHour;
        const hToDeath = (g.hp + ov - 1n) / ov; // ceil(hp / ov)
        if (hToDeath <= delta) {
            w.died = true;
            w.deathHour = w.cursor + hToDeath;
            w.cursor = w.deathHour;
            g.hp = 0n;
            return;
        }
        // hToDeath > delta => ov*delta < hp, so no underflow.
        g.hp = trunc(g.hp - ov * delta, 16);
    }
    w.cursor = to;
}

/** Mirror of TimeLib._collapse: collapse the portal in slot `s` at hour `ch`. */
function collapse(
    g: Game,
    portals: Portal[],
    colHour: bigint[],
    w: Walk,
    c: Config,
    types: readonly PortalTypeParams[],
    events: Collapse[],
    s: bigint,
    ch: bigint,
): void {
    const p = portals[Number(s)];
    // Read all needed fields BEFORE blanking the slot.
    let deaths = p.creaturesKnown ? p.creatures : (p.creaturesLo + p.creaturesHi) / 2n;
    if (p.observerInside) deaths += 1n;
    if (p.rescuerInside) deaths += 1n;

    // An empty collapse still costs hpEmptyCollapse — it is the keeper's failure,
    // unlike closing an empty portal (free, §4.4).
    const hpLost = deaths > 0n ? c.hpCollapseBase + c.hpCollapsePerDeath * deaths : c.hpEmptyCollapse;
    const hpBefore = g.hp;
    const actualLost = hpBefore > hpLost ? hpLost : hpBefore; // min(loss, hp before the hit)

    // `deaths` truncates to uint8 in the event while the HP charge is for all of
    // them: two different numbers, deliberately.
    events.push({
        slot: s,
        deaths: trunc(deaths, 8),
        hpLost: trunc(actualLost, 16),
        atHour: trunc(ch, 32),
    });
    g.hp = trunc(hpBefore - actualLost, 16);

    // Crew inside dies and does NOT return to the pool (§4.3). The slot is freed:
    // a fresh zeroed portal (status == Empty).
    w.yieldSum = subChecked(w.yieldSum, types[p.portalType].powerYieldPerHour);
    portals[Number(s)] = emptyPortal();
    colHour[Number(s)] = NONE;
    w.openCount = subChecked(w.openCount, 1n);
    findNextCollapse(colHour, w);

    if (g.hp === 0n) {
        w.died = true;
        w.deathHour = ch;
    }
}

/**
 * Mirror of TimeLib._birth: birth of one portal at hour `b` into the first free
 * slot. The moment is deterministic; only the CONTENTS are random, drawn from the
 * seed of the birth hour's epoch, `epochSeed(wordFor(epoch), epoch)` with
 * `epoch = b / epochHours`. `rngNonce` is still bumped per portal: it no longer
 * feeds the spawn draw, but the bump keeps the nonce stream the blind-rescue path
 * reads unchanged.
 */
function birth(
    g: Game,
    portals: Portal[],
    colHour: bigint[],
    w: Walk,
    c: Config,
    types: readonly PortalTypeParams[],
    spawns: Spawn[],
    b: bigint,
): void {
    let slot = 0;
    while (portals[slot].status !== PortalStatus.Empty) slot++; // a slot is free: openCount < 12

    const epoch = b / c.epochHours;
    if (epoch !== w.seedEpoch) {
        w.seed = epochSeed(wordFor(epoch, w.oldWord, w.newWord, w.split), epoch);
        w.seedEpoch = epoch;
    }

    g.rngNonce = addChecked(g.rngNonce, 1n, 32); // vestigial for spawns; preserves the nonce stream
    g.spawnCount = addChecked(g.spawnCount, 1n, 32);
    const spawnId = g.spawnCount; // discriminator: unique per spawn within the epoch

    const portalType = Number(spawnDraw(w.seed, spawnId, SALT_TYPE) % 5n) as PortalType;
    const tp = types[portalType];

    // Exact, always-public collapse time inside the type's range.
    const span = subChecked(tp.hoursMax, tp.hoursMin) + 1n;
    const htc = trunc(tp.hoursMin + (spawnDraw(w.seed, spawnId, SALT_HOURS) % span), 16);
    const nameIndex = trunc(spawnDraw(w.seed, spawnId, SALT_NAME) % NAME_POOL_SIZE, 16);

    // Built FRESH from zeros, never copied from another portal: `surveyed`,
    // `surveyPending`, the crew flags and the exact values all stay at their
    // defaults, so the portal is unsurveyed and empty of people.
    const np = emptyPortal();
    np.id = trunc(spawnId, 16);
    np.portalType = portalType;
    np.nameIndex = nameIndex;
    np.status = PortalStatus.Open;
    np.hoursToCollapse = htc;
    np.spawnedAtHour = trunc(b, 32);
    np.snapshotAt = trunc(g.startedAt + b * w.sph, 40);
    np.energyLo = tp.energyMin;
    np.energyHi = tp.energyMax;
    np.stabilityLo = tp.stabilityMin;
    np.stabilityHi = tp.stabilityMax;
    np.creaturesLo = tp.creaturesMin;
    np.creaturesHi = tp.creaturesMax;
    portals[slot] = np;

    const ch = b + htc;
    colHour[slot] = ch;
    if (ch < w.colNext || (ch === w.colNext && BigInt(slot) < w.colSlot)) {
        w.colSlot = BigInt(slot);
        w.colNext = ch;
    }
    w.openCount += 1n;
    w.yieldSum += tp.powerYieldPerHour;
    w.births += 1n;

    spawns.push({ slot: BigInt(slot), portalType, nameIndex, atHour: trunc(b, 32) });
}

/**
 * Mirror of TimeLib._ageAll: age every open portal to hour `hTo` and re-snapshot
 * it at `stampTs` (whose game hour is `hTo`): `e = hTo - h(snapshotAt)`. Ageing
 * composes, which is what keeps a split catch-up equal to a single one.
 */
function ageAll(
    g: Game,
    portals: Portal[],
    c: Config,
    types: readonly PortalTypeParams[],
    sph: bigint,
    hTo: bigint,
    stampTs: bigint,
): void {
    for (let i = 0; i < Number(MAX_OPEN_PORTALS); i++) {
        const p = portals[i];
        if (p.status === PortalStatus.Empty) continue;
        const hSnap = subChecked(p.snapshotAt, g.startedAt) / sph;
        const e = subChecked(hTo, hSnap); // survivors have hoursToCollapse >= e
        if (p.surveyed) {
            const deg = types[p.portalType].degradePerHour * e;
            p.stability = p.stability > deg ? trunc(p.stability - deg, 8) : 0n;
        } else {
            // Unsurveyed: knowledge decays — the energy and stability ranges drift
            // outward by rangeWidenPerHour on each bound per game hour. The
            // CREATURES range is deliberately left untouched.
            const widen = c.rangeWidenPerHour * e;
            p.energyLo = p.energyLo > widen ? trunc(p.energyLo - widen, 8) : 0n;
            const eHi = p.energyHi + widen;
            p.energyHi = eHi > 100n ? 100n : trunc(eHi, 8);
            p.stabilityLo = p.stabilityLo > widen ? trunc(p.stabilityLo - widen, 8) : 0n;
            const sHi = p.stabilityHi + widen;
            p.stabilityHi = sHi > 100n ? 100n : trunc(sHi, 8);
        }
        p.hoursToCollapse = p.hoursToCollapse > e ? trunc(p.hoursToCollapse - e, 16) : 0n;
        p.snapshotAt = stampTs;
    }
}
