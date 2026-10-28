# Unstable Portals Lab — Front End

A Vite + React + TypeScript front end for the on-chain game "Лаборатория нестабильных порталов" (Unstable Portals Lab) on Monad testnet.

Live: https://portal-lab-monad.vercel.app

## What it does

- **Wallet.** Connects an injected wallet (MetaMask), switches it to Monad testnet, and can disconnect (the choice is remembered in local storage).
- **Reads from the contract.** `config` and `portalTypeParams` (both read once), `getGame`, `getPortals`, `getPending`, `bestRun`, `leaderboardSize`, `leaderboardPage`, `canAct`, `randomSource` and the random source's `fee()`. The player's `epochWord` has no getter and is read from contract storage (`getStorageAt` at slot `keccak256(abi.encode(player, 8)) + 15`: the `_players` mapping is declared at slot 8, and `epochWord` sits 15 slots after the start of a player's record). Deferred outcomes are read from the event log (`ActionPerformed`, `DeferredActionCancelled`). Game parameters are never hardcoded; they come from `config` and `portalTypeParams`.
- **Local projection.** Once per second the front end runs the TypeScript mirror from `../shared/src/` (`preview()`) on the last chain snapshot, so HP, portal ageing and elapsed game hours advance on screen between transactions without hitting the chain.
- **12-slot grid.** Each slot is empty or shows a portal with its type, status, hours to collapse and who is inside. Unsurveyed portals show ranges; surveyed ones show exact values.
- **Nine actions.** Toggle questioned, stabilize, destabilize, send observer, recall observer, send rescuer, recall rescuer, evacuate, close. Before sending, the front calls the contract's `canAct` and, if the action is refused, shows the text for the returned refusal code.
- **Two-phase Pyth flow.** Actions that need randomness (survey, blind rescuer entry, crossing into a new epoch) pay the Entropy fee and wait for the random word. A waiting banner is shown. The player can cancel the request once `requestTimeoutHours x secPerHour` seconds (both from `config`) have passed since it was committed; the banner shows the seconds left, and the Entropy fee is not refunded. When the word arrives, results are reported as follows: surveys and blind entries from the new state; other deferred actions from the contract's `ActionPerformed` and `DeferredActionCancelled` events, read from the block of the committing transaction — "applied", or "cancelled" with the reason ("the portal is gone or was replaced" for `PortalEmpty`).
- **Opening the lab.** A new game's first portals (the starting hand) are born at hour 0 once the first random word arrives. While the word is pending the banner reads "Opening the lab — waiting for the random word". There is no countdown.
- **Forecast.** The panel "Coming before the next random word (if you do nothing)" lists each upcoming birth (game hour, seconds remaining, portal type) and the hour the lab falls if that happens before the word's edge. It runs the shared `catchUp` up to the last second of the last covered hour.
- **Deaf hint.** After the first survey a Deaf portal shows "Narrowed — one more survey reads exact".
- **Run-over screen.** When HP reaches zero, the run is shown as over together with the player's best run.
- **Start / settle.** Start a game (with a forfeit confirmation when one is in progress) and settle a finished one. When the world is paused at the edge of its random word, the forfeit confirmation also tells the player to use "Sync (pays for word)" first, since the run may already have ended.
- **Journal.** A scrollable list of the current game's events for the account (spawns, collapses, closes, rescues, actions, surveys, cancellations, game over, settlement), newest first, at most 200 lines, built from the contract's event log. On load it scans backward from the latest block to this game's `GameStarted` (at most 50 chunks; otherwise "Older entries not loaded" is shown), then reads only new blocks on each state refresh. Lines are ordered by game hour, then block, then log index, because catch-up emits collapses before births.
- **Leaderboard.** Reads `leaderboardSize` and `leaderboardPage` (pages of 100), sorts by hours survived, creatures rescued, then earliest settlement, and shows the top 20 with the connected account highlighted (its own row is added below when it ranks lower). Readable without a wallet; refreshed after settle / start game. If the contract has no leaderboard views, the table is replaced by "Leaderboard is not available on this contract."
- **Chunked log reads.** The public RPC accepts `eth_getLogs` over about 101 blocks and rejects 1000, so every event-log read (journal, deferred-action outcomes) is split into sequential chunks of at most 100 blocks, filtered by contract address and the player topic. Deferred outcomes scan backward from the block where the pending action was seen to clear, at most 50 chunks.

## Setup

### Install

```bash
cd app
npm install
```

### Contract address

Set the deployed address in `src/config.ts`:

```typescript
export const PORTAL_LAB_ADDRESS = "0x..." as const;
```

After a redeploy, both this address and `src/PortalLab.abi.json` must match the new contract. If the storage layout of `Player` ever changes, update `PLAYERS_SLOT` and `EPOCH_WORD_OFFSET` in `src/contract.ts` as well.

### Development

```bash
npm run dev
```

On Windows, `localhost` may resolve to IPv6 and refuse the connection; use:

```bash
npm run dev -- --host 127.0.0.1
```

### Production build

```bash
npm run build
```

## Not built

- Session keys (every action is signed in the wallet)
- Front-end tests
