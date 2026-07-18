import { presentDashboard, presentNozzles, fmtDuration, normColor, fmtHmsCode, asNum } from '../present';
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
  // active_extruder omitted -> tests exercise the temperature fallback; the dedicated test below
  // covers the active_extruder path explicitly.
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

// Regression (the real Live-Activity bug, 2026-07-07): the RIGHT nozzle prints (target 220) while the
// LEFT sits idle (target 0) but has NOT cooled yet — so "hotter" would wrongly pick the idle left.
// The only reliable signal is "which nozzle has a target set", so the driven one must win regardless.
test('dual nozzle: active follows the driven target, even when the idle one is still hotter', () => {
  const vm = presentDashboard({
    ...h2cRunning,
    // left just deactivated (cooling from 150, target 0); right just activated (heating 60 -> 220).
    temperatures: { ...h2cRunning.temperatures, nozzle: 150, nozzle_target: 0, nozzle_2: 60, nozzle_2_target: 220 },
  });
  expect(vm.nozzles[0].active).toBe(false); // left, idle
  expect(vm.nozzles[1].active).toBe(true); // right, driven
  expect(vm.nozzleNow).toBe(60);
  expect(vm.nozzleTarget).toBe(220);
});

// The exact live payload pulled off the H2C mid-print: right printing at 220/220, left idle 41/0.
test('dual nozzle: matches the live H2C payload — right active, left idle', () => {
  const vm = presentDashboard({
    ...h2cRunning,
    temperatures: { bed: 55, bed_target: 55, nozzle: 41, nozzle_target: 0, nozzle_2: 220, nozzle_2_target: 220 },
  });
  expect(vm.nozzles[1].active).toBe(true);
  expect(vm.nozzleNow).toBe(220);
  expect(vm.nozzleTarget).toBe(220);
});

// Live H2C capture, 2026-07-07 — originally logged as "active_extruder is unreliable", actually the
// two numbering schemes: temps are position-ordered (`nozzle` = LEFT) while extruder ids are 0=RIGHT.
// ae=1 means LEFT — which IS the driven idx-0 head here. Both signals agree; driven still decides.
test('dual nozzle: the driven head wins (and the mapped active_extruder agrees)', () => {
  const vm = presentDashboard({
    ...h2cRunning,
    active_extruder: 1,
    temperatures: { bed: 70, bed_target: 70, nozzle: 245, nozzle_target: 245, nozzle_2: 46, nozzle_2_target: 0 },
  });
  expect(vm.nozzles[0].active).toBe(true); // left, driven
  expect(vm.nozzles[1].active).toBe(false); // right, idle — despite active_extruder=1
  expect(vm.nozzleNow).toBe(245);
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

// The WS sends AMS temp as a STRING ("30.4"); a raw .toFixed on it crashed the AMS tab (2026-07-05).
test('asNum coerces WS string-numbers and rejects junk', () => {
  expect(asNum('30.4')).toBe(30.4); // the exact WS value that crashed
  expect(asNum(31.2)).toBe(31.2); // REST number form
  expect(asNum(0)).toBe(0);
  expect(asNum('0')).toBe(0);
  expect(asNum(null)).toBeNull();
  expect(asNum(undefined)).toBeNull();
  expect(asNum('')).toBeNull();
  expect(asNum('n/a')).toBeNull();
  expect(asNum(NaN)).toBeNull();
  // Guard usage: a finite result is safe for .toFixed; null is filtered out before rendering.
  const t = asNum('30.4');
  expect(t != null && t > 0 ? t.toFixed(1) : '—').toBe('30.4');
});

test('presentDashboard tolerates string temps in the temperatures block', () => {
  const vm = presentDashboard({ ...running, temperatures: { nozzle: '220' as unknown as number, nozzle_target: '220' as unknown as number, bed: '60' as unknown as number, bed_target: '60' as unknown as number } });
  expect(vm.nozzleNow).toBe(220);
  expect(vm.bedNow).toBe(60);
});

// Mirrors the real live H2C rack payload (2026-07-18, mid-print, owner-verified sides): high-nibble
// 0 (ids 0,1) = the RIGHT fixed head — id 0 is the 0.6 holding the ACTIVE tray's black PLA — and
// high-nibble 1 (ids 16-21) = the LEFT 5-slot vortex, where several docked nozzles keep filament.
const h2cNozzles: PrinterStatus = {
  ...h2cRunning,
  temperatures: { ...h2cRunning.temperatures, nozzle: 44, nozzle_target: 0, nozzle_2: 220, nozzle_2_target: 220 },
  nozzles: [{ nozzle_type: 'HS01', nozzle_diameter: '0.6' }, { nozzle_type: 'HS01', nozzle_diameter: '0.4' }],
  nozzle_rack: [
    { id: 0, nozzle_type: 'HS01', nozzle_diameter: '0.6', wear: 128, max_temp: 350, serial_number: '20D06A5A1504039', filament_color: '161616FF' }, // RIGHT fixed, black PLA loaded
    { id: 1, nozzle_type: 'HS01', nozzle_diameter: '0.4', wear: 0, max_temp: 0, serial_number: 'N/A', filament_color: '00000000' }, // RIGHT empty slot -> dropped
    { id: 16, nozzle_type: 'HS01', nozzle_diameter: '0.4', wear: 128, max_temp: 350, serial_number: '20D06A5A2413139', filament_color: 'F330F9FF' }, // LEFT vortex, PETG loaded
    { id: 17, nozzle_type: 'HS00', nozzle_diameter: '0.2', wear: 128, max_temp: 350, serial_number: '20D06A5A2411698', filament_color: '00000000' }, // LEFT vortex
    { id: 18, nozzle_type: 'HS01', nozzle_diameter: '0.4', wear: 128, max_temp: 350, serial_number: '20D06A5A2416569', filament_color: 'C12E1FFF' }, // LEFT vortex, loaded too
  ],
};

describe('presentNozzles', () => {
  it('groups by toolhead: LEFT is the vortex (high-nibble 1), RIGHT the fixed head (high-nibble 0), Left listed first', () => {
    const { toolheads, hasVortex } = presentNozzles({ ...h2cNozzles, active_extruder: 0 });
    expect(hasVortex).toBe(true);
    expect(toolheads.map((t) => t.label)).toEqual(['Left', 'Right']);

    const left = toolheads[0];
    expect(left).toMatchObject({ side: 'left', swappable: true, active: false }); // ae=0 -> RIGHT is active
    expect(left.nozzles.map((n) => n.diameter)).toEqual(['0.4 mm', '0.2 mm', '0.4 mm']); // ids 16,17,18
    // TWO vortex nozzles keep filament loaded at once — real quick-swap behavior, both flagged.
    expect(left.nozzles.filter((n) => n.mounted).map((n) => n.key)).toEqual(['16', '18']);

    const right = toolheads[1];
    expect(right).toMatchObject({ side: 'right', swappable: false, active: true });
    expect(right.nozzles.map((n) => n.key)).toEqual(['0']); // id 1 (empty) dropped
    expect(right.nozzles[0]).toMatchObject({ diameter: '0.6 mm', type: 'Hardened', mounted: true, colorHex: '#161616' });
  });

  it('active toolhead follows active_extruder with Bambu ids (1 = left)', () => {
    const { toolheads } = presentNozzles({ ...h2cNozzles, active_extruder: 1 });
    expect(toolheads[0].active).toBe(true); // left (ext 1)
    expect(toolheads[1].active).toBe(false); // right (ext 0)
  });

  it('single-nozzle A1: one non-swappable toolhead, no vortex', () => {
    const a1: PrinterStatus = { ...running, nozzles: [{ nozzle_type: 'hardened_steel', nozzle_diameter: '0.4' }, { nozzle_type: '', nozzle_diameter: '' }], nozzle_rack: [] };
    const { toolheads, hasVortex } = presentNozzles(a1);
    expect(hasVortex).toBe(false);
    expect(toolheads).toHaveLength(1);
    expect(toolheads[0]).toMatchObject({ side: 'single', label: 'Nozzle', swappable: false });
    expect(toolheads[0].nozzles[0]).toMatchObject({ diameter: '0.4 mm', type: 'Hardened' });
  });

  it('is safe with no nozzle data', () => {
    expect(presentNozzles(null)).toEqual({ toolheads: [], hasVortex: false });
    expect(presentNozzles(running).toolheads).toEqual([]);
  });
});

test('both nozzles driven: the mapped active_extruder breaks the tie; hotter is the last resort', () => {
  // Both heads driven (250/250 vs 220/225): the driven signal can't decide, so the mapped
  // active_extruder does — ae=1 means LEFT (Bambu ids: 0=right), i.e. temps idx 0.
  const vm = presentDashboard({ ...h2cRunning, active_extruder: 1, temperatures: { nozzle: 250, nozzle_target: 250, nozzle_2: 220, nozzle_2_target: 225 } });
  expect(vm.nozzles[0].active).toBe(true);
  expect(vm.nozzles[1].active).toBe(false);
  // ae=0 means RIGHT -> temps idx 1, even though the left is hotter.
  const vmR = presentDashboard({ ...h2cRunning, active_extruder: 0, temperatures: { nozzle: 250, nozzle_target: 250, nozzle_2: 220, nozzle_2_target: 225 } });
  expect(vmR.nozzles[1].active).toBe(true);
  // With active_extruder absent, the hotter head is the fallback.
  const vm2 = presentDashboard({ ...h2cRunning, active_extruder: undefined, temperatures: { nozzle: 250, nozzle_target: 250, nozzle_2: 220, nozzle_2_target: 225 } });
  expect(vm2.nozzles[0].active).toBe(true);
});

// The definitive live capture (2026-07-18, mid-print, owner ground truth: "printing on the 0.6 on the
// RIGHT, left 0.4 idle"): nozzle_2 driven 220/220 + active_extruder 0 + tray_now's filament sitting in
// rack id 0 — all three agree that temps.nozzle_2 IS the right head and extruder id 0 IS right.
test('live H2C ground truth: right head (nozzle_2) active while printing right', () => {
  const vm = presentDashboard({
    ...h2cRunning,
    active_extruder: 0,
    temperatures: { bed: 55, bed_target: 55, nozzle: 44, nozzle_target: 0, nozzle_2: 220, nozzle_2_target: 220 },
  });
  expect(vm.nozzles[1].active).toBe(true); // idx 1 = nozzle_2 = RIGHT
  expect(vm.nozzleNow).toBe(220);
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
