import { presentDryer, dryDefaultFor, DRY_BLOCKERS, DRY_DEFAULTS } from '../dryer';
import type { PrinterStatus } from '@/api/types';

// The exact live H2C payload captured MID-DRY (2026-07-12): Handy-started cycle, so
// dry_target_temp is null and — crucially — dry_status is 0 while actively drying.
const liveDrying: PrinterStatus = {
  connected: true,
  state: 'IDLE',
  progress: 0,
  remaining_time: 0,
  layer_num: 0,
  total_layers: 0,
  subtask_name: '',
  chamber_light: false,
  temperatures: { nozzle: 38, nozzle_target: 0, bed: 25, bed_target: 0 },
  supports_drying: true,
  ams: [
    {
      id: 0,
      humidity: 25,
      temp: 44.7,
      is_ams_ht: false,
      module_type: 'n3f',
      dry_time: 344,
      dry_status: 0,
      dry_sub_status: 0,
      dry_sf_reason: [],
      dry_target_temp: null,
      dry_filament: 'PLA',
      tray: [
        { id: 0, tray_type: 'PLA', tray_color: '161616FF', drying_temp: 0, drying_time: 0 },
        { id: 1, tray_type: 'PLA-S', tray_color: '00000000', drying_temp: 70, drying_time: 8 },
        { id: 2, tray_type: 'PETG', tray_color: 'C9A38180', drying_temp: 65, drying_time: 8 },
        { id: 3, tray_type: 'PETG', tray_color: 'FFFFFFFF', drying_temp: 0, drying_time: 0 },
      ],
    },
  ],
} as PrinterStatus;

test('live payload: dry_time>0 means ACTIVE even with dry_status=0 (the real-world trap)', () => {
  const [d] = presentDryer(liveDrying);
  expect(d.active).toBe(true);
  expect(d.remainingMin).toBe(344);
  expect(d.remainingText).toBe('5h 44m');
  expect(d.filament).toBe('PLA');
  expect(d.humidityPct).toBe(25);
});

test('live payload: Handy-started cycle (null target) falls back to the drying filament’s recommendation', () => {
  const [d] = presentDryer(liveDrying);
  // dry_filament=PLA, the PLA tray has no preset data -> DRY_DEFAULTS.PLA (55)
  expect(d.targetTemp).toBe(55);
  // 44.7 < 55-3 -> still climbing
  expect(d.stage).toBe('heating');
});

test('options: deduped by type, preset beats 0/0 sibling, AMS 2 Pro clamps to 65°C', () => {
  const [d] = presentDryer(liveDrying);
  const byType = Object.fromEntries(d.options.map((o) => [o.type, o]));
  expect(d.options).toHaveLength(3); // PLA, PLA-S, PETG (two PETG trays deduped)
  // PLA-S preset says 70° but this unit (is_ams_ht=false) tops out at 65°.
  expect(byType['PLA-S']).toMatchObject({ temp: 65, hours: 8, fromPreset: true });
  // PETG: the 65/8 preset tray wins over the 0/0 sibling.
  expect(byType['PETG']).toMatchObject({ temp: 65, hours: 8, fromPreset: true });
  // PLA: no preset -> fallback.
  expect(byType['PLA']).toMatchObject({ temp: 55, hours: 8, fromPreset: false });
  expect(byType['PLA'].color).toBe('#161616');
});

test('AMS-HT: 85°C ceiling, so an 80° preset survives unclamped', () => {
  const s = {
    ...liveDrying,
    ams: [{ ...liveDrying.ams![0], is_ams_ht: true, tray: [{ id: 0, tray_type: 'PA', drying_temp: 80, drying_time: 12 }] }],
  } as PrinterStatus;
  const [d] = presentDryer(s);
  expect(d.maxTemp).toBe(85);
  expect(d.options[0]).toMatchObject({ type: 'PA', temp: 80, hours: 12 });
});

test('WS string form: numeric fields arrive as strings and still work', () => {
  const s = {
    ...liveDrying,
    ams: [{ ...liveDrying.ams![0], dry_time: '344', humidity: '25', temp: '44.7', dry_target_temp: '60' }],
  } as PrinterStatus;
  const [d] = presentDryer(s);
  expect(d.active).toBe(true);
  expect(d.humidityPct).toBe(25);
  expect(d.targetTemp).toBe(60); // explicit target wins over the recommendation fallback
  expect(d.stage).toBe('heating'); // 44.7 < 60-3
});

test('holding stage once at temperature', () => {
  const s = {
    ...liveDrying,
    ams: [{ ...liveDrying.ams![0], temp: 54.2, dry_target_temp: 55 }],
  } as PrinterStatus;
  expect(presentDryer(s)[0].stage).toBe('holding'); // 54.2 >= 55-3
});

test('idle unit: not active, no stage', () => {
  const s = { ...liveDrying, ams: [{ ...liveDrying.ams![0], dry_time: 0 }] } as PrinterStatus;
  const [d] = presentDryer(s);
  expect(d.active).toBe(false);
  expect(d.stage).toBeNull();
  expect(d.options).toHaveLength(3); // config options still offered
});

test('blockers: decoded to human text, unknown codes dropped, code 6 (already drying) omitted', () => {
  const s = {
    ...liveDrying,
    ams: [{ ...liveDrying.ams![0], dry_sf_reason: [3, '8', 6, 99] }],
  } as PrinterStatus;
  const [d] = presentDryer(s);
  expect(d.blockers).toEqual([DRY_BLOCKERS[3], DRY_BLOCKERS[8]]);
});

test('unsupported machine or no AMS -> no dryers', () => {
  expect(presentDryer(null)).toEqual([]);
  expect(presentDryer({ ...liveDrying, supports_drying: false } as PrinterStatus)).toEqual([]);
  expect(presentDryer({ ...liveDrying, ams: [] } as PrinterStatus)).toEqual([]);
});

test('heaterless unit (first-gen AMS on the same hub) gets NO card; dry-capable siblings still do', () => {
  const heaterless = { id: 1, humidity: 40, temp: 28, is_ams_ht: false, module_type: 'f1', tray: [{ id: 0, tray_type: 'PLA' }] };
  const s = { ...liveDrying, ams: [liveDrying.ams![0], heaterless] } as PrinterStatus;
  const dryers = presentDryer(s);
  expect(dryers).toHaveLength(1);
  expect(dryers[0].amsId).toBe(0);
});

test('fail-open: a unit with module_type n3f but no dry_* fields yet still gets a card', () => {
  const fresh = { id: 1, module_type: 'n3f', tray: [{ id: 0, tray_type: 'PLA' }] };
  const s = { ...liveDrying, ams: [fresh] } as PrinterStatus;
  const dryers = presentDryer(s);
  expect(dryers).toHaveLength(1);
  expect(dryers[0].active).toBe(false);
  expect(dryers[0].maxTemp).toBe(65);
});

test('fail-open: an unidentified unit that publishes dry_time gets a card', () => {
  const mystery = { id: 2, dry_time: 0, tray: [{ id: 0, tray_type: 'PLA' }] };
  const s = { ...liveDrying, ams: [mystery] } as PrinterStatus;
  expect(presentDryer(s)).toHaveLength(1);
});

test('empty trays produce no options', () => {
  const s = { ...liveDrying, ams: [{ ...liveDrying.ams![0], dry_time: 0, tray: [{ id: 0 }, { id: 1 }] }] } as PrinterStatus;
  expect(presentDryer(s)[0].options).toEqual([]);
});

test('dryDefaultFor: exact type, base-type prefix, then generic', () => {
  expect(dryDefaultFor('PETG')).toEqual(DRY_DEFAULTS.PETG);
  expect(dryDefaultFor('PETG-CF')).toEqual(DRY_DEFAULTS.PETG); // prefix fallback
  expect(dryDefaultFor('PLA-CF')).toEqual(DRY_DEFAULTS.PLA);
  expect(dryDefaultFor('WEIRDIUM')).toEqual({ temp: 55, hours: 8 }); // generic
});
