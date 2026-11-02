import { describe, expect, it } from 'vitest';
import { createRateLimitedFetch } from './rpcLimiter';

/** A virtual clock: sleep advances time instantly. */
function setup(maxPerSecond: number, fetchImpl?: (n: number) => Promise<unknown>) {
  let t = 0;
  const started: Array<{ id: number; at: number }> = [];
  const fetch = (id: number) => {
    started.push({ id, at: t });
    return fetchImpl ? fetchImpl(id) : Promise.resolve(id);
  };
  const limited = createRateLimitedFetch({
    fetch,
    maxPerSecond,
    now: () => t,
    sleep: async (ms: number) => {
      t += ms;
    },
  });
  return { limited, started };
}

describe('createRateLimitedFetch', () => {
  it('starts calls within the limit at once', async () => {
    const { limited, started } = setup(3);
    await Promise.all([limited(1), limited(2), limited(3)]);
    expect(started.map((s) => s.at)).toEqual([0, 0, 0]);
  });

  it('makes the call over the limit wait until the window frees', async () => {
    const { limited, started } = setup(2);
    await Promise.all([limited(1), limited(2), limited(3)]);
    expect(started.map((s) => s.at)).toEqual([0, 0, 1000]);
  });

  it('keeps FIFO order and never exceeds the limit in any rolling second', async () => {
    const { limited, started } = setup(3);
    const results = await Promise.all(Array.from({ length: 10 }, (_, i) => limited(i)));
    expect(started.map((s) => s.id)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(results).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    for (const s of started) {
      const inWindow = started.filter((o) => o.at > s.at - 1000 && o.at <= s.at);
      expect(inWindow.length).toBeLessThanOrEqual(3);
    }
  });

  it('does not block later calls when a fetch rejects', async () => {
    const { limited } = setup(1, (id) => (id === 1 ? Promise.reject(new Error('boom')) : Promise.resolve(id)));
    const [a, b] = await Promise.allSettled([limited(1), limited(2)]);
    expect(a.status).toBe('rejected');
    expect(b).toEqual({ status: 'fulfilled', value: 2 });
  });
});
