import { PortalStatus, type Config, type Game, type Portal } from '@shared/types';

/**
 * Latest hour at which the lab falls if no new random word arrives, or null if the portals
 * already standing at the edge cannot kill it. It is an upper bound: beyond the edge births
 * can only add HP loss (healing comes only from player actions), so the lab falls at this
 * hour or earlier. Mirrors the collapse rule of TimeLib._collapse; collapses at an equal
 * hour go in ascending slot order.
 */
export function fallsNoLaterThan(game: Game, portals: Portal[], config: Config): bigint | null {
  if (game.finished) return null;
  const collapses = portals
    .map((p, slot) => ({ p, slot }))
    .filter(({ p }) => p.status !== PortalStatus.Empty)
    .map(({ p, slot }) => ({
      p,
      slot,
      hour: (p.snapshotAt - game.startedAt) / config.secPerHour + p.hoursToCollapse,
    }))
    .sort((a, b) => (a.hour < b.hour ? -1 : a.hour > b.hour ? 1 : a.slot - b.slot));

  let hp = game.hp;
  for (const { p, hour } of collapses) {
    let deaths = p.creaturesKnown ? p.creatures : (p.creaturesLo + p.creaturesHi) / 2n;
    if (p.observerInside) deaths += 1n;
    if (p.rescuerInside) deaths += 1n;
    const hpLost = deaths > 0n ? config.hpCollapseBase + config.hpCollapsePerDeath * deaths : config.hpEmptyCollapse;
    hp -= hpLost < hp ? hpLost : hp;
    if (hp === 0n) return hour;
  }
  return null;
}
