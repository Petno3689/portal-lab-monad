import { useState } from 'react';
import { LIVE_V2 } from './presets';
import {
  CONFIG_FIELDS,
  PRESET_NAMES,
  TYPE_FIELDS,
  TYPE_NAMES,
  clampTo,
  cloneParams,
  parseInput,
  settingsFromJson,
  settingsToJson,
  type ConfigKey,
  type FieldMeta,
  type ParamSet,
  type PresetName,
  type TypeKey,
} from './params';
import { DEFAULT_VARIANTS, VARIANT_META, variantNumber, withVariant, type VariantSet } from './variant/variants';

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

/**
 * One numeric field: label, slider (main fields with a range of at most 100 000),
 * typed input, and the reference value next to it; highlighted when it differs.
 */
function FieldRow({
  id,
  meta,
  value,
  reference,
  referenceLabel,
  onCommit,
}: {
  id: string;
  meta: FieldMeta<string>;
  value: bigint;
  reference: bigint;
  referenceLabel: string;
  onCommit: (v: bigint) => void;
}) {
  const lo = meta.sliderMin ?? meta.min;
  const hi = meta.sliderMax ?? meta.max;
  return (
    <div className={`param${value !== reference ? ' diff' : ''}`}>
      <label htmlFor={id}>{meta.label}</label>
      {meta.main && hi - lo <= 100_000n && (
        <input
          id={id}
          type="range"
          min={Number(lo)}
          max={Number(hi)}
          value={Number(clampTo({ min: lo, max: hi }, value))}
          onChange={(e) => onCommit(clampTo(meta, BigInt(e.target.value)))}
        />
      )}
      <NumInput meta={meta} value={value} onCommit={onCommit} />
      <span className="live">
        {referenceLabel}: {reference.toString()}
      </span>
    </div>
  );
}

interface Props {
  preset: PresetName;
  params: ParamSet;
  /** The rule variants, for "Copy as JSON". */
  variants: VariantSet;
  problem: string | null;
  onPreset: (name: PresetName) => void;
  /** Called with the edited set; the page switches the preset to Custom. */
  onEdit: (p: ParamSet) => void;
  /** "Paste JSON": a parameter set and its rule variants (absent in the JSON: all off). */
  onPaste: (p: ParamSet, v: VariantSet) => void;
}

export function ParamsPanel({ preset, params, variants, problem, onPreset, onEdit, onPaste }: Props) {
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

  const row = (f: FieldMeta<ConfigKey>) => (
    <FieldRow
      key={f.key}
      id={`p-${f.key}`}
      meta={f}
      value={params.config[f.key]}
      reference={LIVE_V2.config[f.key]}
      referenceLabel="Live v2"
      onCommit={(v) => setConfig(f.key, v)}
    />
  );

  const copy = async () => {
    const text = settingsToJson(params, variants);
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
    const r = settingsFromJson(text);
    if (r.ok) {
      onPaste(r.params, r.variants);
      setJsonMsg('Parameters and rule variants loaded.');
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

/** The "Rule variants" panel: sandbox-only rule changes, applied on "New game". */
export function VariantsPanel({ variants, problem, onEdit }: { variants: VariantSet; problem: string | null; onEdit: (v: VariantSet) => void }) {
  return (
    <section className="panel variants">
      <h2>Rule variants</h2>
      <p className="hint">Candidate rule changes, sandbox only. Applied on “New game”; all off is the live contract’s rules.</p>
      {problem && <p className="bad">Invalid rule variants: {problem}. “New game” is disabled.</p>}
      {VARIANT_META.map((m) => {
        const on = variants[m.id].on;
        return (
          <div key={m.id} className={`variant${on ? ' on' : ''}`}>
            <label className="check variant-head">
              <input type="checkbox" checked={on} onChange={(e) => onEdit(withVariant(variants, m.id, 'on', e.target.checked))} />
              <strong>{m.label}</strong>
            </label>
            <p className="hint">{m.description}</p>
            {m.id === 'criticalPhase' && on && !variants.stabilityHealth.on && <p className="bad">Has no effect while V2 is off.</p>}
            {m.fields.map((f) => {
              const value = variantNumber(variants, m.id, f.key);
              return (
                <FieldRow
                  key={f.key}
                  id={`v-${m.id}-${f.key}`}
                  meta={f}
                  value={value}
                  reference={variantNumber(DEFAULT_VARIANTS, m.id, f.key)}
                  referenceLabel="default"
                  onCommit={(v) => {
                    if (v !== value) onEdit(withVariant(variants, m.id, f.key, v));
                  }}
                />
              );
            })}
          </div>
        );
      })}
    </section>
  );
}
