import { toContentState, meaningfulChange, GENERIC_END } from '../contentState';
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
