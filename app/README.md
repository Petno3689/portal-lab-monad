# Unstable Portals Lab — Minimal Playable Front End

A Vite + React + TypeScript front end for the on-chain game "Лаборатория нестабильных порталов" (Unstable Portals Lab) on Monad testnet.

## What's Built

### 1. **Wallet Connection** ✅
- MetaMask integration with automatic chain detection
- Automatic switch to Monad testnet (chain ID 10143)
- Display of connected address and wallet controls

### 2. **Game State Reading** ✅
- Reads contract state: `config()`, `getGame(player)`, `portalTypes()`, `bestRun(player)`
- Loads full game state including 12 portals and their parameters
- Handles both surveyed (exact values) and unsurveyed (range) portals

### 3. **Local Time Projection** ✅ (The critical piece)
- Imports the TypeScript mirror from `../shared/src/`
- Calls `preview()` once per second with current timestamp
- Advances the displayed world in real-time without hitting the chain
- Shows HP depletion, portal degradation, and hour accumulation between transactions
- Makes the game feel alive and responsive

### 4. **Portal Display** ✅
- 12-slot grid showing all portals
- For empty slots: shows "Empty"
- For open portals: displays type, hours to collapse, occupancy, survey status

### 5. **Action System** ✅
All nine actions (codes 0–8):
- 0: Toggle Questioned (?)
- 1: Stabilize (⬆)
- 2: Destabilize (⬇)
- 3: Send Observer (👁)
- 4: Recall Observer (🔙)
- 5: Send Rescuer (🚀)
- 6: Recall Rescuer (🔙)
- 7: Evacuate (✈)
- 8: Close (✖)

### 6. **Game Flow** ✅
- Start Game, Perform Actions, Settle Game
- Transaction handling with MetaMask
- Auto-refresh after transactions

### 7. **UI/UX** ✅
- Dark theme suited for game
- Responsive grid layout
- Real-time state projection (every second)

## Setup & Running

### Install Dependencies
```bash
cd app
npm install
```

### Set Contract Address
**CRITICAL:** Update `src/config.ts` with deployed address:
```typescript
export const PORTAL_LAB_ADDRESS = "0x..."
```

### Development
```bash
npm run dev
```

### Production Build
```bash
npm run build
```

## What's NOT Implemented
- ❌ Session keys
- ❌ Tests
- ❌ Design system or animations
- ❌ Leaderboard table
- ❌ Two-phase Pyth integration

## Untested (Requires Live Chain)
- Actual contract state reading (no RPC access in build environment)
- Transaction submission (requires deployed contract)
- Event listening

**Status:** Ready to demo, untested on live chain ✅
