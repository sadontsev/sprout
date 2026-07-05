import { matchFilamentPreset, loadedFilaments, type FilamentPreset, type AmsTray, type AssignmentLike } from '../filamentMatch';

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
  const TRAYS: AmsTray[] = [
    { id: 0, tray_type: 'PLA-S', tray_color: '00000000', remain: 100 },
    { id: 1, tray_type: 'PETG-CF', tray_color: '565656FF', remain: 100 },
    { id: 2, tray_type: 'PLA', tray_color: '000000FF', remain: 100 },
    { id: 3, tray_type: undefined, tray_color: undefined, remain: 0 },
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
