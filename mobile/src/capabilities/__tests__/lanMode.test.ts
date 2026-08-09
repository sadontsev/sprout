import { readdirSync, readFileSync } from 'fs';
import { join } from 'path';

import { blockedActions, isBlocked, lanModeFrom, lockedStyle, LOCKED_OPACITY, type ActionId } from '../lanMode';
import type { PrinterStatus } from '@/api/types';

const st = (developer_mode?: boolean | null): PrinterStatus => ({ developer_mode } as unknown as PrinterStatus);

describe('lanModeFrom — tri-state, because absence is not "off"', () => {
  it('reads an explicit boolean', () => {
    expect(lanModeFrom(st(true))).toBe('on');
    expect(lanModeFrom(st(false))).toBe('off');
  });

  it('treats absent/null/no-status as UNKNOWN, never as off', () => {
    // A gate that reads absence as "off" greys out the whole UI on every cold start, and — worse —
    // the field is missing from the WebSocket payload entirely, which is the app's primary feed.
    for (const s of [st(undefined), st(null), null, undefined]) expect(lanModeFrom(s)).toBe('unknown');
  });
});

describe('isBlocked', () => {
  const blocked: ActionId[] = ['pause', 'resume', 'speed', 'amsLoad', 'amsUnload', 'dryStart', 'dryStop', 'startPrint', 'printAgain'];
  const allowed: ActionId[] = ['stop', 'light', 'camera', 'plug', 'plateCleared', 'maintenance', 'queueRemove'];

  it('blocks every print.* command when Developer Mode is off', () => {
    for (const a of blocked) expect(isBlocked(a, 'off')).toBe(true);
  });

  it('NEVER blocks the emergency stop', () => {
    // A dead grey Stop on a print that is spaghettifying is actively dangerous. A Stop that might
    // fail is strictly better than one that cannot be pressed.
    for (const m of ['on', 'off', 'unknown'] as const) expect(isBlocked('stop', m)).toBe(false);
  });

  it('never blocks the things that do not go through the verified MQTT topic', () => {
    for (const a of allowed) expect(isBlocked(a, 'off')).toBe(false);
  });

  it('blocks NOTHING while the mode is on or not yet known', () => {
    for (const a of [...blocked, ...allowed]) {
      expect(isBlocked(a, 'on')).toBe(false);
      expect(isBlocked(a, 'unknown')).toBe(false);
    }
    expect(blockedActions('unknown')).toEqual([]);
    expect(blockedActions('on')).toEqual([]);
  });

  it('the blocked set is exactly the print-command family', () => {
    expect(blockedActions('off').sort()).toEqual([...blocked].sort());
  });

  it('the light is allowed — it is system/ledctrl, not a print command', () => {
    expect(isBlocked('light', 'off')).toBe(false);
  });
});

describe('lockedStyle', () => {
  it('dims a locked control and leaves an available one untouched', () => {
    expect(lockedStyle(true)).toEqual({ opacity: LOCKED_OPACITY });
    expect(lockedStyle(false)).toBeNull();
  });

  it('returns null (not {opacity:1}) so it can be spread without clobbering a style', () => {
    // `{...lockedStyle(false)}` must be a no-op; an {opacity:1} would override a caller's own opacity
    // (e.g. the dryer buttons' `opacity: busy ? 0.5 : 1`).
    expect({ opacity: 0.5, ...lockedStyle(false) }).toEqual({ opacity: 0.5 });
    expect({ opacity: 0.5, ...lockedStyle(true) }).toEqual({ opacity: LOCKED_OPACITY });
  });
});

describe('every blocked action is acknowledged by the UI', () => {
  // The bug this guards: an action gated in the handler but whose button still looks tappable.
  // Any ActionId we refuse must be named by at least one component, so adding one to BLOCKED
  // without giving it a visual treatment fails here rather than shipping a dead-looking button.
  const roots = [join(__dirname, '../../components'), join(__dirname, '../../app')];
  const sources = roots
    .flatMap((d) => readdirSync(d).map((f) => join(d, f)))
    .filter((f) => f.endsWith('.tsx'))
    .map((f) => readFileSync(f, 'utf8'))
    .join('\n');

  it.each(blockedActions('off'))('%s is referenced by a component', (action) => {
    expect(sources).toContain(`'${action}'`);
  });
});
