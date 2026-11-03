import { useEffect, useReducer, useState } from 'react';
import { PortalStatus } from '@shared/types';
import { view } from './engine';
import { Board } from './Board';
import { ParamsPanel } from './ParamsPanel';
import { clockText, logText } from './format';
import {
  buildExport,
  cloneParams,
  configProblem,
  exportFileName,
  loadCustom,
  presetParams,
  saveCustom,
  type ParamSet,
  type PresetName,
} from './params';
import { Session, summarize } from './session';

const TICK_MS = 250;
const LOG_LINES = 30;

function download(name: string, text: string): void {
  const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export default function Sandbox() {
  const [preset, setPreset] = useState<PresetName>('Live v2');
  const [params, setParams] = useState<ParamSet>(() => presetParams('Live v2'));
  const [delaysOn, setDelaysOn] = useState(true);
  const [session, setSession] = useState<Session | null>(null);
  const [startError, setStartError] = useState<string | null>(null);
  const [, redraw] = useReducer((n: number) => n + 1, 0);

  useEffect(() => {
    const id = setInterval(() => {
      session?.tick();
      redraw();
    }, TICK_MS);
    return () => clearInterval(id);
  }, [session]);

  const problem = configProblem(params);

  const onPreset = (name: PresetName) => {
    setPreset(name);
    setParams(name === 'Custom' ? (loadCustom() ?? params) : presetParams(name));
  };
  const onEdit = (p: ParamSet) => {
    setPreset('Custom');
    setParams(p);
    saveCustom(p);
  };
  const newGame = () => {
    try {
      setSession(new Session(cloneParams(params), preset, delaysOn));
      setStartError(null);
    } catch (e) {
      setStartError(e instanceof Error ? e.message : String(e));
    }
  };
  const toggleDelays = (on: boolean) => {
    setDelaysOn(on);
    session?.setDelays(on);
  };
  const exportLog = () => {
    if (!session) return;
    download(
      exportFileName(session.startedAt),
      buildExport({
        exportedAt: new Date(),
        preset: session.preset,
        startedAt: session.startedAt,
        delays: session.delaysAtStart,
        params: session.params,
        calls: session.calls,
        log: session.log,
      }),
    );
  };

  return (
    <main className="sandbox">
      <h1>Balance sandbox</h1>
      <p className="hint">Offline simulation of the lab on the sandbox engine. No wallet, no network; the live game is not affected.</p>

      <div className="toolbar">
        <button type="button" onClick={newGame} disabled={problem !== null}>
          New game
        </button>
        <button type="button" onClick={() => {
            session?.setPaused(!session.paused);
            redraw();
          }} disabled={!session || session.over}>
          {session?.paused ? 'Resume' : 'Pause'}
        </button>
        <label className="check">
          <input type="checkbox" checked={delaysOn} onChange={(e) => toggleDelays(e.target.checked)} />
          Chain-like delays
        </label>
        <button type="button" onClick={exportLog} disabled={!session}>
          Export game log
        </button>
      </div>
      {startError && <p className="bad">Cannot start: {startError}</p>}

      {session ? <Game session={session} /> : <p className="panel">Pick parameters below and press “New game”.</p>}

      <ParamsPanel preset={preset} params={params} problem={problem} onPreset={onPreset} onEdit={onEdit} />
    </main>
  );
}

function Game({ session }: { session: Session }) {
  const nowTs = session.clock.now();
  const v = view(session.state, nowTs);
  const c = session.state.config;
  const g = v.game;
  const hour = g.hoursElapsed;

  // Hours until the pinned edge (the last hour the pinned words cover).
  const covered = session.state.player.pending.coveredEpochs;
  const edge = covered > 0n ? covered * c.epochHours - 1n : null;

  // Power: regeneration per hour (reactor + open energetic portals) and time to the next regen hour.
  const open = v.portals.filter((p) => p.status !== PortalStatus.Empty);
  const perHour = c.powerRegenPerHour + open.reduce((s, p) => s + session.state.types[p.portalType].powerYieldPerHour, 0n);
  const gain = perHour < c.powerMax - g.power ? perHour : c.powerMax - g.power;
  const nextHourTs = g.startedAt + (hour + 1n) * c.secPerHour;
  const toNext = v.cappedShort || session.over ? null : Number(nextHourTs - nowTs);
  const powerPct = Number((g.power * 100n) / c.powerMax);

  const cells = [g.rescuerReadyAt0, g.rescuerReadyAt1, g.rescuerReadyAt2, g.rescuerReadyAt3];
  const cooldowns = cells.slice(0, Number(c.rescuersTotal)).filter((r) => r > hour).map((r) => `${r - hour} h`);

  const status = session.status();
  const log = session.log.slice(-LOG_LINES).reverse();
  const sum = session.over ? summarize(session) : null;

  return (
    <>
      <section className="panel header">
        <div>
          <strong>Hour {hour.toString()}</strong>
          {edge !== null && !session.over && <span> · edge in {(edge - hour).toString()} h</span>}
          <span> · played {clockText(session.playedMs() / 1000)}</span>
        </div>
        <div>
          HP <strong>{g.hp.toString()}</strong> / {c.hpMax.toString()}
        </div>
        <div>
          Power <strong>{g.power.toString()}</strong> / {c.powerMax.toString()}
          <span className="bar" aria-hidden="true">
            <span style={{ width: `${powerPct}%` }} />
          </span>
          {!session.over && (gain > 0n ? ` +${gain} in ${toNext === null ? '—' : `${toNext}s`}` : ' full')}
          <small> ({perHour.toString()}/h)</small>
        </div>
        <div>
          Observers {g.observersFree.toString()} / {c.observersTotal.toString()} free
        </div>
        <div>
          Rescuers {g.rescuersFree.toString()} / {c.rescuersTotal.toString()} free
          {cooldowns.length > 0 && <small> (recovering: {cooldowns.join(', ')})</small>}
        </div>
        <div className={`status status-${status.replace(/ /g, '-')}`}>
          {status}
          {session.note && <span className="bad"> · {session.note}</span>}
        </div>
      </section>

      {sum && (
        <section className="panel summary">
          <h2>Game over</h2>
          <ul>
            <li>Hours survived: {sum.hoursSurvived.toString()}</li>
            <li>Real duration: {clockText(Number(sum.realSeconds))}</li>
            <li>Actions performed: {sum.actions}</li>
            <li>Portals closed: {sum.portalsClosed}</li>
            <li>Portals collapsed: {sum.portalsCollapsed}</li>
            <li>Creatures rescued: {sum.creaturesRescued.toString()}</li>
          </ul>
          <p className="hint">Press “New game” (top) to play again.</p>
        </section>
      )}

      <Board session={session} v={v} />

      <section className="panel log">
        <h2>Log</h2>
        <ol>
          {log.map((e, i) => (
            <li key={session.log.length - i}>{logText(e)}</li>
          ))}
        </ol>
      </section>
    </>
  );
}
