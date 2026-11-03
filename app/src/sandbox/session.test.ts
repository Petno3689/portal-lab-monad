import { describe, expect, it } from 'vitest';
import { Action, PortalStatus } from '@shared/types';
import { VirtualClock } from './clock';
import { LIVE_V2 } from './presets';
import { startGame, resolve, act, sync } from './engine';
import { cloneParams } from './params';
import { Session, summarize } from './session';

function fake() {
  let t = 5_000_000;
  const clock = new VirtualClock(1_800_000_000n, () => t);
  let n = 0;
  const randomWord = () => BigInt.asUintN(256, BigInt(++n) * 0x9e3779b97f4a7c15f39cc0605cedc834n);
  return { clock, advance: (ms: number) => void (t += ms), randomWord };
}

describe('Session', () => {
  it('delivers the first word after the word delay and births the starting hand', () => {
    const f = fake();
    const s = new Session(cloneParams(LIVE_V2), 'Live v2', true, f);
    expect(s.status()).toBe('waiting for word');
    f.advance(2400);
    s.tick();
    expect(s.state.player.pending.active).toBe(true);
    f.advance(200);
    s.tick();
    expect(s.state.player.pending.active).toBe(false);
    expect(s.state.player.portals.filter((p) => p.status !== PortalStatus.Empty)).toHaveLength(3);
    expect(s.calls.map((c) => c.kind)).toEqual(['start', 'resolve']);
    expect(s.status()).toBe('running');
  });

  it('runs an action at the time it lands, not the time of the click, and allows one at a time', () => {
    const f = fake();
    const s = new Session(cloneParams(LIVE_V2), 'Live v2', true, f);
    f.advance(2500);
    s.tick();
    expect(s.canAct()).toBe(true);
    const clickTs = f.clock.now();
    expect(s.requestAction(0n, Action.ToggleQuestioned)).toBe(true);
    expect(s.status()).toBe('action in flight');
    expect(s.requestAction(1n, Action.ToggleQuestioned)).toBe(false);
    f.advance(1000);
    s.tick();
    const call = s.calls[s.calls.length - 1];
    expect(call.kind).toBe('act');
    expect(call.nowTs).toBe(clickTs + 1n);
    expect(s.canAct()).toBe(true);
  });

  it('does nothing while paused and does not age the world', () => {
    const f = fake();
    const s = new Session(cloneParams(LIVE_V2), 'Live v2', true, f);
    s.setPaused(true);
    f.advance(600_000);
    s.tick();
    expect(s.calls).toHaveLength(1);
    expect(s.status()).toBe('paused');
    expect(s.canAct()).toBe(false);
    s.setPaused(false);
    f.advance(2500);
    s.tick();
    expect(s.calls.map((c) => c.kind)).toEqual(['start', 'resolve']);
  });

  it('buys the next word by itself when the world is capped, and ends the game on death', () => {
    const f = fake();
    const p = cloneParams(LIVE_V2);
    p.config.hpStart = 1n;
    p.config.hpMax = 1n;
    const s = new Session(p, 'Custom', false, f);
    for (let i = 0; i < 400 && !s.over; i++) {
      f.advance(5000);
      s.tick();
    }
    expect(s.over).toBe(true);
    expect(s.state.log.at(-1)?.kind).toBe('gameOver');
    const sum = summarize(s);
    expect(sum.hoursSurvived).toBe(s.state.player.game.diedAtHour);
    expect(sum.realSeconds).toBe(sum.hoursSurvived * 15n);
    expect(sum.portalsCollapsed).toBeGreaterThan(0);
  });

  it('records calls that replay to the same log on the bare engine', () => {
    const f = fake();
    const s = new Session(cloneParams(LIVE_V2), 'Live v2', false, f);
    for (let i = 0; i < 6; i++) {
      f.advance(4000);
      s.tick();
      s.requestAction(BigInt(i % 3), Action.Stabilize);
    }
    for (let i = 0; i < 100 && !s.over; i++) {
      f.advance(5000);
      s.tick();
    }
    let st = startGame(LIVE_V2.config, LIVE_V2.types, s.calls[0].nowTs, { buyFirstWord: true });
    for (const c of s.calls.slice(1)) {
      if (c.kind === 'act') st = act(st, c.slot, c.action, c.nowTs).state;
      else if (c.kind === 'resolve') st = resolve(st, c.word, c.nowTs);
      else if (c.kind === 'sync') st = sync(st, c.word, c.nowTs);
    }
    expect(st.log).toEqual(s.state.log);
  });
});
