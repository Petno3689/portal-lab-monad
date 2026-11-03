import { useState } from 'react';
import { LIVE_V2 } from './presets';
import {
  CONFIG_FIELDS,
  PRESET_NAMES,
  TYPE_FIELDS,
  TYPE_NAMES,
  clampTo,
  cloneParams,
  paramsFromJson,
  paramsToJson,
  parseInput,
  type ConfigKey,
  type FieldMeta,
  type ParamSet,
  type PresetName,
  type TypeKey,
} from './params';

/** A whole-number input that commits valid values as they are typed and clamps on blur. */
function NumInput({ meta, value, onCommit }: { meta: FieldMeta<string>; value: bigint; onCommit: (v: bigint) => void }) {
  const [draft, setDraft] = useState<string | null>(null);
  const parsed = draft === null ? null : parseInput(meta, draft);
  return (
    <span className="numinput">
      <input
        type="text"
        inputMode="numeric"
        value={draft ?? value.toString()}
        aria-invalid={parsed !== null && !parsed.ok}
        onChange={(e) => {
          setDraft(e.target.value);
          const r = parseInput(meta, e.target.value);
          if (r.ok) onCommit(r.value);
        }}
        onBlur={() => {
          if (draft !== null) {
            const r = parseInput(meta, draft);
            if (r.ok) onCommit(r.value);
            else if (/^\d+$/.test(draft.trim())) onCommit(clampTo(meta, BigInt(draft.trim())));
          }
          setDraft(null);
        }}
      />
      {parsed && !parsed.ok && <span className="bad">{parsed.message}</span>}
    </span>
  );
}

interface Props {
  preset: PresetName;
  params: ParamSet;
  problem: string | null;
  onPreset: (name: PresetName) => void;
  /** Called with the edited set; the page switches the preset to Custom. */
  onEdit: (p: ParamSet) => void;
}

export function ParamsPanel({ preset, params, problem, onPreset, onEdit }: Props) {
  const [json, setJson] = useState('');
  const [jsonMsg, setJsonMsg] = useState<string | null>(null);

  const setConfig = (key: ConfigKey, v: bigint) => {
    if (params.config[key] === v) return;
    const next = cloneParams(params);
    next.config[key] = v;
    onEdit(next);
  };
  const setType = (i: number, key: TypeKey, v: bigint) => {
    if (params.types[i][key] === v) return;
    const next = cloneParams(params);
    next.types[i][key] = v;
    onEdit(next);
  };
  const setPrecise = (i: number, v: boolean) => {
    const next = cloneParams(params);
    next.types[i].surveyPrecise = v;
    onEdit(next);
  };

  const row = (f: FieldMeta<ConfigKey>) => {
    const value = params.config[f.key];
    const live = LIVE_V2.config[f.key];
    const lo = f.sliderMin ?? f.min;
    const hi = f.sliderMax ?? f.max;
    return (
      <div key={f.key} className={`param${value !== live ? ' diff' : ''}`}>
        <label htmlFor={`p-${f.key}`}>{f.label}</label>
        {f.main && hi - lo <= 100_000n && (
          <input
            id={`p-${f.key}`}
            type="range"
            min={Number(lo)}
            max={Number(hi)}
            value={Number(clampTo({ min: lo, max: hi }, value))}
            onChange={(e) => setConfig(f.key, clampTo(f, BigInt(e.target.value)))}
          />
        )}
        <NumInput meta={f} value={value} onCommit={(v) => setConfig(f.key, v)} />
        <span className="live">Live v2: {live.toString()}</span>
      </div>
    );
  };

  const copy = async () => {
    const text = paramsToJson(params);
    setJson(text);
    try {
      await navigator.clipboard.writeText(text);
      setJsonMsg('Copied to the clipboard (and shown below).');
    } catch {
      setJsonMsg('Clipboard unavailable — copy the text below.');
    }
  };
  const paste = async () => {
    let text = json.trim();
    if (!text) {
      try {
        text = await navigator.clipboard.readText();
        setJson(text);
      } catch {
        setJsonMsg('Paste the JSON into the box below, then press Paste JSON.');
        return;
      }
    }
    const r = paramsFromJson(text);
    if (r.ok) {
      onEdit(r.params);
      setJsonMsg('Parameters loaded.');
    } else {
      setJsonMsg(`Rejected: ${r.error}`);
    }
  };

  return (
    <section className="panel params">
      <h2>Parameters</h2>
      <p className="hint">Applied on “New game”; a running game keeps its configuration.</p>
      <div className="preset-row">
        <label htmlFor="preset">Preset</label>
        <select id="preset" value={preset} onChange={(e) => onPreset(e.target.value as PresetName)}>
          {PRESET_NAMES.map((n) => (
            <option key={n} value={n}>
              {n}
            </option>
          ))}
        </select>
      </div>
      {problem && <p className="bad">Invalid configuration: {problem}. “New game” is disabled.</p>}

      <div className="param-list">{CONFIG_FIELDS.filter((f) => f.main).map(row)}</div>

      <details>
        <summary>Advanced</summary>
        <div className="param-list">{CONFIG_FIELDS.filter((f) => !f.main).map(row)}</div>
        <h3>Portal types</h3>
        <div className="table-wrap">
          <table className="types">
            <thead>
              <tr>
                <th />
                {TYPE_NAMES.map((n) => (
                  <th key={n}>{n}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {TYPE_FIELDS.map((f) => (
                <tr key={f.key}>
                  <th scope="row">{f.label}</th>
                  {params.types.map((t, i) => (
                    <td key={i} className={t[f.key] !== LIVE_V2.types[i][f.key] ? 'diff' : ''}>
                      <NumInput meta={f} value={t[f.key]} onCommit={(v) => setType(i, f.key, v)} />
                    </td>
                  ))}
                </tr>
              ))}
              <tr>
                <th scope="row">Survey precise</th>
                {params.types.map((t, i) => (
                  <td key={i} className={t.surveyPrecise !== LIVE_V2.types[i].surveyPrecise ? 'diff' : ''}>
                    <input type="checkbox" aria-label={`${TYPE_NAMES[i]} survey precise`} checked={t.surveyPrecise} onChange={(e) => setPrecise(i, e.target.checked)} />
                  </td>
                ))}
              </tr>
            </tbody>
          </table>
        </div>
      </details>

      <div className="json-row">
        <button type="button" onClick={() => void copy()}>
          Copy as JSON
        </button>
        <button type="button" onClick={() => void paste()}>
          Paste JSON
        </button>
        {jsonMsg && <span className="hint">{jsonMsg}</span>}
      </div>
      <textarea rows={4} value={json} onChange={(e) => setJson(e.target.value)} placeholder="Parameter JSON" aria-label="Parameter JSON" />
    </section>
  );
}
