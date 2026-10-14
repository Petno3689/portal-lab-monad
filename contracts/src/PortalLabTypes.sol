// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Data model for the on-chain "Unstable Portals Lab" game (Monad).
/// @notice Enums and structs, plus the two free accessors for the packed rescuer
/// cooldown ledger (`rescuerReadyAt` / `setRescuerReadyAt`) — the only logic here,
/// and only because the four-scalar packing that keeps `Game` at two slots needs
/// an array-like face. The struct field order and types are load-bearing: they
/// determine storage packing (see NatSpec on `Portal` and `Game`). Do not reorder
/// for cosmetics.

/// @dev Maximum number of portals a game holds at once. This is the size of
/// the fixed portal array, not a tunable parameter — hence a `constant`.
uint256 constant MAX_OPEN_PORTALS = 12;

/// @dev Fuse on the number of events (collapses plus births) one catch-up may
/// process. Sizes the event arrays `TimeLib.catchUp` returns. When it is exhausted
/// the walk stops at the hour of the last processed event and reports it like the
/// pinned edge (`cappedShort`), so the next call continues. With the deployed
/// configuration a real game never reaches it: every collapse costs HP
/// (`hpEmptyCollapse > 0`, enforced at deploy), an unsurveyed newborn's collapse
/// costs at least `hpCollapseBase + hpCollapsePerDeath`, and HP never exceeds
/// `hpMax`. A protocol bound, not a tunable — hence a `constant`.
uint256 constant MAX_CATCHUP_EVENTS = 64;

/// @dev Upper bound on the number of rescuers a game may have. Bounds the
/// rescuer cooldown ledger in `Game` (the `rescuerReadyAt0..3` cells);
/// `Config.rescuersTotal` is validated against it at deploy. A protocol
/// invariant, not a tunable — hence a `constant`.
///
/// @dev NOTE ON REPRESENTATION: the cooldown ledger is FOUR SCALAR FIELDS, not a
/// `uint32[MAX_RESCUERS]` array, and this is load-bearing for storage packing. A
/// Solidity fixed array ALWAYS starts a fresh storage slot (and the field after
/// it starts another), so an array would push `Game` from two slots to three and
/// `Player` from fourteen to fifteen (measured: Game 96 bytes, Player 480). Four
/// `uint32` scalars instead pack into the second slot beside `spawnCount`/
/// `rngNonce` (8 + 16 = 24 of 32 bytes), keeping `Game` at exactly two slots and
/// `Player` at fourteen. The free functions `rescuerReadyAt` / `setRescuerReadyAt`
/// (below) give the four fields an array-like interface so the logic still reads
/// as a loop. DO NOT "tidy" the four fields into an array — it silently costs an
/// extra storage slot per player.
uint256 constant MAX_RESCUERS = 4;

/// @dev Raised by `rescuerReadyAt` / `setRescuerReadyAt` for an index outside
/// `[0, MAX_RESCUERS)`. A silent no-op or a returned zero would corrupt the
/// cooldown ledger (zero means "free cell"), so an out-of-range access reverts.
error RescuerIndexOutOfRange(uint8 index);

/// @dev Ceiling for the accumulated spawn pressure (`Game.spawnDebt`). A very
/// long absence would otherwise overflow the `uint32` field; pressure saturates
/// here instead of wrapping. This is a protocol invariant, not a tunable —
/// hence a `constant` rather than a `Config` field (SPEC §7).
uint256 constant SPAWN_DEBT_MAX = 1_000_000_000;

/// @dev Size of the portal name pool. Names themselves are NOT stored on-chain
/// (a string in storage costs gas per byte and the contract has no use for it);
/// a portal keeps only `nameIndex`, and the front end maps the index to a name
/// (SPEC §7). This constant bounds that index.
uint256 constant NAME_POOL_SIZE = 24;

/// @notice Portal archetype. One byte in storage, drives a lot of behaviour
/// (SPEC §4.5). The order fixes the enum's integer values and must match the
/// order of the per-type parameter table `PortalTypeParams[5]`.
enum PortalType {
    Flash, // 0
    LongLived, // 1
    Deaf, // 2
    Resonant, // 3
    Energetic // 4
}

/// @notice Risk level of a portal, derived from its numeric risk score (SPEC
/// §4.1). `Unknown` — not surveyed yet; `None` — empty slot. The score→level
/// thresholds live in `RiskLib.levelOf`. `Critical` is a gate: it forbids
/// sending people into the portal, so the 84/85 boundary is load-bearing.
enum RiskLevel {
    Unknown, // 0
    None, // 1
    Low, // 2
    Medium, // 3
    High, // 4
    Critical // 5
}

/// @notice Actions the player can take on a portal (SPEC §4.2).
/// Order is part of the specification — the TS mirror repeats it exactly.
enum Action {
    ToggleQuestioned,
    Stabilize,
    Destabilize,
    SendObserver,
    RecallObserver,
    SendRescuer,
    RecallRescuer,
    Evacuate,
    Close
}

/// @notice Reason an action was refused (SPEC §4.2).
/// `None` (0) means the action is allowed.
/// The order is part of the specification — the TS mirror repeats it exactly.
enum Refusal {
    None,
    GameNotActive,
    InvalidSlot,
    PortalEmpty,
    NotSurveyed,
    SurveyPending,
    ObserverAlreadyInside,
    NoObserverInside,
    NoObserverFree,
    RescuerAlreadyInside,
    NoRescuerInside,
    NoRescuerFree,
    NoCreatures,
    RiskTooHigh,
    NotUnstableEnough,
    NotEnoughPower,
    /// @dev Not a rule refusal: the random word never arrived within
    /// `Config.requestTimeoutHours` and the deferral was cancelled (Ticket 4.7).
    /// Lets logs tell a provider failure from a game-rule refusal.
    RandomnessTimeout
}

/// @notice Slot occupancy / lifecycle of a portal. There is deliberately no
/// "Closed" state: closing or collapsing frees the slot back to `Empty`, and the
/// history lives in events (SPEC §9).
enum PortalStatus {
    Empty, // 0 — free slot
    Open, // 1
    Questioned // 2 — flagged "under question" by the player
}

/// @notice A single portal.
/// @dev Packed into one 32-byte storage slot by declaration order (32 bytes
/// of 32 used). All fields together fit without crossing a slot boundary:
///   id(2) + portalType(1) + nameIndex(1) + status(1) + surveyed(1)
///   + narrowedOnce(1) + observerInside(1) + rescuerInside(1) + surveyPending(1)
///   + rescuerPending(1) + creaturesKnown(1) + energy(1) + stability(1)
///   + creatures(1) + hoursToCollapse(2) + spawnedAtHour(4) + snapshotAt(5)
///   + energyLo/Hi + stabilityLo/Hi + creaturesLo/Hi(6)
///   = 32 bytes.
///
/// The range fields (energyLo/Hi, stabilityLo/Hi, creaturesLo/Hi) are
/// meaningful only while `surveyed == false`; after survey the exact values
/// are written into energy/stability/creatures.
///
/// `hoursToCollapse` is always exact and public (even before survey): the
/// collapse moment must be computable from the snapshot for the lazy-time
/// formula (SPEC §5). Only energy, stability and creatures are hidden behind
/// ranges until survey.
struct Portal {
    uint16 id;
    PortalType portalType;
    uint8 nameIndex; // index into the name pool (NAME_POOL_SIZE = 24)
    PortalStatus status;
    bool surveyed;
    /// @dev True after a non-precise (Deaf) survey narrowed this portal; the
    /// NEXT survey then reads exact values like a precise type.
    bool narrowedOnce;
    bool observerInside;
    bool rescuerInside;
    bool surveyPending;
    /// @dev Set at the COMMIT of a two-phase blind rescue (Ticket 4.6). Cleared on
    /// reveal (success or cancel). Used at reveal to detect "portal is still the
    /// one the rescuer was sent to" vs "portal collapsed while the word was in flight".
    bool rescuerPending;
    /// @dev True when `creatures` holds the exact count. Distinct from
    /// `surveyed`: a blind rescue sets creaturesKnown without completing a
    /// full survey (surveyed stays false). The two flags diverge on blind entry.
    bool creaturesKnown;
    uint8 energy; // exact, 0..100, after survey
    uint8 stability; // exact, 0..100, after survey
    uint8 creatures; // exact, after survey
    uint16 hoursToCollapse; // exact always, as of the snapshot
    uint32 spawnedAtHour; // game hour the portal appeared
    uint40 snapshotAt; // block.timestamp of the last parameter snapshot
    uint8 energyLo; // range fields: meaningful only while surveyed == false
    uint8 energyHi;
    uint8 stabilityLo;
    uint8 stabilityHi;
    uint8 creaturesLo;
    uint8 creaturesHi;
}

/// @notice One player's game (SPEC §3.2).
/// @dev Packs into two 32-byte slots:
///   Slot 0: startedAt(5) + lastTickAt(5) + hoursElapsed(4) + diedAtHour(4)
///           + hp(2) + power(2) + observersFree(1) + rescuersFree(1)
///           + openPortals(1) + finished(1) + spawnDebt(4) = 30 bytes.
///   Slot 1: spawnCount(4) + rngNonce(4) + rescuerReadyAt0..3(16)
///           + creaturesRescued(4) + settled(1) = 29 bytes.
/// `startedAt == 0` means "no game".
struct Game {
    uint40 startedAt; // 0 — no game
    uint40 lastTickAt; // base for lazy time
    uint32 hoursElapsed; // game hours lived (the score)
    uint32 diedAtHour; // game hour of death
    uint16 hp;
    uint16 power; // lab resource
    uint8 observersFree; // free crew
    uint8 rescuersFree;
    uint8 openPortals; // occupied slots
    bool finished;
    uint32 spawnDebt; // accumulated spawn pressure
    uint32 spawnCount; // counter for ids and names
    uint32 rngNonce; // roll counter for the RNG stub (bumped per survey)
    /// @dev Cooldown ledger for rescuers who walked into an empty portal and
    /// left for recovery (SPEC §4.3). Each occupied cell holds the game hour at
    /// which that rescuer rejoins `rescuersFree`; 0 means the cell is free.
    /// `TimeLib.catchUp` frees any cell whose hour has arrived by comparison
    /// against the current hour, never a per-hour loop.
    ///
    /// Four scalars, NOT a `uint32[MAX_RESCUERS]` array, so the ledger packs into
    /// this second slot instead of forcing a third (see `MAX_RESCUERS`). The free
    /// functions `rescuerReadyAt` / `setRescuerReadyAt` index them as if they were
    /// an array; the count of live cells never exceeds
    /// `Config.rescuersTotal <= MAX_RESCUERS`.
    uint32 rescuerReadyAt0;
    uint32 rescuerReadyAt1;
    uint32 rescuerReadyAt2;
    uint32 rescuerReadyAt3;
    uint32 creaturesRescued; // total creatures pulled out alive this run
    bool settled; // true once the run result has been recorded in _bestRun
}

/// @notice Permanent per-address best-run record (SPEC §15). One 32-byte slot:
///   hoursSurvived(4) + creaturesRescued(4) + settledAt(4) + runsSettled(4) = 16 bytes.
struct BestRun {
    uint32 hoursSurvived; // ranking key
    uint32 creaturesRescued; // tiebreaker
    uint32 settledAt; // block.timestamp of the last best-run update
    uint32 runsSettled; // total finished runs recorded (incremented every settle)
}

/// @notice Read cooldown cell `i` of `g` (game hour the rescuer rejoins the pool;
/// 0 means the cell is free). Array-like accessor over the four packed scalars
/// (see the note on `MAX_RESCUERS` for why they are not an array). Used by both
/// `EffectsLib` and `TimeLib`. An index `>= MAX_RESCUERS` reverts.
function rescuerReadyAt(Game memory g, uint8 i) pure returns (uint32) {
    if (i == 0) return g.rescuerReadyAt0;
    if (i == 1) return g.rescuerReadyAt1;
    if (i == 2) return g.rescuerReadyAt2;
    if (i == 3) return g.rescuerReadyAt3;
    revert RescuerIndexOutOfRange(i);
}

/// @notice Write cooldown cell `i` of `g` to `v`. `g` is memory, passed by
/// reference, so the write is visible to the caller. An index `>= MAX_RESCUERS`
/// reverts rather than silently dropping the write.
function setRescuerReadyAt(Game memory g, uint8 i, uint32 v) pure {
    if (i == 0) {
        g.rescuerReadyAt0 = v;
    } else if (i == 1) {
        g.rescuerReadyAt1 = v;
    } else if (i == 2) {
        g.rescuerReadyAt2 = v;
    } else if (i == 3) {
        g.rescuerReadyAt3 = v;
    } else {
        revert RescuerIndexOutOfRange(i);
    }
}

/// @notice A single deferred (two-phase) action awaiting its random word (SPEC
/// §6.3). At most ONE per player: while `active`, every new action is refused.
/// @dev Packs into ONE 32-byte storage slot (26 of 32 bytes used):
///   active(1) + action(1) + slot(1) + atHour(4) + requestId(8) + coveredEpochs(4)
///   + deferredWorld(1) + syncOnly(1) + committedAt(5) = 26 bytes.
/// This is what keeps `Player` at sixteen slots rather than seventeen — the
/// fields must stay scalar and small; do not widen `requestId` past `uint64`
/// (it mirrors a Pyth sequence number) or add a field that overflows the slot.
/// The per-portal `Portal.surveyPending` flag marks WHICH portal is being
/// surveyed (and gates `RecallObserver`); this struct carries the rest — which
/// action, which request, and when — that a portal flag cannot.
///
/// `coveredEpochs` lives in this slot per Ticket 4.5 §2.4 but is GAME state, not
/// deferral state: it is the count of spawn epochs pinned to `Player.epochWord`
/// (epoch `e` uses that word iff `e < coveredEpochs`; `0` means none pinned yet).
/// It therefore must OUTLIVE a deferral — `receiveWord` clears `active`/
/// `requestId` by hand rather than `delete`ing the struct, which would wipe it.
/// `startGame`'s whole-`Player` delete resets it to 0, as a fresh game intends.
///
/// `deferredWorld` distinguishes the two deferral shapes. `false` — the legacy
/// in-epoch survey (Ticket 4.4): the world was already aged to now at commit and
/// the observer walked in; reveal only writes the survey draws. `true` — an
/// epoch-crossing deferral (Ticket 4.5): the world was NOT aged at commit because
/// the catch-up needs the new word for spawns; reveal ages the world in full
/// (old word for epochs `< coveredEpochs`, new word beyond) and only THEN applies
/// the action. `syncOnly` marks a `true`-deferral carrying no action — a paid
/// `sync` that merely drives the world across the epoch edge (§4.4 amended).
struct Pending {
    bool active; // a deferred action is outstanding
    Action action; // which action was deferred
    uint8 slot; // the portal slot it targets
    uint32 atHour; // game hour the commit was fixed at
    uint64 requestId; // id returned by the random source; matched on delivery
    uint32 coveredEpochs; // GAME state: spawn epochs pinned to Player.epochWord
    bool deferredWorld; // true = epoch-crossing deferral (reveal ages the world)
    bool syncOnly; // true = paid sync with no action to apply on reveal
    uint40 committedAt; // block.timestamp of the commit; the timeout clock (REAL time)
}

/// @notice Combines a player's game state, their portal array, any deferred
/// action, and the current spawn-entropy word in one mapping entry so that a
/// single action touches one contiguous storage region. On Monad (128-slot
/// pages, SPEC §14.1) a Game (2 slots) + Portal[12] (12 slots) + Pending (1 slot)
/// + epochWord (1 slot) = 16 slots fit on one or two pages, versus crossing
/// unpredictably many pages with two separate mappings.
///
/// @dev `epochWord` is the one random word currently pinned to this player's
/// spawn epochs (Ticket 4.5 §2.1): epoch `e`'s seed is derived from it while
/// `e < pending.coveredEpochs`. A full 32-byte slot — a word cannot be packed —
/// which is the sixteenth and last slot the budget allows (§2.4). It is 0 at a
/// fresh game; the first epoch-crossing action fetches a real word for it.
struct Player {
    Game game;
    Portal[MAX_OPEN_PORTALS] portals;
    Pending pending;
    uint256 epochWord;
}

/// @notice Per-type balance parameters (SPEC §4.5). One entry per `PortalType`,
/// stored in a separate table so tuning does not touch logic. All values are
/// placeholders to be tuned.
struct PortalTypeParams {
    uint16 hoursMin; // life span at spawn
    uint16 hoursMax;
    uint8 degradePerHour; // stability lost per game hour
    uint8 energyMin; // spawn range
    uint8 energyMax;
    uint8 stabilityMin;
    uint8 stabilityMax;
    uint8 creaturesMin;
    uint8 creaturesMax;
    uint16 actionMultiplierPct; // stabilize/destabilize strength, 100 = normal
    uint8 powerYieldPerHour; // resource produced while open
    bool surveyPrecise; // false — survey only narrows the range
}

/// @notice Immutable-after-deploy game configuration (SPEC §3.4). Written once
/// in the constructor; there are no setters. Kept in storage (not `immutable`)
/// because it is a large struct — `immutable` does not support structs — and on
/// Monad the contiguous layout reads in a single cold access (SPEC §14.1).
struct Config {
    // time
    uint32 secPerHour;
    uint16 longAbsenceHours;
    // HP
    uint16 hpMax;
    uint16 hpStart; // starting HP (≤ hpMax); the main handle for tuning run length
    uint16 hpCollapseBase;
    uint16 hpCollapsePerDeath;
    uint16 hpEmptyCollapse;
    uint16 hpOverflowPerHour;
    uint16 healPerCreature;
    // resource
    uint16 powerMax;
    uint16 powerRegenPerHour;
    // action costs
    uint16 costToggleQuestioned;
    uint16 costStabilize;
    uint16 costDestabilize;
    uint16 costSendObserver;
    uint16 costRecallObserver;
    uint16 costSendRescuer;
    uint16 costRecallRescuer;
    uint16 costEvacuate;
    uint16 costClose;
    // crew
    uint8 observersTotal;
    uint8 rescuersTotal;
    uint16 rescuerCooldownHours; // game hours a rescuer recovers after walking into an empty portal (SPEC §4.3)
    // closing thresholds
    uint8 closeStabilityBelow;
    uint16 closeHoursAtMost;
    // spawns (pressure in units; one unit = 1/spawnCostUnits of a portal, SPEC §4.6/§7).
    // There is no per-transaction spawn cap: a portal is born at the hour its
    // pressure matures, whoever calls and whenever (TimeLib.catchUp).
    uint32 basePressurePerHour; // pressure gained per game hour at the start
    uint32 pressureRampPerHour; // extra pressure per hour added for each lived hour
    uint32 spawnCostUnits; // pressure one portal costs
    uint32 closePressureBonus; // pressure added immediately when a portal is closed
    // survey / knowledge decay (SPEC §3.1)
    uint8 rangeWidenPerHour; // per game hour, each energy/stability bound drifts out
    // spawn entropy (Ticket 4.5)
    /// @dev Length of a spawn epoch in game hours. One random word is pinned per
    /// epoch, so a player can predict spawns at most `epochHours` hours ahead and
    /// no further (Ticket 4.5 §6.8). Packs into the free tail of Config slot 2
    /// (closePressureBonus 4 + rangeWiden 1 + deafNarrow 1 + epochHours 2 = 8 of
    /// 32 bytes); Config stays at three slots. Validated `> 0` at deploy.
    uint16 epochHours;
    /// @dev Game hours after a deferral's commit at which anyone may cancel it
    /// (Ticket 4.7). Measured in REAL time (`block.timestamp`), not game hours.
    /// Packs into Config slot 2 after epochHours; Config stays at three slots.
    /// Validated `> 0` at deploy.
    uint16 requestTimeoutHours;
}
