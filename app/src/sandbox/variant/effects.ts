/**
 * SANDBOX FORK of shared/src/effects.ts `applyAction` (the EffectsLib.sol mirror),
 * with the action variants V3–V5. It exists only for the balance sandbox.
 *
 * The fork is a wrapper, not a copy: it runs the mirror's `applyAction` unchanged
 * and then applies the variant's extra effect to the result. Each variant only ADDS
 * to what the mirror did (V5 replaces the rescuer's return with a rest), so a copy
 * would only be a second place for the mirror's arithmetic to drift. With V3–V5 off
 * the result is the mirror's, untouched.
 *
 *   V3 stabilizeExtends      Stabilize: hoursToCollapse += hours, capped at uint16.
 *   V4 rescuerTakesObserver  Evacuate: if an observer is inside, it comes back too
 *                            (observerInside = false, observersFree + 1). Applied
 *                            before V5, which concerns the rescuer only.
 *   V5 rescuerRestAfterEvac  Evacuate: the rescuer does not return to the pool; it
 *                            takes a free rescuerReadyAt cell with
 *                            readyAt = hoursElapsed + hours, released by the catch-up
 *                            exactly like a blind-miss rescuer. hours = 0 means no
 *                            rest (the rescuer returns at once, as in the mirror).
 *
 * V6 (pressure per action) is not an effect of one action's rule but of performing
 * any action, including the two-phase commits that never reach `applyAction`; it is
 * applied by the engine through `addActionPressure`.
 */

import {
  ContractRevert,
  NO_FREE_RESCUER_CELL,
  SPAWN_DEBT_MAX,
  addChecked,
  applyAction,
  rescuerReadyAt,
  setRescuerReadyAt,
  subChecked,
  trunc,
  type Outcome,
} from '@shared/effects';
import { Action, MAX_RESCUERS, type Config, type Game, type Portal, type PortalTypeParams } from '@shared/types';
import type { VariantSet } from './variants';

const U16_MAX = 65_535n;

/** The mirror's Outcome plus the V5 rest (`rescuerRestReadyAt` is 0 when none). */
export interface VOutcome extends Outcome {
  rescuerRestReadyAt: bigint;
}

export function applyActionVariant(
  g0: Game,
  p0: Portal,
  c: Config,
  tp: PortalTypeParams,
  a: Action,
  v: VariantSet,
): { game: Game; portal: Portal; outcome: VOutcome } {
  const fx = applyAction(g0, p0, c, tp, a);
  const game: Game = { ...fx.game };
  const portal: Portal = { ...fx.portal };
  const outcome: VOutcome = { ...fx.outcome, rescuerRestReadyAt: 0n };

  if (a === Action.Stabilize && v.stabilizeExtends.on) {
    const h = portal.hoursToCollapse + v.stabilizeExtends.hours;
    portal.hoursToCollapse = h > U16_MAX ? U16_MAX : h;
  }

  if (a === Action.Evacuate) {
    if (v.rescuerTakesObserver.on && p0.observerInside) {
      portal.observerInside = false;
      game.observersFree = addChecked(game.observersFree, 1n, 8);
    }
    if (v.rescuerRestAfterEvac.on && v.rescuerRestAfterEvac.hours > 0n) {
      // Undo the mirror's return to the pool, then park the rescuer in a cell.
      game.rescuersFree = subChecked(game.rescuersFree, 1n);
      const readyAt = trunc(game.hoursElapsed + v.rescuerRestAfterEvac.hours, 32);
      let placed = false;
      for (let cell = 0n; cell < MAX_RESCUERS; cell++) {
        if (rescuerReadyAt(game, cell) === 0n) {
          setRescuerReadyAt(game, cell, readyAt);
          placed = true;
          break;
        }
      }
      if (!placed) throw new ContractRevert(NO_FREE_RESCUER_CELL);
      outcome.rescuerRestReadyAt = readyAt;
    }
  }

  return { game, portal, outcome };
}

/** V6: a performed action adds `value` to spawnDebt, capped as closePressureBonus is. */
export function addActionPressure(g: Game, v: VariantSet): Game {
  if (!v.pressurePerAction.on || v.pressurePerAction.value === 0n) return g;
  const debt = g.spawnDebt + v.pressurePerAction.value;
  return { ...g, spawnDebt: debt > SPAWN_DEBT_MAX ? SPAWN_DEBT_MAX : trunc(debt, 32) };
}
