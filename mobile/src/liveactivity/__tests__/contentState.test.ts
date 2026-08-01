import { toContentState, toDryContentState, dryingUnitIds, meaningfulChange, GENERIC_END } from '../contentState';
import { presentDashboard } from '../../dashboard/present';
import type { PrinterStatus } from '../../api/types';

const base: PrinterStatus = {
  connected: true,
  state: 'RUNNING',
  progress: 66,
  remaining_time: 9,
  layer_num: 178,
  total_layers: 296,
  subtask_name: 'Axis Washers Handle',
  chamber_light: true,
  temperatures: { nozzle: 220, nozzle_target: 220, bed: 60, bed_target: 60 },
};

/** Build the ContentState the Live Activity renders from a raw status (through the real view-model). */
const cs = (status: PrinterStatus, name = 'H2C') => toContentState(presentDashboard(status, 0), status, 0, '', name);

test('single-nozzle A1: one nozzle, no second head, active index 0', () => {
  const s = cs(base, 'A1');
  expect(s.hasNozzle2).toBe(false);
  expect(s.activeNozzle).toBe(0);
  expect(s.nozzle).toBe(220);
  expect(s.nozzleTarget).toBe(220);
  expect(s.nozzle2).toBe(0);
  expect(s.printerName).toBe('A1');
});

// The exact live H2C payload mid-print: right printing at 220/220, left idle at 41/0.
// Regression: toContentState used to hardcode the LEFT nozzle, so the card showed 41°/idle.
test('dual-nozzle H2C: right active -> shows both, active index 1, both temps carried', () => {
  const s = cs({
    ...base,
    temperatures: { bed: 55, bed_target: 55, nozzle: 41, nozzle_target: 0, nozzle_2: 220, nozzle_2_target: 220 },
  });
  expect(s.hasNozzle2).toBe(true);
  expect(s.activeNozzle).toBe(1); // right
  expect(s.nozzle).toBe(41); // left carried (dimmed on the card)
  expect(s.nozzle2).toBe(220); // right carried (highlighted)
  expect(s.nozzle2Target).toBe(220);
});

// Mid tool-change: left just deactivated (hot, target 0), right just activated (cooler, target 220).
// The active head must follow the driven target, not the temperature.
test('dual-nozzle H2C: driven-but-cooler right head is still the active one', () => {
  const s = cs({
    ...base,
    temperatures: { bed: 55, bed_target: 55, nozzle: 150, nozzle_target: 0, nozzle_2: 60, nozzle_2_target: 220 },
  });
  expect(s.activeNozzle).toBe(1);
  expect(s.nozzle2).toBe(60);
});

// Live H2C left-nozzle print: active_extruder=1 (WRONG) while nozzle idx0 is driven at 245/245.
// The card must show the LEFT head active, not follow the bogus active_extruder.
test('dual-nozzle H2C: contradictory active_extruder ignored -> left (driven) is active', () => {
  const s = cs({
    ...base,
    active_extruder: 1,
    temperatures: { bed: 70, bed_target: 70, nozzle: 245, nozzle_target: 245, nozzle_2: 46, nozzle_2_target: 0 },
  });
  expect(s.activeNozzle).toBe(0);
  expect(s.nozzle).toBe(245);
  expect(s.nozzle2).toBe(46);
});

test('meaningfulChange fires on a change to the second (right) nozzle', () => {
  const a = cs({ ...base, temperatures: { bed: 55, bed_target: 55, nozzle: 41, nozzle_target: 0, nozzle_2: 200, nozzle_2_target: 220 } });
  const b = cs({ ...base, temperatures: { bed: 55, bed_target: 55, nozzle: 41, nozzle_target: 0, nozzle_2: 220, nozzle_2_target: 220 } });
  expect(meaningfulChange(a, a)).toBe(false); // no change
  expect(meaningfulChange(a, b)).toBe(true); // right nozzle warmed 200 -> 220
  expect(meaningfulChange(null, b)).toBe(true);
});

test('meaningfulChange fires when the active head switches (tool change)', () => {
  // left driven -> then a tool change: left target drops to 0, right target set to 220.
  const left = cs({ ...base, temperatures: { bed: 55, bed_target: 55, nozzle: 220, nozzle_target: 220, nozzle_2: 40, nozzle_2_target: 0 } });
  const right = cs({ ...base, temperatures: { bed: 55, bed_target: 55, nozzle: 210, nozzle_target: 0, nozzle_2: 210, nozzle_2_target: 220 } });
  expect(left.activeNozzle).toBe(0);
  expect(right.activeNozzle).toBe(1); // driven target follows to the right head
  expect(meaningfulChange(left, right)).toBe(true);
});

test('GENERIC_END is a complete, terminal ContentState', () => {
  expect(GENERIC_END).toMatchObject({ finished: true, hasNozzle2: false, activeNozzle: 0, nozzle2: 0 });
});

describe('toDryContentState (AMS drying card)', () => {
  const { toDryContentState } = require('../contentState');
  const base = (ams: object | undefined) => ({ connected: true, state: 'RUNNING', ams: ams ? [ams] : undefined }) as never;

  it('null when no AMS or no active cycle (dry_time 0)', () => {
    expect(toDryContentState(base(undefined), 0)).toBeNull();
    expect(toDryContentState(base({ id: 0, dry_time: 0 }), 0)).toBeNull();
  });

  it('builds a drying card from an active cycle (verified live shape: H2C, Studio-started)', () => {
    const cs = toDryContentState(base({ id: 0, dry_time: 59, dry_target_temp: 50, dry_filament: 'PLA', temp: 38.0, humidity: 31 }), 1_000_000, 'file://icon', 'H2C');
    expect(cs).toMatchObject({
      dry: true, stateLabel: 'Drying', name: 'PLA @ 50°', printerName: 'H2C',
      amsTemp: 38, amsTarget: 50, humidity: 31, finished: false,
    });
    expect(cs!.etaEpochMs).toBe(1_000_000 + 59 * 60000);
  });

  it('tolerates WS string numbers and a missing target (external starts may omit it)', () => {
    const cs = toDryContentState(base({ id: 0, dry_time: '30', dry_target_temp: null, dry_filament: null, temp: '41.2', humidity: '28' }), 0);
    expect(cs).toMatchObject({ name: 'Filament', amsTemp: 41, amsTarget: 0, humidity: 28 });
    expect(cs!.etaEpochMs).toBe(30 * 60000);
  });

  it('dry-field deltas count as meaningful changes; countdown drift alone within a minute does not', () => {
    const { meaningfulChange } = require('../contentState');
    const a = toDryContentState(base({ id: 0, dry_time: 59, dry_target_temp: 50, dry_filament: 'PLA', temp: 38, humidity: 31 }), 0)!;
    const hotter = toDryContentState(base({ id: 0, dry_time: 59, dry_target_temp: 50, dry_filament: 'PLA', temp: 41, humidity: 31 }), 0)!;
    const sameSoon = toDryContentState(base({ id: 0, dry_time: 59, dry_target_temp: 50, dry_filament: 'PLA', temp: 38, humidity: 31 }), 30_000)!;
    expect(meaningfulChange(a, hotter)).toBe(true);
    expect(meaningfulChange(a, sameSoon)).toBe(false);
  });
});

describe('laTint — lock-screen colours must not follow the app theme', () => {
  const { laTint, LA_COLORS, toContentState } = require('../contentState');
  const { presentDashboard } = require('@/dashboard/present');
  const { setTheme } = require('@/theme');
  const status = (over: object = {}) =>
    ({ connected: true, state: 'RUNNING', progress: 42, temperatures: { nozzle: 220, nozzle_target: 220, bed: 60, bed_target: 60 }, ...over }) as never;

  afterEach(() => setTheme('dark'));

  it('is IDENTICAL in light and dark mode (la-push has no idea what theme the phone is on)', () => {
    setTheme('dark');
    const dark = toContentState(presentDashboard(status(), 0), status(), 0).tint;
    setTheme('light');
    const light = toContentState(presentDashboard(status(), 0), status(), 0).tint;
    expect(light).toBe(dark);
    expect(light).toBe(LA_COLORS.running); // and it matches la-push's COLORS['running']
  });

  it('maps each state to the fixed palette', () => {
    expect(laTint(presentDashboard(status({ print_error: 1 }), 0))).toBe(LA_COLORS.error);
    expect(laTint(presentDashboard(status({ state: 'PAUSE' }), 0))).toBe(LA_COLORS.paused);
    expect(laTint(presentDashboard(status({ state: 'IDLE' }), 0))).toBe(LA_COLORS.idle);
    expect(laTint(presentDashboard(status({ state: 'FINISH' }), 0))).toBe(LA_COLORS.running);
  });

  it('heating (a named sub-stage) is amber, steady printing is green', () => {
    expect(laTint(presentDashboard(status({ stg_cur_name: 'Auto bed leveling' }), 0))).toBe(LA_COLORS.heating);
    expect(laTint(presentDashboard(status(), 0))).toBe(LA_COLORS.running);
  });
});

describe('concurrent drying cycles — one card per unit', () => {
  const threeUnits = (dryTimes: Array<number | string>): PrinterStatus =>
    ({
      connected: true,
      state: 'IDLE',
      ams: [
        { id: 0, module_type: 'n3f', dry_time: dryTimes[0], dry_target_temp: 55, dry_filament: 'PETG', temp: 40, humidity: 20, tray: [] },
        { id: 1, module_type: 'n3f', dry_time: dryTimes[1], dry_target_temp: 55, dry_filament: 'PLA', temp: 38, humidity: 22, tray: [] },
        { id: 128, module_type: 'n3s', is_ams_ht: true, dry_time: dryTimes[2], dry_target_temp: 85, dry_filament: 'PETG-CF', temp: 60, humidity: 12, tray: [] },
      ],
    }) as unknown as PrinterStatus;

  it('reports every actively drying unit, not just the first', () => {
    expect(dryingUnitIds(threeUnits([90, 0, 120]))).toEqual([0, 128]);
    expect(dryingUnitIds(threeUnits([90, 45, 120]))).toEqual([0, 1, 128]);
  });

  it('treats only dry_time > 0 as active, and copes with WebSocket string values', () => {
    expect(dryingUnitIds(threeUnits([0, 0, 0]))).toEqual([]);
    expect(dryingUnitIds(threeUnits(['90', '0', '']))).toEqual([0]);
    expect(dryingUnitIds(null)).toEqual([]);
  });

  it('builds a DISTINCT card per unit, each naming its own unit and filament', () => {
    const st = threeUnits([90, 0, 120]);
    const a = toDryContentState(st, 0, '', 'H2C', 0)!;
    const b = toDryContentState(st, 0, '', 'H2C', 128)!;
    expect(a.name).toContain('AMS 1');
    expect(a.name).toContain('PETG');
    expect(b.name).toContain('AMS HT');
    expect(b.name).toContain('PETG-CF');
    expect(a.name).not.toBe(b.name); // the two lock-screen cards must be tellable apart
    expect(a.etaEpochMs).not.toBe(b.etaEpochMs);
    expect(b.amsTarget).toBe(85); // the HT's higher ceiling, not unit 0's 55
  });

  it('returns null for a unit that is not drying, so no card is started for it', () => {
    expect(toDryContentState(threeUnits([90, 0, 120]), 0, '', 'H2C', 1)).toBeNull();
  });

  it('returns null for a unit id that does not exist', () => {
    expect(toDryContentState(threeUnits([90, 0, 120]), 0, '', 'H2C', 7)).toBeNull();
  });

  it('without an amsId still falls back to the first drying unit', () => {
    // Back-compat for callers that only ask "is anything drying".
    expect(toDryContentState(threeUnits([0, 45, 0]), 0, '', 'H2C')!.name).toContain('AMS 2');
  });
});
