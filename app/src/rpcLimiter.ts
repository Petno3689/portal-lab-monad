type FetchLike = (input: any, init?: any) => Promise<any>;

interface Options<F extends FetchLike> {
  fetch: F;
  /** At most this many calls start in any rolling 1000 ms window. */
  maxPerSecond: number;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
}

const WINDOW_MS = 1000;

/**
 * Wraps `fetch` so that at most `maxPerSecond` calls start in any rolling second.
 * Excess calls wait in FIFO order; a rejected fetch frees nothing and blocks nobody.
 */
export function createRateLimitedFetch<F extends FetchLike>({ fetch, maxPerSecond, now, sleep }: Options<F>): F {
  const starts: number[] = [];
  const queue: Array<() => void> = [];
  let pumping = false;

  async function pump() {
    if (pumping) return;
    pumping = true;
    try {
      while (queue.length > 0) {
        const t = now();
        while (starts.length > 0 && starts[0] <= t - WINDOW_MS) starts.shift();
        if (starts.length < maxPerSecond) {
          starts.push(t);
          queue.shift()!();
        } else {
          await sleep(starts[0] + WINDOW_MS - t);
        }
      }
    } finally {
      pumping = false;
    }
  }

  return ((input, init) =>
    new Promise((resolve, reject) => {
      queue.push(() => {
        try {
          fetch(input, init).then(resolve, reject);
        } catch (error) {
          reject(error);
        }
      });
      void pump();
    })) as F;
}
