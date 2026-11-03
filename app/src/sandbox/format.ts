/** Display helpers of the sandbox page: names and readable text for log entries. */

import { Action, Refusal, RiskLevel, type Portal } from '@shared/types';
import type { LogEntry } from './engine';
import { TYPE_NAMES } from './params';

export const ACTION_LABELS: Record<Action, string> = {
  [Action.ToggleQuestioned]: 'Flag',
  [Action.Stabilize]: 'Stabilize',
  [Action.Destabilize]: 'Destabilize',
  [Action.SendObserver]: 'Send observer',
  [Action.RecallObserver]: 'Recall observer',
  [Action.SendRescuer]: 'Send rescuer',
  [Action.RecallRescuer]: 'Recall rescuer',
  [Action.Evacuate]: 'Evacuate',
  [Action.Close]: 'Close',
};

export const ALL_ACTIONS: readonly Action[] = [
  Action.ToggleQuestioned,
  Action.Stabilize,
  Action.Destabilize,
  Action.SendObserver,
  Action.RecallObserver,
  Action.SendRescuer,
  Action.RecallRescuer,
  Action.Evacuate,
  Action.Close,
];

export const RISK_NAMES: Record<RiskLevel, string> = {
  [RiskLevel.Unknown]: 'Unknown',
  [RiskLevel.None]: 'None',
  [RiskLevel.Low]: 'Low',
  [RiskLevel.Medium]: 'Medium',
  [RiskLevel.High]: 'High',
  [RiskLevel.Critical]: 'Critical',
};

export const typeName = (t: number): string => TYPE_NAMES[t] ?? `type ${t}`;

/** "lo–hi", or the single value when the range is closed. */
export function range(lo: bigint, hi: bigint): string {
  if (hi < lo) return '?';
  return lo === hi ? lo.toString() : `${lo}–${hi}`;
}

export const energyOf = (p: Portal): string => range(p.energyLo, p.energyHi);
export const stabilityOf = (p: Portal): string => range(p.stabilityLo, p.stabilityHi);
export const creaturesOf = (p: Portal): string => (p.creaturesKnown ? p.creatures.toString() : range(p.creaturesLo, p.creaturesHi));

export function refusalLabel(r: Refusal | 'ActionPending'): string {
  return typeof r === 'string' ? r : Refusal[r];
}

/** m:ss for a number of seconds. */
export function clockText(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** One log entry as a line of text. */
export function logText(e: LogEntry): string {
  switch (e.kind) {
    case 'gameStarted':
      return 'Game started';
    case 'actionPerformed':
      return `h${e.hour} · slot ${e.slot}: ${ACTION_LABELS[e.action]} (power ${e.powerBefore} → ${e.powerAfter}, HP ${e.hpAfter})`;
    case 'actionRefused':
      return `h${e.hour} · slot ${e.slot}: ${ACTION_LABELS[e.action]} refused — ${refusalLabel(e.reason)}`;
    case 'deferralRequested':
      return `h${e.hour} · ${e.crossing ? 'word requested to cross the edge' : `slot ${e.slot}: ${ACTION_LABELS[e.action]} waits for a word`}`;
    case 'deferralResolved':
      return `h${e.hour} · slot ${e.slot}: ${ACTION_LABELS[e.action]} resolved`;
    case 'deferralCancelled':
      return `h${e.hour} · slot ${e.slot}: ${ACTION_LABELS[e.action]} cancelled — ${refusalLabel(e.reason)} (power back ${e.powerRefunded})`;
    case 'wordPinned':
      return `Word pinned: epochs ${e.fromEpoch}–${e.toEpoch}`;
    case 'portalCollapsed':
      return `h${e.hour} · slot ${e.slot}: portal COLLAPSED — ${e.deaths} lost, −${e.hpLost} HP`;
    case 'portalSpawned':
      return `h${e.hour} · slot ${e.slot}: ${typeName(e.portalType)} portal appeared`;
    case 'portalSurveyed':
      return `h${e.hour} · slot ${e.slot}: surveyed (${e.precise ? 'exact' : 'narrowed'})`;
    case 'portalClosed':
      return `h${e.hour} · slot ${e.slot}: portal closed — ${e.deaths} lost, −${e.hpLost} HP`;
    case 'creaturesRescued':
      return `h${e.hour} · slot ${e.slot}: ${e.count} rescued, +${e.hpGained} HP`;
    case 'rescuerRecovering':
      return `slot ${e.slot}: rescuer recovering until h${e.readyAtHour}`;
    case 'gameOver':
      return `h${e.hour}: GAME OVER`;
  }
}
