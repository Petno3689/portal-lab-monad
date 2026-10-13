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

## Why Monad

One game hour is fifteen real seconds, and the world ages lazily: whenever
the contract is next touched, it computes the whole elapsed span in closed
form. A player therefore signs a transaction every few seconds, and almost
every one of them carries both a Pyth Entropy request and a catch-up over
the game hours that passed while the transaction was in flight.

That shape only works where blocks are fast and gas is cheap. On a slower
chain the clock outruns the blocks: the world a player acts on is already
stale by the time the action lands, and the catch-up grows with every second
of latency. On an expensive chain the per-action fee makes a twenty-minute
session absurd. Monad is what makes real-time play affordable at per-action
granularity.

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

The on-chain work is based on the game design of an off-chain React/TypeScript
prototype. That prototype was built starting 14 September 2026, inside the
hackathon period, as a separate off-chain exercise. The on-chain contracts in
`contracts/`, the TypeScript mirror in `shared/`, and the front end in `app/`
were written afterwards, also inside the hackathon period. `forge-std`
(`contracts/lib/forge-std/`) is vendored external code, not written for this
project.

## Repository history

This repository holds only a handful of commits, all of them recent. That is
because the on-chain project was moved into a repository of its own on
12 October 2026; it says nothing about when the work was done. Work on the
design started on 14 September 2026 in the earlier repository, and the
contract first reached Monad testnet on 30 September 2026 (`docs/SPEC.md`,
section 14.2). The earlier history lives in a separate private repository that
also contains unrelated work, so it is not published.
