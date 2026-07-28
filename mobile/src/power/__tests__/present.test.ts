import { automationSummary, otherPlugs, plugAutomations, plugLabel } from '../present';
import type { SmartPlug } from '@/api/types';

const plug = (over: Partial<SmartPlug> = {}): SmartPlug => ({ id: 1, name: 'H2C Printer Plug', ...over });
const keys = (p: SmartPlug) => plugAutomations(p).map((a) => a.key);

describe('plugAutomations', () => {
  it('reports nothing for a plug with every rule disarmed', () => {
    expect(plugAutomations(plug({ auto_on: false, auto_off: false, auto_off_after_drying: false, schedule_enabled: false }))).toEqual([]);
    expect(automationSummary(plug())).toBe('Nothing switches this plug automatically.');
  });

  it('returns [] for a missing plug rather than throwing', () => {
    expect(plugAutomations(null)).toEqual([]);
    expect(plugAutomations(undefined)).toEqual([]);
    expect(automationSummary(null)).toBe('Nothing switches this plug automatically.');
  });

  it('flags only power-CUTTING rules as cuts — auto-on is harmless', () => {
    expect(plugAutomations(plug({ auto_on: true }))[0]).toMatchObject({ key: 'auto_on', cuts: false });
    expect(plugAutomations(plug({ auto_off: true }))[0].cuts).toBe(true);
    expect(plugAutomations(plug({ auto_off_after_drying: true }))[0].cuts).toBe(true);
  });

  it('describes auto-off by its mode — minutes vs hotend temperature', () => {
    expect(plugAutomations(plug({ auto_off: true, off_delay_minutes: 12 }))[0].detail).toContain('12 min after a print');
    const temp = plugAutomations(plug({ auto_off: true, off_delay_mode: 'temperature', off_temp_threshold: 55 }))[0];
    expect(temp.detail).toContain('below 55°C');
    expect(temp.detail).not.toContain('min after');
  });

  it('falls back to the server defaults when thresholds are absent', () => {
    expect(plugAutomations(plug({ auto_off: true }))[0].detail).toContain('5 min');
    expect(plugAutomations(plug({ auto_off: true, off_delay_mode: 'temperature' }))[0].detail).toContain('70°C');
    expect(plugAutomations(plug({ auto_off_after_drying: true }))[0].detail).toContain('10 min');
  });

  it('calls out a persistent auto-off, which survives a restart', () => {
    expect(plugAutomations(plug({ auto_off: true, auto_off_persistent: true }))[0].detail).toContain('Survives a Bambuddy restart');
    expect(plugAutomations(plug({ auto_off: true }))[0].detail).not.toContain('Survives');
  });

  it('describes the drying rule distinctly from the print rule', () => {
    const both = plugAutomations(plug({ auto_off: true, auto_off_after_drying: true, off_delay_after_drying_minutes: 20 }));
    expect(both.map((a) => a.key)).toEqual(['auto_off', 'after_drying']);
    expect(both[1].detail).toContain('20 min after AMS drying');
  });

  describe('schedule', () => {
    it('renders both edges and counts the OFF edge as cutting', () => {
      const s = plugAutomations(plug({ schedule_enabled: true, schedule_on_time: '07:00', schedule_off_time: '22:30' }))[0];
      expect(s.detail).toBe('Switches on at 07:00, off at 22:30 every day.');
      expect(s.cuts).toBe(true);
    });

    it('an ON-only schedule cannot cut power', () => {
      const s = plugAutomations(plug({ schedule_enabled: true, schedule_on_time: '07:00' }))[0];
      expect(s.detail).toBe('Switches on at 07:00 every day.');
      expect(s.cuts).toBe(false);
    });

    it('is NOT reported when enabled with no times — that rule does nothing', () => {
      expect(keys(plug({ schedule_enabled: true }))).toEqual([]);
      expect(keys(plug({ schedule_enabled: true, schedule_on_time: null, schedule_off_time: null }))).toEqual([]);
    });

    it('ignores malformed times rather than printing them', () => {
      expect(keys(plug({ schedule_enabled: true, schedule_on_time: '25:00' }))).toEqual([]);
      expect(keys(plug({ schedule_enabled: true, schedule_on_time: 'soon' }))).toEqual([]);
      expect(keys(plug({ schedule_enabled: true, schedule_on_time: '7:00' }))).toEqual([]); // needs zero-padding
      expect(keys(plug({ schedule_enabled: true, schedule_off_time: '00:00' }))).toEqual(['schedule']); // midnight is valid
    });

    it('is not reported when the schedule is disabled, times or not', () => {
      expect(keys(plug({ schedule_enabled: false, schedule_on_time: '07:00', schedule_off_time: '22:00' }))).toEqual([]);
    });
  });

  it('lists every armed rule in a stable, readable order', () => {
    const all = plug({ auto_on: true, auto_off: true, auto_off_after_drying: true, schedule_enabled: true, schedule_off_time: '23:00' });
    expect(keys(all)).toEqual(['auto_on', 'auto_off', 'after_drying', 'schedule']);
    expect(automationSummary(all)).toBe('Auto power-on · Auto power-off · Off after drying · Schedule');
  });
});

describe('otherPlugs', () => {
  const all: SmartPlug[] = [
    { id: 5, name: 'Meaco AC Plug' },
    { id: 2, name: 'H2C Printer Plug', printer_id: 2 },
    { id: 4, name: 'AMS HT Plug' },
    { id: 3, name: 'AMS 2 Pro Plug' },
  ];

  it('excludes the printer plug and sorts by id', () => {
    expect(otherPlugs(all, 2).map((p) => p.id)).toEqual([3, 4, 5]);
  });

  it('keeps every plug when the printer has none linked', () => {
    expect(otherPlugs(all, null).map((p) => p.id)).toEqual([2, 3, 4, 5]);
    expect(otherPlugs(all, undefined)).toHaveLength(4);
  });

  it('drops disabled plugs — Bambuddy will not act on them', () => {
    expect(otherPlugs([...all, { id: 9, name: 'Old', enabled: false }], 2).map((p) => p.id)).toEqual([3, 4, 5]);
    expect(otherPlugs([{ id: 9, name: 'Kept', enabled: true }], null)).toHaveLength(1);
  });

  it('survives an empty or missing list', () => {
    expect(otherPlugs([], 2)).toEqual([]);
    expect(otherPlugs(null, 2)).toEqual([]);
    expect(otherPlugs(undefined, 2)).toEqual([]);
  });
});

describe('plugLabel', () => {
  it('prefers the name, falls back to the id, never renders blank', () => {
    expect(plugLabel({ id: 3, name: 'AMS HT Plug' })).toBe('AMS HT Plug');
    expect(plugLabel({ id: 3, name: '   ' })).toBe('Plug 3');
    expect(plugLabel({ id: 3 })).toBe('Plug 3');
    expect(plugLabel(null)).toBe('Smart plug');
  });
});
