/**
 * Danger forecast of the balance sandbox board: for every open portal, when it will
 * collapse if nobody acts, and what the collapse would cost. SANDBOX ONLY.
 *
 * The forecast is the engine's own rule read forward, not an estimate of its own:
 *
 *   - the scheduled collapse comes `hoursToCollapse` hours from the view's hour;
 *   - with V2 on, the early-collapse condition (surveyed: stability 0; unsurveyed:
 *     stabilityHi 0) is checked at every hour step h > now, after the hour's ageing:
 *     a surveyed portal's stability at now + k is max(0, s − degradePerHour × k), so
 *     the condition first holds at k = ceil(s / degradePerHour) (k = 1 if s is 0
 *     already, never if nothing degrades); an unsurveyed portal's upper bound only
 *     widens, so it holds only if it is 0 already and nothing widens;
 *   - with V2b on, the condition starts a critical phase of `hours` instead, and an
 *     existing mark (variant/time.ts) collapses the portal at its untilHour if the
 *     condition still holds at the next step — otherwise the mark goes and a new
 *     phase starts when the condition comes back;
 *   - at an equal hour the scheduled collapse wins (the mirror's events come before
 *     the hour step), which changes the cause, not the hour.
 *
 * Random V2 jumps can only make a collapse SOONER; the forecast assumes none, and
 * `jumpsMaySpeed` says when that assumption is a real one. V1 arrivals change only the
 * damage, never the hour. The damage is `collapseDamage` — the function the engine's
 * collapse uses — on the portal as it stands now.
 */

import { PortalStatus, type Config, type Portal } from '@shared/types';
import type { EngineView } from './engine';
import type { TypeTable } from './presets';
import { collapseDamage, type CriticalMark } from './variant/time';
import type { VariantSet } from './variant/variants';

export type DangerLevel = 'red' | 'amber' | 'none';

/** Red at ≤ RED_HOURS hours to the collapse (or while critical), amber at ≤ AMBER_HOURS. */
export const RED_HOURS = 2n;
export const AMBER_HOURS = 4n;

export interface PortalForecast {
  slot: number;
  /** Hours from the view's hour to the collapse, if nobody acts and no jump comes. */
  collapsesIn: bigint;
  /** What ends it: the scheduled hour, V2 stability 0, or the end of a V2b critical phase. */
  cause: 'scheduled' | 'stability' | 'critical';
  /** hoursToCollapse. */
  scheduledIn: bigint;
  /** V2 on: hours until the stability condition first holds (null: not in sight or V2 off). */
  zeroIn: bigint | null;
  /** V2 on and jumps can happen: the real collapse may come sooner. */
  jumpsMaySpeed: boolean;
  /** V2b: the portal is critical; `holds` — the condition still holds at the next step. */
  critical: { untilHour: bigint; holds: boolean } | null;
  /** If it collapsed now (collapseDamage, before the cap at the HP left). */
  deaths: bigint;
  hpLost: bigint;
  /** The collapse would take every HP left. */
  fatal: boolean;
  level: DangerLevel;
}

/** Steps k ≥ 1 from now until the V2 condition first holds with no jumps, or null. */
function stepsToCondition(p: Portal, c: Config, types: TypeTable): bigint | null {
  if (p.surveyed) {
    if (p.stability === 0n) return 1n;
    const d = types[p.portalType].degradePerHour;
    return d > 0n ? (p.stability + d - 1n) / d : null;
  }
  return p.stabilityHi === 0n && c.rangeWidenPerHour === 0n ? 1n : null;
}

export function forecastPortal(
  p: Portal,
  slot: number,
  hour: bigint,
  hp: bigint,
  c: Config,
  types: TypeTable,
  v: VariantSet,
  marks: readonly CriticalMark[] = [],
): PortalForecast {
  const v2 = v.stabilityHealth.on;
  const v2b = v2 && v.criticalPhase.on;
  const mark = v2b ? marks.find((m) => m.portalId === p.id) : undefined;
  const k = v2 ? stepsToCondition(p, c, types) : null;

  // Hours to the V2 / V2b collapse, or null.
  let viaStability: bigint | null = null;
  if (k !== null) {
    if (!v2b) viaStability = k;
    else if (mark && k === 1n) viaStability = mark.untilHour > hour + 1n ? mark.untilHour - hour : 1n;
    else viaStability = k + v.criticalPhase.hours;
  }

  const scheduledIn = p.hoursToCollapse;
  const early = viaStability !== null && viaStability < scheduledIn;
  const collapsesIn = early ? (viaStability as bigint) : scheduledIn;
  const cause = early ? (v2b ? 'critical' : 'stability') : 'scheduled';
  const { deaths, hpLost } = collapseDamage(p, c);

  const level: DangerLevel = collapsesIn <= RED_HOURS || mark ? 'red' : collapsesIn <= AMBER_HOURS ? 'amber' : 'none';
  return {
    slot,
    collapsesIn,
    cause,
    scheduledIn,
    zeroIn: k,
    jumpsMaySpeed: v2 && v.stabilityHealth.jumpChancePct > 0n && v.stabilityHealth.jumpMax > 0n,
    critical: mark ? { untilHour: mark.untilHour, holds: k === 1n } : null,
    deaths,
    hpLost,
    fatal: hpLost >= hp,
    level,
  };
}

/** One forecast per slot of the view (null for an empty slot). */
export function forecastBoard(view: EngineView, c: Config, types: TypeTable, v: VariantSet): (PortalForecast | null)[] {
  const hour = view.game.hoursElapsed;
  return view.portals.map((p, i) =>
    p.status === PortalStatus.Empty ? null : forecastPortal(p, i, hour, view.game.hp, c, types, v, view.critical ?? []),
  );
}

/** The red portals, worst first: soonest collapse, then the heavier one, then the lower slot. */
export function dangerList(fs: readonly (PortalForecast | null)[]): PortalForecast[] {
  return fs
    .filter((f): f is PortalForecast => f !== null && f.level === 'red')
    .sort((a, b) => {
      if (a.collapsesIn !== b.collapsesIn) return a.collapsesIn < b.collapsesIn ? -1 : 1;
      if (a.hpLost !== b.hpLost) return a.hpLost > b.hpLost ? -1 : 1;
      return a.slot - b.slot;
    });
}

/** The collapse estimate as a line of text. */
export function collapseText(f: PortalForecast): string {
  if (f.critical) {
    if (f.critical.holds) return `CRITICAL — collapses in ${f.collapsesIn} h`;
    return `CRITICAL, saved — stability above 0, clears next hour · collapses in ${f.collapsesIn} h`;
  }
  const why = f.cause === 'stability' ? ' (stability → 0)' : f.cause === 'critical' ? ' (stability → 0, then critical)' : '';
  return `collapses in ${f.collapsesIn} h${why}${f.jumpsMaySpeed ? ' · jumps can make it sooner' : ''}`;
}
