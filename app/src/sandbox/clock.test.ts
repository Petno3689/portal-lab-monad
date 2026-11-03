import { describe, expect, it } from 'vitest';
import { VirtualClock } from './clock';

function fake(t0 = 1_000_000) {
  let t = t0;
  return { real: () => t, advance: (ms: number) => void (t += ms), set: (v: number) => void (t = v) };
}

describe('VirtualClock', () => {
  it('starts at the given timestamp and counts whole seconds', () => {
    const f = fake();
    const c = new VirtualClock(1_700_000_000n, f.real);
    expect(c.now()).toBe(1_700_000_000n);
    f.advance(999);
    expect(c.now()).toBe(1_700_000_000n);
    f.advance(1);
    expect(c.now()).toBe(1_700_000_001n);
    f.advance(2500);
    expect(c.now()).toBe(1_700_000_003n);
    expect(c.elapsedMs()).toBe(3500);
  });

  it('defaults the start to the real time in seconds', () => {
    const f = fake(5_000_999);
    expect(new VirtualClock(undefined, f.real).now()).toBe(5000n);
  });

  it('stands still while paused and resumes from where it stopped', () => {
    const f = fake();
    const c = new VirtualClock(100n, f.real);
    f.advance(2000);
    c.pause();
    expect(c.paused).toBe(true);
    f.advance(60_000);
    expect(c.now()).toBe(102n);
    expect(c.elapsedMs()).toBe(2000);
    c.resume();
    expect(c.paused).toBe(false);
    f.advance(1000);
    expect(c.now()).toBe(103n);
  });

  it('pause and resume are idempotent', () => {
    const f = fake();
    const c = new VirtualClock(100n, f.real);
    c.resume();
    f.advance(1000);
    c.pause();
    c.pause();
    f.advance(5000);
    c.resume();
    c.resume();
    f.advance(1000);
    expect(c.elapsedMs()).toBe(2000);
  });

  it('never goes backwards when the real clock does', () => {
    const f = fake(1_000_000);
    const c = new VirtualClock(100n, f.real);
    f.advance(5000);
    expect(c.now()).toBe(105n);
    f.set(900_000);
    expect(c.now()).toBe(105n);
    f.advance(1000); // 901_000: still behind the high-water mark
    expect(c.now()).toBe(105n);
    f.set(1_010_000);
    expect(c.now()).toBe(110n);
    // a backwards jump while paused cannot make it go back either
    c.pause();
    f.set(0);
    expect(c.now()).toBe(110n);
  });
});
