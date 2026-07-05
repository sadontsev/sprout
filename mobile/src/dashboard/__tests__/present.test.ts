import { presentDashboard, fmtDuration, normColor, fmtHmsCode } from '../present';
import type { PrinterStatus } from '../../api/types';

const running: PrinterStatus = {
  connected: true,
  state: 'RUNNING',
  progress: 42,
  remaining_time: 72,
  layer_num: 87,
  total_layers: 203,
  subtask_name: 'caldera-E-clean_plate_2',
  chamber_light: true,
  temperatures: { nozzle: 220, nozzle_target: 220, bed: 60, bed_target: 60 },
  ams: [
    {
      id: 0,
      tray: [
        { id: 0, tray_type: 'PLA-S', tray_color: '00000000', remain: 100 },
        { id: 1, tray_type: 'PETG-CF', tray_color: '565656FF', remain: 100 },
        { id: 2, tray_type: 'PLA', tray_color: '000000FF', remain: 100 },
        { id: 3 },
      ],
    },
  ],
  tray_now: 1,
};

// Shape mirrors the real H2C payload (dual nozzle, chamber, benign HMS entry mid-print).
const h2cRunning: PrinterStatus = {
  ...running,
  state: 'RUNNING',
  progress: 1,
  subtask_name: '[H2C] Cute Happy Fox',
  temperatures: {
    bed: 70, bed_target: 70, bed_heating: false,
    nozzle: 203, nozzle_target: 25, nozzle_heating: false,
    nozzle_2: 245, nozzle_2_target: 245, nozzle_2_heating: false,
    chamber: 32, chamber_target: 0, chamber_heating: false,
  },
  hms_errors: [{ code: '0x10007', attr: 83887360, module: 5, severity: 5, full_code: '0500050000010007' }],
  speed_level: 2,
  stg_cur_name: 'Printing',
  active_extruder: 0,
};

test('null -> connecting', () => {
  expect(presentDashboard(null).kind).toBe('connecting');
});

test('disconnected -> offline', () => {
  expect(presentDashboard({ ...running, connected: false }).kind).toBe('offline');
});

test('running maps to live with progress/temps/eta', () => {
  const vm = presentDashboard(running, 0);
  expect(vm.kind).toBe('live');
  expect(vm.stateLabel).toBe('Printing');
  expect(vm.progressInt).toBe(42);
  expect(vm.layer).toBe('87');
  expect(vm.totalLayers).toBe('203');
  expect(vm.etaText).toBe('1h 12m');
  expect(vm.nozzleNow).toBe(220);
  expect(vm.lightOn).toBe(true);
  expect(vm.heroSub).toBe('caldera-E-clean_plate_2');
  expect(vm.nozzles).toHaveLength(1);
  expect(vm.hasChamber).toBe(false);
});

test('ams maps trays with active + empty + normalized color', () => {
  const vm = presentDashboard(running);
  expect(vm.ams).toHaveLength(4);
  expect(vm.ams[1]).toMatchObject({ label: 'PETG-CF', color: '#565656', pct: '100%', active: true, empty: false });
  expect(vm.ams[3]).toMatchObject({ empty: true, label: 'Empty' });
});

test('pause -> live+paused, idle -> idle, finish -> complete', () => {
  expect(presentDashboard({ ...running, state: 'PAUSE' }).isPaused).toBe(true);
  expect(presentDashboard({ ...running, state: 'PAUSE' }).stateLabel).toBe('Paused');
  expect(presentDashboard({ ...running, state: 'IDLE' }).kind).toBe('idle');
  expect(presentDashboard({ ...running, state: 'FINISH' }).kind).toBe('complete');
});

// The H2C emits benign HMS notices while happily printing — presence alone must NOT hijack the
// dashboard into the error screen (real regression: live payload 2026-07-05).
test('benign hms while RUNNING stays live, surfaced as a warning chip', () => {
  const vm = presentDashboard(h2cRunning, 0);
  expect(vm.kind).toBe('live');
  expect(vm.hmsCount).toBe(1);
  expect(vm.hmsCode).toBe('0500-0500-0001-0007');
});

test('print_error or FAILED state -> error', () => {
  expect(presentDashboard({ ...running, print_error: 50348044 }).kind).toBe('error');
  expect(presentDashboard({ ...running, state: 'FAILED' }).kind).toBe('error');
});

test('dual nozzle: both surfaced, active = the driven one (nozzle_2 on the live H2C)', () => {
  const vm = presentDashboard(h2cRunning, 0);
  expect(vm.nozzles).toHaveLength(2);
  expect(vm.nozzles[0]).toMatchObject({ now: 203, active: false });
  expect(vm.nozzles[1]).toMatchObject({ now: 245, target: 245, active: true });
  // Compact views + Live Activity read the active nozzle.
  expect(vm.nozzleNow).toBe(245);
  expect(vm.nozzleTarget).toBe(245);
});

test('dual nozzle: falls back to the hotter one when both/neither have targets', () => {
  const vm = presentDashboard({
    ...h2cRunning,
    temperatures: { ...h2cRunning.temperatures, nozzle: 250, nozzle_target: 0, nozzle_2: 40, nozzle_2_target: 0 },
  });
  expect(vm.nozzles[0].active).toBe(true);
  expect(vm.nozzleNow).toBe(250);
});

test('chamber: surfaced only when the payload reports it', () => {
  const vm = presentDashboard(h2cRunning, 0);
  expect(vm.hasChamber).toBe(true);
  expect(vm.chamberNow).toBe(32);
  expect(vm.chamberTarget).toBe(0);
  expect(vm.chamberHeating).toBe(false);
});

test('speed comes from status.speed_level (default Standard when missing)', () => {
  expect(presentDashboard(h2cRunning).speedIdx).toBe(2);
  expect(presentDashboard({ ...h2cRunning, speed_level: 4 }).speedLabel).toBe('Ludicrous');
  expect(presentDashboard(running).speedLabel).toBe('Standard');
});

test('live sub-stage name becomes the state label', () => {
  const vm = presentDashboard({ ...h2cRunning, stg_cur_name: 'Changing filament' });
  expect(vm.kind).toBe('live');
  expect(vm.stateLabel).toBe('Changing filament');
  // Plain "Printing" stage falls through to the heuristic label.
  expect(presentDashboard(h2cRunning).stateLabel).toBe('Printing');
});

test('explicit heating flags from the payload win over the derived heuristic', () => {
  const vm = presentDashboard({
    ...running,
    temperatures: { nozzle: 40, nozzle_target: 220, nozzle_heating: false, bed: 25, bed_target: 60, bed_heating: false },
  });
  expect(vm.nozzleHeating).toBe(false);
  expect(vm.bedHeating).toBe(false);
});

test('awaiting_plate_clear survives into the VM on complete', () => {
  const vm = presentDashboard({ ...running, state: 'FINISH', awaiting_plate_clear: true });
  expect(vm.kind).toBe('complete');
  expect(vm.awaitingPlateClear).toBe(true);
});

test('heating: running, cold, no progress', () => {
  const vm = presentDashboard({ ...running, progress: 0, temperatures: { nozzle: 40, nozzle_target: 220, bed: 25, bed_target: 60 } });
  expect(vm.stateLabel).toBe('Heating');
  expect(vm.stateColor).not.toBe('');
});

test('fmtDuration + normColor + fmtHmsCode helpers', () => {
  expect(fmtDuration(72)).toBe('1h 12m');
  expect(fmtDuration(45)).toBe('45m');
  expect(fmtDuration(0)).toBe('—');
  expect(normColor('565656FF')).toBe('#565656');
  expect(normColor(undefined)).toBeNull();
  expect(fmtHmsCode('0500050000010007')).toBe('0500-0500-0001-0007');
  expect(fmtHmsCode('0x10007')).toBe('0x10007');
  expect(fmtHmsCode(null)).toBeNull();
});
