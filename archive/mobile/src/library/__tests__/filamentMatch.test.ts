import { matchFilamentPreset, loadedFilaments, type FilamentPreset, type AssignmentLike } from '../filamentMatch';
import type { AmsTrayRef } from '@/ams/units';

/** Build a unit-0 tray ref, matching the pre-multi-unit fixtures (global id === local id there). */
const ref = (localId: number, trayType?: string, trayColor?: string, unitId = 0): AmsTrayRef => ({
  unitId,
  unitLabel: unitId >= 128 ? 'AMS HT' : `AMS ${unitId + 1}`,
  localId,
  globalId: unitId >= 128 ? unitId : unitId * 4 + localId,
  trayType,
  trayColor,
});

const PRESETS: FilamentPreset[] = [
  { id: 'a', name: 'Bambu PLA Basic @BBL A1' },
  { id: 'b', name: 'Bambu PLA Basic @BBL A1M' }, // wrong machine
  { id: 'c', name: 'Bambu PETG-CF @BBL A1 0.4 nozzle' },
  { id: 'd', name: 'Bambu PETG-CF @BBL A1 0.8 nozzle' }, // wrong nozzle
  { id: 'e', name: 'Bambu Support For PLA @BBL A1' },
  { id: 'f', name: 'Bambu ABS @BBL A1' },
];

describe('matchFilamentPreset', () => {
  it('matches by slicer name (exact base)', () => {
    expect(matchFilamentPreset(PRESETS, 'Bambu PLA Basic', 'PLA')?.id).toBe('a');
  });
  it('matches by slicer name to the 0.4-nozzle variant when no base exists', () => {
    expect(matchFilamentPreset(PRESETS, 'Bambu PETG-CF', 'PETG-CF')?.id).toBe('c');
  });
  it('falls back to material type when no slicer name', () => {
    expect(matchFilamentPreset(PRESETS, null, 'PLA')?.id).toBe('a');
    expect(matchFilamentPreset(PRESETS, null, 'PETG-CF')?.id).toBe('c');
    expect(matchFilamentPreset(PRESETS, null, 'ABS')?.id).toBe('f');
  });
  it('never returns the wrong machine or nozzle variant', () => {
    const m = matchFilamentPreset(PRESETS, 'Bambu PLA Basic', 'PLA');
    expect(m?.name).not.toMatch(/A1M|0\.8 nozzle/);
  });
  it('returns null for an unknown material', () => {
    expect(matchFilamentPreset(PRESETS, null, 'UNOBTANIUM')).toBeNull();
  });
});

describe('matchFilamentPreset with the H2C token', () => {
  const H2C_PRESETS: FilamentPreset[] = [
    { id: 'h1', name: 'Bambu PETG HF @BBL H2C' },
    { id: 'h2', name: 'Bambu PETG HF @BBL H2C 0.8 nozzle' }, // wrong nozzle
    { id: 'd1', name: 'Bambu PETG HF @BBL H2D' }, // different machine
    ...PRESETS,
  ];
  it('picks the H2C preset, never the H2D or A1 one', () => {
    expect(matchFilamentPreset(H2C_PRESETS, null, 'PETG', '@BBL H2C')?.id).toBe('h1');
  });
  it('the default token still resolves to the A1', () => {
    expect(matchFilamentPreset(H2C_PRESETS, null, 'PLA')?.id).toBe('a');
  });
  it('returns null when the machine has no preset for the material', () => {
    expect(matchFilamentPreset(H2C_PRESETS, null, 'ABS', '@BBL H2C')).toBeNull();
  });
});

describe('loadedFilaments', () => {
  // Real AMS shape: tray 0 support, 1 PETG-CF (gray), 2 PLA (black), 3 empty.
  const TRAYS: AmsTrayRef[] = [
    ref(0, 'PLA-S', '00000000'),
    ref(1, 'PETG-CF', '565656FF'),
    ref(2, 'PLA', '000000FF'),
    ref(3, undefined, undefined),
  ];
  const ASSIGNS: AssignmentLike[] = [
    { tray_id: 1, spool: { material: 'PETG-CF', color_name: 'Titan Gray', rgba: '565656FF', slicer_filament_name: 'Bambu PETG-CF' } },
  ];

  it('builds one option per loaded tray, skipping empty slots', () => {
    const out = loadedFilaments(TRAYS, ASSIGNS, PRESETS);
    expect(out.map((o) => o.slot)).toEqual([0, 1, 2]); // tray 3 empty -> skipped
  });
  it('uses inventory slicer name + color_name when available, else the tray data', () => {
    const out = loadedFilaments(TRAYS, ASSIGNS, PRESETS);
    const petg = out.find((o) => o.slot === 1)!;
    expect(petg.material).toBe('PETG-CF');
    expect(petg.colorName).toBe('Titan Gray');
    expect(petg.colorHex).toBe('#565656'); // normColor strips alpha
    expect(petg.preset?.id).toBe('c');
    const pla = out.find((o) => o.slot === 2)!;
    expect(pla.colorName).toBeNull(); // no inventory -> tray only
    expect(pla.preset?.id).toBe('a'); // mapped by material type
  });
  it('flags support filament', () => {
    const out = loadedFilaments(TRAYS, ASSIGNS, PRESETS);
    expect(out.find((o) => o.slot === 0)!.isSupport).toBe(true);
    expect(out.find((o) => o.slot === 1)!.isSupport).toBe(false);
  });
});

// ---- Nozzle-size resolution. Fixtures mirror the LIVE H2C set (189 presets, captured 2026-07-19):
// every material ships a bare form; size variants exist only where Bambu tuned one. The convention is
// asymmetric and these two materials ARE the whole spec:
//   Bambu PLA Basic @BBL H2C -> bare + 0.2/0.6/0.8, NO 0.4  (0.4 must resolve to the bare form)
//   Bambu PETG-CF  @BBL H2C -> bare + 0.4               (0.4 must resolve to the SUFFIXED one)
describe('matchFilamentPreset — nozzle size', () => {
  const { catalogFilaments } = require('../filamentMatch');
  const P: FilamentPreset[] = [
    { id: 'pla-bare', name: 'Bambu PLA Basic @BBL H2C' },
    { id: 'pla-02', name: 'Bambu PLA Basic @BBL H2C 0.2 nozzle' },
    { id: 'pla-06', name: 'Bambu PLA Basic @BBL H2C 0.6 nozzle' },
    { id: 'pla-08', name: 'Bambu PLA Basic @BBL H2C 0.8 nozzle' },
    { id: 'cf-bare', name: 'Bambu PETG-CF @BBL H2C' },
    { id: 'cf-04', name: 'Bambu PETG-CF @BBL H2C 0.4 nozzle' },
    { id: 'other-model', name: 'Bambu PLA Basic @BBL A1M 0.6 nozzle' },
  ];
  const pick = (name: string, nozzle?: never) => matchFilamentPreset(P, name, null, '@BBL H2C', nozzle);

  it('0.4 falls back to the bare form when no 0.4 variant exists', () => {
    expect(matchFilamentPreset(P, 'Bambu PLA Basic', null, '@BBL H2C', '0.4')?.id).toBe('pla-bare');
  });
  it('0.4 prefers an explicit 0.4 variant when one exists', () => {
    expect(matchFilamentPreset(P, 'Bambu PETG-CF', null, '@BBL H2C', '0.4')?.id).toBe('cf-04');
  });
  it('0.6 / 0.2 / 0.8 pick their own variant (was impossible: pool was 0.4-only)', () => {
    expect(matchFilamentPreset(P, 'Bambu PLA Basic', null, '@BBL H2C', '0.6')?.id).toBe('pla-06');
    expect(matchFilamentPreset(P, 'Bambu PLA Basic', null, '@BBL H2C', '0.2')?.id).toBe('pla-02');
    expect(matchFilamentPreset(P, 'Bambu PLA Basic', null, '@BBL H2C', '0.8')?.id).toBe('pla-08');
  });
  it('a size with no variant falls back to bare — never to a DIFFERENT size', () => {
    expect(matchFilamentPreset(P, 'Bambu PETG-CF', null, '@BBL H2C', '0.6')?.id).toBe('cf-bare');
    expect(matchFilamentPreset(P, 'Bambu PLA Basic', null, '@BBL H2C', '0.4')?.id).not.toBe('pla-06');
  });
  it('defaults to 0.4 when the caller omits the size (back-compat)', () => {
    expect(pick('Bambu PLA Basic')?.id).toBe('pla-bare');
  });
  it('never leaks another printer model, whatever the size', () => {
    expect(matchFilamentPreset(P, 'Bambu PLA Basic', null, '@BBL A1', '0.6')).toBeNull();
  });
  it('catalogFilaments resolves per size and keeps curated order', () => {
    const c06 = catalogFilaments(P, '@BBL H2C', '0.6').map((p: FilamentPreset) => p.id);
    expect(c06).toEqual(['pla-06', 'cf-bare']); // PLA Basic before PETG-CF, each at its best match
    const c04 = catalogFilaments(P, '@BBL H2C', '0.4').map((p: FilamentPreset) => p.id);
    expect(c04).toEqual(['pla-bare', 'cf-04']);
  });
});

describe('loadedFilaments — nozzle size', () => {
  it('threads the nozzle through to each tray’s preset', () => {
    const P: FilamentPreset[] = [
      { id: 'bare', name: 'Bambu PETG HF @BBL H2C' },
      { id: 'six', name: 'Bambu PETG HF @BBL H2C 0.6 nozzle' },
    ];
    const trays: AmsTrayRef[] = [ref(0, 'PETG', '000000FF')];
    const asg: AssignmentLike[] = [];
    expect(loadedFilaments(trays, asg, P, '@BBL H2C', '0.6')[0].preset?.id).toBe('six');
    expect(loadedFilaments(trays, asg, P, '@BBL H2C', '0.4')[0].preset?.id).toBe('bare');
  });
});

describe('loadedFilaments across MULTIPLE AMS units', () => {
  const P: FilamentPreset[] = [
    { id: 'petg', name: 'Bambu PETG-CF @BBL H2C', filament_type: 'PETG' } as FilamentPreset,
    { id: 'pla', name: 'Bambu PLA Basic @BBL H2C', filament_type: 'PLA' } as FilamentPreset,
  ];
  // Two AMS 2 Pro units + an HT, as fitted. Each unit has a local tray 0 — they must not collide.
  const TRAYS = [ref(0, 'PETG-CF', '565656FF', 0), ref(0, 'PLA', '000000FF', 1), ref(0, 'PETG-CF', 'FFFFFFFF', 128)];

  it('emits GLOBAL tray ids, so slots stay addressable across units', () => {
    const out = loadedFilaments(TRAYS, [], P, '@BBL H2C', '0.4');
    expect(out.map((f) => f.slot)).toEqual([0, 4, 128]);
    expect(out.map((f) => f.unitLabel)).toEqual(['AMS 1', 'AMS 2', 'AMS HT']);
    expect(out.every((f) => f.localId === 0)).toBe(true); // all local 0 — the collision case
  });

  it('binds an inventory spool to the RIGHT unit, not merely the right tray number', () => {
    // Before this, matching on tray_id alone gave AMS 2 and the HT the AMS 1 spool: wrong brand,
    // wrong colour name, and a wrong slicer preset that then drove the slice.
    const asg: AssignmentLike[] = [
      { ams_id: 0, tray_id: 0, spool: { color_name: 'Titan Gray', slicer_filament_name: 'Bambu PETG-CF' } },
      { ams_id: 1, tray_id: 0, spool: { color_name: 'Jet Black', slicer_filament_name: 'Bambu PLA Basic' } },
    ];
    const out = loadedFilaments(TRAYS, asg, P, '@BBL H2C', '0.4');
    expect(out[0].colorName).toBe('Titan Gray');
    expect(out[1].colorName).toBe('Jet Black');
    expect(out[2].colorName).toBeNull(); // HT has no assignment — must not inherit one
  });

  it('still matches a legacy assignment that carries no ams_id', () => {
    const legacy: AssignmentLike[] = [{ tray_id: 0, spool: { color_name: 'Legacy' } }];
    const out = loadedFilaments(TRAYS, legacy, P, '@BBL H2C', '0.4');
    expect(out[0].colorName).toBe('Legacy');
  });

  it('prefers an exact unit match over a legacy unit-less one', () => {
    const mixed: AssignmentLike[] = [
      { tray_id: 0, spool: { color_name: 'Legacy' } },
      { ams_id: 1, tray_id: 0, spool: { color_name: 'Exact' } },
    ];
    expect(loadedFilaments(TRAYS, mixed, P, '@BBL H2C', '0.4')[1].colorName).toBe('Exact');
  });
});
