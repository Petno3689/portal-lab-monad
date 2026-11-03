import { portalRisk } from '@shared/risk';
import { check, cost } from '@shared/rules';
import { PortalStatus, Refusal, type Portal } from '@shared/types';
import type { PreviewResult } from '@shared/preview';
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

export function Board({ session, v }: { session: Session; v: PreviewResult }) {
  const { config } = session.state;
  const canAct = session.canAct();
  const hour = v.game.hoursElapsed;
  const blocked = session.over ? 'game over' : session.paused ? 'paused' : session.status() === 'action in flight' ? 'action in flight' : 'waiting for a word';

  return (
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
        const tags = [
          p.status === PortalStatus.Questioned ? 'flagged' : '',
          p.observerInside ? 'observer inside' : '',
          p.rescuerInside ? 'rescuer inside' : '',
          p.surveyPending ? 'survey pending' : '',
          p.rescuerPending ? 'rescuer pending' : '',
        ].filter(Boolean);
        return (
          <div key={i} className={`slot risk-${RISK_NAMES[risk.level].toLowerCase()}`}>
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
  );
}
