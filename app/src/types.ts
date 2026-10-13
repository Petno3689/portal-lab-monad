import { Action, Refusal } from '@shared/types';

export { Action, Refusal };

// Refusal texts from docs/SPEC.md §4.2. RandomnessTimeout (16) is not in that
// table; its text follows the same style.
const RefusalMessages: Record<Refusal, string> = {
  [Refusal.None]: '—',
  [Refusal.GameNotActive]: 'Game is not active',
  [Refusal.InvalidSlot]: 'Invalid slot',
  [Refusal.PortalEmpty]: 'Slot is empty',
  [Refusal.NotSurveyed]: 'Portal not surveyed',
  [Refusal.SurveyPending]: 'Survey in progress',
  [Refusal.ObserverAlreadyInside]: 'Observer already inside',
  [Refusal.NoObserverInside]: 'No observer inside',
  [Refusal.NoObserverFree]: 'No free observer',
  [Refusal.RescuerAlreadyInside]: 'Rescuer already inside',
  [Refusal.NoRescuerInside]: 'No rescuer inside',
  [Refusal.NoRescuerFree]: 'No free rescuer',
  [Refusal.NoCreatures]: 'No creatures in the portal',
  [Refusal.RiskTooHigh]: 'Risk too high',
  [Refusal.NotUnstableEnough]: 'Portal not unstable enough',
  [Refusal.NotEnoughPower]: 'Not enough power',
  [Refusal.RandomnessTimeout]: 'Random word did not arrive in time',
};

export function getRefusalMessage(refusal: number): string {
  return RefusalMessages[refusal as Refusal] ?? `Refused (${refusal})`;
}

export const ActionNames: Record<Action, string> = {
  [Action.ToggleQuestioned]: 'Toggle Questioned',
  [Action.Stabilize]: 'Stabilize',
  [Action.Destabilize]: 'Destabilize',
  [Action.SendObserver]: 'Send Observer',
  [Action.RecallObserver]: 'Recall Observer',
  [Action.SendRescuer]: 'Send Rescuer',
  [Action.RecallRescuer]: 'Recall Rescuer',
  [Action.Evacuate]: 'Evacuate',
  [Action.Close]: 'Close',
};
