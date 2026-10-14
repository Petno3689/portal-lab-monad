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

These are the currently live deployment. The contract on this branch is a
newer version that has not been deployed yet; the addresses will be replaced
when it is.

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

**Why the mirror exists.** The contract ages the world lazily: on each call
it brings the stored state forward by walking the events of the elapsed
window (portal collapses and births) in chronological order, never the hours
one by one. The walk is capped at `MAX_CATCHUP_EVENTS` (64) events per
transaction; if the window holds more, the world stops short and the next
call continues. Each event's hour follows from the stored snapshot and the
pinned random word; the current time only decides how far the walk goes. That means the front end has to compute the same aging and risk
formulas itself to animate the world smoothly between transactions — if it
guessed differently from the contract, a player would see an action as
available, click it, and get a revert. The front end also runs the mirror's
`catchUp` to draw its forecast of upcoming births. Since the front end needs
its own copy of the rules regardless, that copy doubles as an independent
cross-check: `shared/test/vectors/` holds golden-vector
corpora (risk, rules, effects, time, catch-up, spawns, preview) generated
from Solidity (`contracts/script/Gen*Vectors.s.sol`) and verified against
both the Solidity test suite and the TypeScript mirror, so the two
implementations are checked against the same numbers rather than against
each other's assumptions.

## Why Monad

One game hour is fifteen real seconds, and the world ages lazily: whenever
the contract is next touched, it walks the collapses and births of the whole
elapsed span in order, up to a fixed cap of events per transaction. A player
therefore signs a transaction every few seconds, and every one of them
carries a catch-up over the game hours that passed while the transaction was
in flight. A Pyth Entropy request is made only when needed: by a survey, a
blind rescuer entry, or an action that crosses into a new epoch (one random
word per 36 game hours, i.e. 9 real minutes; `epochHours` 36 x `secPerHour`
15 in `GameConfig`).

That shape only works where blocks are fast and gas is cheap. On a slower
chain the clock outruns the blocks: the world a player acts on is already
stale by the time the action lands, and the catch-up grows with every second
of latency. On an expensive chain the per-action fee makes a twenty-minute
session absurd. Monad is what makes real-time play affordable at per-action
granularity.

## Determinism and fairness

- **A free sync cannot reshape the world.** The stored world depends only on
  time and the pinned random word: one sync to time `c` gives the same state
  as a sync to `b` followed by a sync to `c`
  (`contracts/test/BirthAtMaturity.t.sol`, `test_SplitInvariance_*`).
- **Births are public within a word.** A portal is born at the first hour its
  spawn pressure matures and a slot is free (`TimeLib.catchUp`). Within one
  random word the world is deterministic and public: the front end shows
  every upcoming birth up to the edge of the current word, assuming the player
  does nothing, and that forecast is the same computation the contract
  performs. Each random word covers 36 game hours; the next one is drawn when
  an action crosses that edge.
- **A deferred action is bound to its portal.** The pending request stores
  the target portal's id; if that portal collapsed and a new one was born in
  the slot before the word arrived, the action is cancelled with
  `PortalEmpty` instead of hitting the new portal (`PortalLab.sol`,
  `p.id != pend.portalId`).
- **Deaf portals take two surveys.** The first survey narrows the ranges, the
  second reads exact values (`EffectsLib.sol`, `narrowedOnce`).
- **A stuck randomness request can be cancelled.** The player can call
  `cancelDeferred` once 15 real seconds have passed since the request
  (`requestTimeoutHours` 1 x `secPerHour` 15), anyone else after 600 real
  seconds (`outsiderTimeoutHours` 40 x 15). The wait is measured in real
  time, not game hours, because a request stuck at an epoch edge freezes the
  game clock. The Entropy fee is not refunded.
- **The deployed contracts are source-verified** with Sourcify and shown on
  MonadVision.

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
