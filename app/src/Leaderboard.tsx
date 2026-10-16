import { useEffect, useMemo, useState } from 'react';
import type { Address } from 'viem';
import { readLeaderboard, type LeaderboardRow } from './contract';

const TOP = 20;

const shorten = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** Hours survived desc, creatures rescued desc, earliest settlement first. */
function compare(a: LeaderboardRow, b: LeaderboardRow): number {
  if (a.run.hoursSurvived !== b.run.hoursSurvived) return a.run.hoursSurvived > b.run.hoursSurvived ? -1 : 1;
  if (a.run.creaturesRescued !== b.run.creaturesRescued) return a.run.creaturesRescued > b.run.creaturesRescued ? -1 : 1;
  if (a.run.settledAt !== b.run.settledAt) return a.run.settledAt < b.run.settledAt ? -1 : 1;
  return 0;
}

interface Props {
  account: Address | null;
  /** Changes whenever the leaderboard should be re-read. */
  refreshKey: number;
}

export function Leaderboard({ account, refreshKey }: Props) {
  const [rows, setRows] = useState<LeaderboardRow[] | null>(null);
  const [unavailable, setUnavailable] = useState(false);

  useEffect(() => {
    let live = true;
    readLeaderboard()
      .then((r) => {
        if (!live) return;
        setRows(r);
        setUnavailable(false);
      })
      .catch((error) => {
        console.error('Leaderboard not available:', error);
        if (live) setUnavailable(true);
      });
    return () => {
      live = false;
    };
  }, [refreshKey]);

  const sorted = useMemo(() => (rows ? [...rows].sort(compare) : []), [rows]);
  const me = account ? account.toLowerCase() : null;
  const myIndex = me ? sorted.findIndex((r) => r.player.toLowerCase() === me) : -1;

  const row = (r: LeaderboardRow, rank: number) => (
    <tr key={r.player} className={r.player.toLowerCase() === me ? 'leaderboard-me' : undefined}>
      <td>{rank}</td>
      <td className="leaderboard-address">{shorten(r.player)}</td>
      <td>{String(r.run.hoursSurvived)}</td>
      <td>{String(r.run.creaturesRescued)}</td>
    </tr>
  );

  return (
    <div className="leaderboard">
      <h3>Leaderboard</h3>
      {unavailable ? (
        <p>Leaderboard is not available on this contract.</p>
      ) : rows === null ? (
        <p>Loading…</p>
      ) : sorted.length === 0 ? (
        <p>No settled runs yet.</p>
      ) : (
        <>
          <table>
            <thead>
              <tr>
                <th>Rank</th>
                <th>Player</th>
                <th>Hours</th>
                <th>Creatures</th>
              </tr>
            </thead>
            <tbody>{sorted.slice(0, TOP).map((r, i) => row(r, i + 1))}</tbody>
          </table>
          {myIndex >= TOP && (
            <table className="leaderboard-own">
              <tbody>{row(sorted[myIndex], myIndex + 1)}</tbody>
            </table>
          )}
        </>
      )}
    </div>
  );
}
