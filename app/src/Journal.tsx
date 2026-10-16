import { useEffect, useMemo, useRef, useState } from 'react';
import type { Address } from 'viem';
import { publicClient, readPlayerEvents, scanPlayerEventsBackward, type ChainState, type LabEvent } from './contract';
import { Action, ActionNames, getCancelReasonMessage, portalTypeNames } from './types';

const BACKFILL_CAP = 50;
const MAX_LINES = 200;

// Events that carry the game hour they happened at.
const HOUR_FIELD: Record<string, string> = {
  PortalSpawned: 'atHour',
  PortalCollapsed: 'atHour',
  PortalClosed: 'atHour',
  CreaturesRescued: 'atHour',
  ActionPerformed: 'atHour',
  SurveyRequested: 'atHour',
  PortalSurveyed: 'atHour',
  SurveyCancelled: 'atHour',
  DeferredActionCancelled: 'atHour',
  GameOver: 'atHour',
};

const before = (a: LabEvent, b: LabEvent) =>
  a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1;

const actionName = (a: unknown) => ActionNames[Number(a) as Action] ?? `Action ${a}`;

function describe(e: LabEvent, hour: number): string | null {
  const a = e.args;
  const slot = Number(a.slot);
  const h = `Hour ${hour}`;
  switch (e.eventName) {
    case 'GameStarted':
      return 'New game started';
    case 'PortalSpawned':
      return `${h}: a ${portalTypeNames[Number(a.portalType)] ?? 'Unknown'} portal opened in slot ${slot}`;
    case 'PortalCollapsed':
      return `${h}: slot ${slot} collapsed: ${a.deaths} deaths, −${a.hpLost} HP`;
    case 'PortalClosed':
      return `${h}: slot ${slot} closed: ${a.deaths} deaths, −${a.hpLost} HP`;
    case 'CreaturesRescued':
      return `${h}: ${a.count} creatures rescued from slot ${slot}, +${a.hpGained} HP`;
    case 'ActionPerformed':
      return `${h}: ${actionName(a.action)} on slot ${slot} (−${a.powerSpent} power)`;
    case 'SurveyRequested':
      return `${h}: observer sent to slot ${slot}, waiting for the random word`;
    case 'PortalSurveyed':
      return `${h}: survey of slot ${slot}: ${a.precise ? 'exact values' : 'ranges narrowed'}`;
    case 'SurveyCancelled':
      return `${h}: survey of slot ${slot} cancelled, ${a.powerRefunded} power refunded`;
    case 'DeferredActionCancelled':
      return `${h}: ${actionName(a.action)} on slot ${slot} cancelled: ${getCancelReasonMessage(Number(a.reason))}`;
    case 'RescuerRecovering':
      return `Rescuer from slot ${slot} recovers at hour ${a.readyAtHour}`;
    case 'GameOver':
      return `${h}: the lab fell`;
    case 'RunSettled':
      return `Run recorded: ${a.hoursSurvived} hours, ${a.creaturesRescued} creatures${a.newBest ? ' — new best' : ''}`;
    default:
      return null; // GameForfeited belongs to the previous game
  }
}

/** Journal lines, newest first: ordered by game hour, then block, then log index. */
function buildLines(events: LabEvent[]): string[] {
  const emitted = [...events].sort(before);
  // An event without an hour takes the hour of the previous event in emission order.
  let hour = 0;
  const timed = emitted.map((e) => {
    const field = HOUR_FIELD[e.eventName];
    if (e.eventName === 'GameStarted') hour = 0;
    else if (field) hour = Number(e.args[field]);
    return { e, hour };
  });
  timed.sort((x, y) => x.hour - y.hour || before(x.e, y.e));
  const lines: string[] = [];
  for (let i = timed.length - 1; i >= 0 && lines.length < MAX_LINES; i--) {
    const line = describe(timed[i].e, timed[i].hour);
    if (line) lines.push(line);
  }
  return lines;
}

interface Props {
  player: Address | null;
  state: ChainState | null;
}

/** The current game's events for `player`, read from the contract's event log. */
export function Journal({ player, state }: Props) {
  const [events, setEvents] = useState<LabEvent[]>([]);
  const [truncated, setTruncated] = useState(false);
  const startedAt = state?.game.startedAt ?? 0n;
  const key = player && startedAt !== 0n ? `${player}:${startedAt}` : null;

  // Last block read for `key`; null until the backfill has run.
  const readTo = useRef<{ key: string; block: bigint } | null>(null);
  // Runs are serialized: a refresh during a backfill waits for it.
  const queue = useRef<Promise<void>>(Promise.resolve());
  const currentKey = useRef<string | null>(null);
  currentKey.current = key;

  useEffect(() => {
    if (!key || !player) {
      readTo.current = null;
      setEvents([]);
      setTruncated(false);
      return;
    }
    if (readTo.current && readTo.current.key !== key) {
      readTo.current = null;
      setEvents([]);
      setTruncated(false);
    }
    queue.current = queue.current.then(async () => {
      if (currentKey.current !== key) return;
      try {
        const head = await publicClient.getBlockNumber();
        if (readTo.current === null) {
          let startLog: LabEvent | null = null;
          const { events: found, stopped } = await scanPlayerEventsBackward(player, 0n, head, BACKFILL_CAP, (chunk) => {
            const hit = chunk.find(
              (e) => e.eventName === 'GameStarted' && BigInt(e.args.startedAt as number | bigint) === startedAt,
            );
            if (hit) startLog = hit;
            return !!hit;
          });
          if (currentKey.current !== key) return;
          const start = startLog as LabEvent | null;
          const mine = start ? found.filter((e) => !before(e, start)) : found;
          readTo.current = { key, block: head };
          setEvents(mine);
          setTruncated(!stopped);
        } else if (head > readTo.current.block) {
          const fresh = await readPlayerEvents(player, readTo.current.block + 1n, head);
          if (currentKey.current !== key) return;
          readTo.current = { key, block: head };
          if (fresh.length > 0) setEvents((prev) => [...prev, ...fresh]);
        }
      } catch (error) {
        console.error('Journal read failed:', error);
      }
    });
  }, [key, player, state]);

  const lines = useMemo(() => buildLines(events), [events]);
  if (!key) return null;

  return (
    <div className="journal">
      <h3>Journal</h3>
      <div className="journal-lines">
        {lines.length === 0 && <p className="journal-empty">No entries yet.</p>}
        {lines.map((l, i) => (
          <div key={i} className="journal-line">
            {l}
          </div>
        ))}
        {truncated && <div className="journal-line journal-note">Older entries not loaded</div>}
      </div>
    </div>
  );
}
