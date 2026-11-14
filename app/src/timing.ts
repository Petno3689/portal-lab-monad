// Opt-in stage timing (?timing=1). Everything here is a no-op unless the page URL has timing=1.

export type TimingExtra = Record<string, unknown>;

interface Stage {
  stage: string;
  perf: number;
  at: number;
  extra?: TimingExtra;
}

interface Run {
  label: string;
  meta: TimingExtra;
  startedAt: number;
  startPerf: number;
  stages: Stage[];
}

let enabled: boolean | null = null;
let nextId = 1;
const runs = new Map<number, Run>();

export function timingEnabled(): boolean {
  if (enabled === null) {
    try {
      enabled = new URLSearchParams(globalThis.location?.search ?? '').get('timing') === '1';
    } catch {
      enabled = false;
    }
  }
  return enabled;
}

/** Test hook: forget the cached flag and open runs. */
export function resetTimingForTests(): void {
  enabled = null;
  nextId = 1;
  runs.clear();
}

/** Opens a run and returns its id (0 when disabled). */
export function startRun(label: string, meta: TimingExtra = {}): number {
  if (!timingEnabled()) return 0;
  const id = nextId++;
  runs.set(id, { label, meta, startedAt: Date.now(), startPerf: performance.now(), stages: [] });
  return id;
}

export function mark(id: number, stage: string, extra?: TimingExtra): void {
  if (!timingEnabled() || !id) return;
  runs.get(id)?.stages.push({ stage, perf: performance.now(), at: Date.now(), extra });
}

export function finish(id: number): void {
  if (!timingEnabled() || !id) return;
  const run = runs.get(id);
  if (!run) return;
  runs.delete(id);
  const row = {
    label: run.label,
    ...run.meta,
    startedAt: run.startedAt,
    stages: run.stages.map((s) => ({ stage: s.stage, ms: Math.round(s.perf - run.startPerf), at: s.at, ...s.extra })),
  };
  const w = globalThis as unknown as { __timings?: unknown[] };
  (w.__timings ??= []).push(row);
  console.info('[timing]', JSON.stringify(row, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
}
