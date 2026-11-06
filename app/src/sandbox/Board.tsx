import { portalRisk } from '@shared/risk';
import { check, cost } from '@shared/rules';
import { PortalStatus, Refusal, type Portal } from '@shared/types';
import type { EngineView } from './engine';
import { collapseText, dangerList, forecastBoard, type PortalForecast } from './forecast';
import { ALL_ACTIONS, ACTION_LABELS, RISK_NAMES, creaturesOf, energyOf, stabilityOf, typeName } from './format';
import type { Session } from './session';

function riskOf(p: Portal) {
  return portalRisk({
    status: p.status,
    surveyed: p.surveyed,
    stability: Number(p.stability),
    energy: Number(p.energy),
    hoursToCollapse: Number(p.hoursToCollapse),
    creatures: Number(p.creatures),
    observerInside: p.observerInside,
    rescuerInside: p.rescuerInside,
  });
}

/** The forecast block of one portal: when it collapses, and what that would cost now. */
function ForecastLine({ f, p, v2 }: { f: PortalForecast; p: Portal; v2: boolean }) {
  return (
    <div className={`slot-forecast${f.critical ? ' critical' : ''}`}>
      <span>{collapseText(f)}</span>
      {!p.surveyed && (
        <span>
          stability {stabilityOf(p)}: exact value unknown{v2 ? ` · V2 worst case: collapses once the upper bound (${p.stabilityHi}) hits 0` : ''}
        </span>
      )}
      <span>
        if it collapses now: −{f.hpLost.toString()} HP{f.fatal ? ' (FATAL)' : ''}
      </span>
    </div>
  );
}

export function Board({ session, v }: { session: Session; v: EngineView }) {
  const { config, types } = session.state;
  const forecasts = forecastBoard(v, config, types, session.variants);
  const danger = dangerList(forecasts);
  const v2 = session.variants.stabilityHealth.on;
  const canAct = session.canAct();
  const hour = v.game.hoursElapsed;
  const blocked = session.over ? 'game over' : session.paused ? 'paused' : session.status() === 'action in flight' ? 'action in flight' : 'waiting for a word';

  return (
    <>
      <div className={`danger-strip${danger.length > 0 ? ' active' : ''}`} role="status">
        <strong>Danger:</strong>{' '}
        {danger.length === 0
          ? 'nothing collapses within 2 h'
          : danger.map((f) => `#${f.slot} ${f.critical ? 'CRITICAL ' : ''}in ${f.collapsesIn} h (−${f.hpLost} HP${f.fatal ? ', FATAL' : ''})`).join(' · ')}
        {v2 && session.variants.stabilityHealth.jumpChancePct > 0n && <small> — V2 jumps can make any collapse sooner</small>}
      </div>
      <div className="board">
      {v.portals.map((p, i) => {
        const slot = BigInt(i);
        if (p.status === PortalStatus.Empty) {
          return (
            <div key={i} className="slot empty">
              slot {i} · empty
            </div>
          );
        }
        const risk = riskOf(p);
        const f = forecasts[i] as PortalForecast;
        const tags = [
          p.status === PortalStatus.Questioned ? 'flagged' : '',
          p.observerInside ? 'observer inside' : '',
          p.rescuerInside ? 'rescuer inside' : '',
          p.surveyPending ? 'survey pending' : '',
          p.rescuerPending ? 'rescuer pending' : '',
        ].filter(Boolean);
        return (
          <div key={i} className={`slot risk-${RISK_NAMES[risk.level].toLowerCase()} danger-${f.level}`}>
            <div className="slot-head">
              <strong>
                #{i} {typeName(p.portalType)}
              </strong>
              <span className="risk">
                risk: {RISK_NAMES[risk.level]}
                {p.surveyed ? ` (${risk.score})` : ''}
              </span>
            </div>
            <div className="slot-facts">
              <span>
                {p.hoursToCollapse} h left (collapse h{hour + p.hoursToCollapse})
              </span>
              <span>energy {energyOf(p)}</span>
              <span>stability {stabilityOf(p)}</span>
              <span>creatures {creaturesOf(p)}</span>
            </div>
            <ForecastLine f={f} p={p} v2={v2} />
            {tags.length > 0 && <div className="slot-tags">{tags.join(' · ')}</div>}
            <div className="slot-actions">
              {ALL_ACTIONS.map((a) => {
                const refusal = check(v.game, p, config, slot, a);
                const disabled = !canAct || refusal !== Refusal.None;
                const title = !canAct ? blocked : refusal !== Refusal.None ? Refusal[refusal] : '';
                return (
                  <button key={a} type="button" disabled={disabled} title={title} onClick={() => session.requestAction(slot, a)}>
                    {ACTION_LABELS[a]} <small>{cost(config, a).toString()}</small>
                  </button>
                );
              })}
            </div>
          </div>
        );
      })}
      </div>
    </>
  );
}
