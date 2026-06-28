import { presentDashboard, fmtDuration, normColor } from '../present';
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

test('hms error -> error', () => {
  expect(presentDashboard({ ...running, hms_errors: [{ code: '0300' }] }).kind).toBe('error');
});

test('heating: running, cold, no progress', () => {
  const vm = presentDashboard({ ...running, progress: 0, temperatures: { nozzle: 40, nozzle_target: 220, bed: 25, bed_target: 60 } });
  expect(vm.stateLabel).toBe('Heating');
  expect(vm.stateColor).not.toBe('');
});

test('fmtDuration + normColor helpers', () => {
  expect(fmtDuration(72)).toBe('1h 12m');
  expect(fmtDuration(45)).toBe('45m');
  expect(fmtDuration(0)).toBe('—');
  expect(normColor('565656FF')).toBe('#565656');
  expect(normColor(undefined)).toBeNull();
});
