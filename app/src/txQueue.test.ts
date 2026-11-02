import { describe, expect, it } from 'vitest';
import { createTxQueue, type TxResult } from './txQueue';

const included = (blockNumber: bigint): TxResult => ({ hash: '0xabc', blockNumber });

/** Each call returns the next scripted block number; the last one repeats. */
function scriptedBlocks(blocks: bigint[]) {
  let i = 0;
  const calls = { count: 0 };
  const getBlockNumber = async () => {
    calls.count += 1;
    return blocks[Math.min(i++, blocks.length - 1)];
  };
  return { getBlockNumber, calls };
}

function fakeSleep() {
  const naps: number[] = [];
  return { naps, sleep: async (ms: number) => void naps.push(ms) };
}

describe('createTxQueue', () => {
  it('runs jobs in enqueue order with no overlap', async () => {
    const { getBlockNumber } = scriptedBlocks([1000n]);
    const queue = createTxQueue({ getBlockNumber, sleep: fakeSleep().sleep });
    const log: string[] = [];
    let running = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));

    const job = (name: string, wait?: Promise<void>) => async () => {
      running += 1;
      expect(running).toBe(1);
      log.push(`start ${name}`);
      await wait;
      log.push(`end ${name}`);
      running -= 1;
      return included(1n);
    };

    const all = [queue.enqueue(job('a', gate)), queue.enqueue(job('b')), queue.enqueue(job('c'))];
    await Promise.resolve();
    release();
    await Promise.all(all);
    expect(log).toEqual(['start a', 'end a', 'start b', 'end b', 'start c', 'end c']);
  });

  it('does not wait before the first job', async () => {
    const { getBlockNumber, calls } = scriptedBlocks([0n]);
    const queue = createTxQueue({ getBlockNumber, sleep: fakeSleep().sleep });
    await queue.enqueue(async () => included(100n));
    expect(calls.count).toBe(0);
  });

  it('holds the next job until the chain reaches p + 3', async () => {
    const { getBlockNumber, calls } = scriptedBlocks([100n, 101n, 102n, 103n]);
    const { naps, sleep } = fakeSleep();
    const queue = createTxQueue({ getBlockNumber, sleep });
    await queue.enqueue(async () => included(100n));

    let callsAtStart = 0;
    await queue.enqueue(async () => {
      callsAtStart = calls.count;
      return included(104n);
    });
    expect(callsAtStart).toBe(4);
    expect(naps).toEqual([200, 200, 200]);
  });

  it('honours a custom gap and poll interval', async () => {
    const { getBlockNumber, calls } = scriptedBlocks([10n, 11n]);
    const { naps, sleep } = fakeSleep();
    const queue = createTxQueue({ getBlockNumber, sleep, minBlockGap: 1n, pollMs: 50 });
    await queue.enqueue(async () => included(10n));
    await queue.enqueue(async () => included(11n));
    expect(calls.count).toBe(2);
    expect(naps).toEqual([50]);
  });

  it('a rejected job rejects only itself, and the next job runs', async () => {
    const { getBlockNumber } = scriptedBlocks([1000n]);
    const queue = createTxQueue({ getBlockNumber, sleep: fakeSleep().sleep });
    const failed = queue.enqueue(async () => {
      throw new Error('boom');
    });
    const next = queue.enqueue(async () => included(5n));
    await expect(failed).rejects.toThrow('boom');
    await expect(next).resolves.toEqual(included(5n));
  });

  it('a job that failed before inclusion keeps the gap of the last included one', async () => {
    const { getBlockNumber, calls } = scriptedBlocks([100n, 103n]);
    const { sleep } = fakeSleep();
    const queue = createTxQueue({ getBlockNumber, sleep });
    await queue.enqueue(async () => included(100n));
    await expect(
      queue.enqueue(async () => {
        throw new Error('simulation refused');
      }),
    ).rejects.toThrow();
    await queue.enqueue(async () => included(104n));
    expect(calls.count).toBe(3);
  });

  it('a job that was included and reverted still sets the gap', async () => {
    const { getBlockNumber, calls } = scriptedBlocks([200n, 201n, 202n, 203n]);
    const { naps, sleep } = fakeSleep();
    const queue = createTxQueue({ getBlockNumber, sleep });
    await expect(
      queue.enqueue(async () => {
        throw Object.assign(new Error('reverted'), { blockNumber: 200n });
      }),
    ).rejects.toThrow('reverted');
    await queue.enqueue(async () => included(204n));
    expect(calls.count).toBe(4);
    expect(naps).toHaveLength(3);
  });

  it('a failing block read rejects that job and the queue continues', async () => {
    let fail = true;
    const getBlockNumber = async () => {
      if (fail) {
        fail = false;
        throw new Error('rpc down');
      }
      return 1000n;
    };
    const queue = createTxQueue({ getBlockNumber, sleep: fakeSleep().sleep });
    await queue.enqueue(async () => included(1n));
    await expect(queue.enqueue(async () => included(2n))).rejects.toThrow('rpc down');
    await expect(queue.enqueue(async () => included(3n))).resolves.toEqual(included(3n));
  });
});
