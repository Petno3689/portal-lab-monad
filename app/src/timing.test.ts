import { afterEach, describe, expect, it, vi } from 'vitest';
import { finish, mark, resetTimingForTests, startRun, timingEnabled } from './timing';

const setSearch = (search: string) => vi.stubGlobal('location', { search });

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  delete (globalThis as { __timings?: unknown }).__timings;
  resetTimingForTests();
});

describe('timing', () => {
  it('is a no-op without ?timing=1', () => {
    setSearch('');
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});
    expect(timingEnabled()).toBe(false);
    const id = startRun('x', {});
    mark(id, 'click');
    finish(id);
    expect(id).toBe(0);
    expect(info).not.toHaveBeenCalled();
    expect((globalThis as { __timings?: unknown }).__timings).toBeUndefined();
  });

  it('records stages and logs a row with ?timing=1', () => {
    setSearch('?foo=1&timing=1');
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});
    const id = startRun('Survey', { fn: 'act' });
    mark(id, 'click', { auto: false });
    mark(id, 'receipt', { blockNumber: '5' });
    finish(id);
    const rows = (globalThis as { __timings?: { label: string; stages: { stage: string; ms: number }[] }[] }).__timings!;
    expect(rows).toHaveLength(1);
    expect(rows[0].label).toBe('Survey');
    expect(rows[0].stages.map((s) => s.stage)).toEqual(['click', 'receipt']);
    expect(info).toHaveBeenCalledWith('[timing]', expect.stringContaining('"label":"Survey"'));
  });
});
