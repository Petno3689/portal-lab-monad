# Unstable Portals Lab — Front End

A Vite + React + TypeScript front end for the on-chain game "Лаборатория нестабильных порталов" (Unstable Portals Lab) on Monad testnet.

Live: https://portal-lab-monad.vercel.app

## What it does

- **Wallet.** Connects an injected wallet (MetaMask), switches it to Monad testnet, and can disconnect (the choice is remembered in local storage).
- **Reads from the contract.** `config`, `portalTypeParams`, `getGame`, `getPortals`, `getPending` and `bestRun`. Game parameters are never hardcoded; they come from `config` and `portalTypeParams`.
- **Local projection.** Once per second the front end runs the TypeScript mirror from `../shared/src/` (`preview()`) on the last chain snapshot, so HP, portal ageing and elapsed game hours advance on screen between transactions without hitting the chain.
- **12-slot grid.** Each slot is empty or shows a portal with its type, status, hours to collapse and who is inside. Unsurveyed portals show ranges; surveyed ones show exact values.
- **"Forming" marks.** Portals that exist only in the projection (not yet written on chain) are marked "Forming" and become real on the next transaction.
- **Nine actions.** Toggle questioned, stabilize, destabilize, send observer, recall observer, send rescuer, recall rescuer, evacuate, close. Before sending, the front calls the contract's `canAct` and, if the action is refused, shows the text for the returned refusal code.
- **Two-phase Pyth flow.** Actions that need randomness (survey, blind rescuer entry, crossing into a new epoch) pay the Entropy fee and wait for the random word. A waiting banner is shown; after the contract timeout the request can be cancelled (the fee is not refunded). When the word arrives, the result of the action is reported.
- **Opening the lab.** A new game starts with an empty lab; a message counts down to the first portals and then waits for the random word.
- **Run-over screen.** When HP reaches zero, the run is shown as over together with the player's best run.
- **Start / settle.** Start a game (with a forfeit confirmation when one is in progress) and settle a finished one.

## Setup

### Install

```bash
cd app
npm install
```

### Contract address

Update `src/config.ts` with the deployed address:

```typescript
export const PORTAL_LAB_ADDRESS = "0x..."
```

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
- A leaderboard table (only the player's own best run is shown)
- Front-end tests
