import { blockedActions, isBlocked, lanModeFrom, type ActionId } from '../lanMode';
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
  const blocked: ActionId[] = ['pause', 'resume', 'speed', 'dismissHms', 'amsLoad', 'amsUnload', 'dryStart', 'dryStop', 'startPrint', 'printAgain'];
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
