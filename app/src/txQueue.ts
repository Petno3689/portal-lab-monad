/** What a job reports about its included transaction. */
export interface TxResult {
  hash: `0x${string}`;
  blockNumber: bigint;
}

export interface TxQueueDeps {
  getBlockNumber: () => Promise<bigint>;
  sleep: (ms: number) => Promise<void>;
  minBlockGap?: bigint;
  pollMs?: number;
}

export interface TxQueue {
  enqueue: <T extends TxResult>(job: () => Promise<T>) => Promise<T>;
}

/**
 * Runs transactions strictly one at a time. Below Monad's reserve balance a transaction
 * that spends more than its gas reverts if the sender sent another one in the previous
 * k blocks, so each job waits `minBlockGap` blocks after the previous inclusion.
 */
export function createTxQueue({ getBlockNumber, sleep, minBlockGap = 3n, pollMs = 200 }: TxQueueDeps): TxQueue {
  let tail: Promise<unknown> = Promise.resolve();
  let lastBlock: bigint | null = null;

  const run = async <T extends TxResult>(job: () => Promise<T>): Promise<T> => {
    if (lastBlock !== null) {
      const ready = lastBlock + minBlockGap;
      while ((await getBlockNumber()) < ready) await sleep(pollMs);
    }
    try {
      const result = await job();
      lastBlock = result.blockNumber;
      return result;
    } catch (error) {
      // A transaction that was included and reverted still counts for the gap.
      const included = (error as { blockNumber?: unknown } | null)?.blockNumber;
      if (typeof included === 'bigint') lastBlock = included;
      throw error;
    }
  };

  return {
    enqueue(job) {
      const result = tail.then(() => run(job));
      tail = result.catch(() => undefined);
      return result;
    },
  };
}
