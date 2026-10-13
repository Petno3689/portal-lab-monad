# Лаборатория нестабильных порталов (Unstable Portals Lab)

A fully on-chain survival game on Monad testnet. You play a lab overseer
watching a grid of unstable magical portals: survey them, stabilize or
destabilize them, send observers and rescuers, evacuate trapped creatures,
and close portals before they collapse. There is no backend — the Solidity
contract is the sole source of truth, time passes by real wall-clock seconds
(not player turns), and the goal is simply to keep the lab's HP above zero
for as long as you can.

## Deployed addresses (Monad testnet, chain id 10143)

| Contract | Address |
|---|---|
| `PortalLab` | `0x0DF83BfFE9b7071f29524964ed1D8Ef84bA2829c` |
| `PythEntropySource` | `0x70c1D0AF77594CC2Dd2650Ea8c979092a42C156F` |

## Architecture

- **`contracts/`** — the Solidity domain, built with Foundry. `PortalLab` is
  the game contract (state, actions, time catch-up, the leaderboard); it
  draws randomness through `PythEntropySource`, an `IRandomSource`
  implementation backed by Pyth Entropy V2's two-phase request/callback flow.
  Risk, rules, effects and time-aging math live in dedicated libraries
  (`RiskLib`, `RulesLib`, `EffectsLib`, `TimeLib`) so they can be tested and
  reasoned about independently of game-loop glue.
- **`shared/`** — a TypeScript mirror of the on-chain rules, using `BigInt`
  fixed-point arithmetic that matches the contract's integer math exactly.
- **`app/`** — the React + Vite front end. It reads game state from the
  chain with viem and submits actions as transactions.

**Why the mirror exists.** The contract ages the world lazily: a portal's
state is a pure function of its last snapshot and elapsed time, so the
contract never loops over missed hours. That means the front end has to
compute the same aging and risk formulas itself to animate the world
smoothly between transactions — if it guessed differently from the contract,
a player would see an action as available, click it, and get a revert. Since
the front end needs its own copy of the rules regardless, that copy doubles
as an independent cross-check: `shared/test/vectors/` holds golden-vector
corpora (risk, rules, effects, time, catch-up, spawns, preview) generated
from Solidity (`contracts/script/Gen*Vectors.s.sol`) and verified against
both the Solidity test suite and the TypeScript mirror, so the two
implementations are checked against the same numbers rather than against
each other's assumptions.

## Stack

Foundry, Solidity 0.8.28, Pyth Entropy V2, React, Vite, viem.

## Setup

### Contracts

```bash
cd contracts
forge build
forge test
```

### Shared TypeScript mirror

```bash
cd shared
npm install
npm test
npm run typecheck
```

### Front end

```bash
cd app
npm install
npm run dev
```

On Windows, plain `localhost` can resolve to IPv6 and refuse the connection;
if that happens, run `npm run dev -- --host 127.0.0.1` and open that address
instead.

## AI tool disclosure

This project was built with Claude. Claude Code wrote the contract, test and
front-end code; a reviewing Claude session wrote the tickets handed to Claude
Code and reviewed every diff before it landed.

## Pre-existing components

An off-chain React/TypeScript prototype of the same game existed before this
hackathon. The on-chain contracts in `contracts/`, the TypeScript mirror in
`shared/`, and the front end in `app/` were all written for this submission,
targeting that earlier prototype's game design. `forge-std`
(`contracts/lib/forge-std/`) is vendored external code, not written for this
project.
