import { selectProcess, selectA1Process, pickDefaultQuality, isA1, supportTwinName, mountedNozzles, defaultNozzle, printerPresetNameFor, type PresetsResponse, type Preset } from '../presetSelect';

// Realistic slice of a /slicer/presets response (names verified against the live backend).
const RESP: PresetsResponse = {
  standard: {
    process: [
      { id: '1', name: '0.20mm Standard @BBL A1' },
      { id: '2', name: '0.20mm Strength @BBL A1' },
      { id: '3', name: '0.08mm Extra Fine @BBL A1' },
      { id: '4', name: '0.06mm Fine @BBL A1 0.2 nozzle' }, // wrong nozzle
      { id: '5', name: '0.30mm Standard @BBL A1 0.6 nozzle' }, // wrong nozzle
      { id: '6', name: '0.32mm Optimal @BBL A1 0.8 nozzle' }, // wrong nozzle
      { id: '7', name: '0.20mm Standard @BBL A1M' }, // A1 Mini, not our machine
      { id: '8', name: '0.20mm Standard @BBL P1P' }, // other printer
    ],
  },
  local: { process: [{ id: '100', name: '0.20mm Standard + Supports @BBL A1' }] }, // user's custom support profile
  cloud: {},
  orca_cloud: {},
};

describe('selectA1Process', () => {
  it('keeps only A1 0.4-nozzle BASE quality presets — support twins are not in the quality list', () => {
    const { qualities } = selectA1Process(RESP);
    const names = qualities.map((q) => q.name);
    expect(names).toEqual([
      '0.20mm Standard @BBL A1',
      '0.20mm Strength @BBL A1',
      '0.08mm Extra Fine @BBL A1',
    ]);
    expect(names.some((n) => /\+ Supports/i.test(n))).toBe(false); // twin excluded from the grid
    expect(names.some((n) => /0\.[268] nozzle/.test(n))).toBe(false);
    expect(names.some((n) => /A1M|P1P/.test(n))).toBe(false);
  });

  it('pairs each base quality to its support twin from the local group', () => {
    const { supportByBase, hasSupportProfile } = selectA1Process(RESP);
    expect(hasSupportProfile).toBe(true);
    expect(supportByBase['0.20mm Standard @BBL A1'].id).toBe('100'); // the local twin
    expect(supportByBase['0.20mm Strength @BBL A1']).toBeUndefined(); // no twin for this one
  });

  it('reports no support profile when none exist', () => {
    const noSupport: PresetsResponse = { standard: { process: [{ id: '1', name: '0.20mm Standard @BBL A1' }] } };
    const r = selectA1Process(noSupport);
    expect(r.hasSupportProfile).toBe(false);
    expect(r.supportByBase).toEqual({});
  });

  it('dedupes a profile echoed into multiple groups by id', () => {
    const dup: PresetsResponse = {
      standard: { process: [{ id: 'x', name: '0.20mm Standard @BBL A1' }] },
      cloud: { process: [{ id: 'x', name: '0.20mm Standard @BBL A1' }] },
    };
    expect(selectA1Process(dup).qualities).toHaveLength(1);
  });

  it('is safe on empty / missing input', () => {
    expect(selectA1Process(null)).toEqual({ qualities: [], supportByBase: {}, hasSupportProfile: false });
    expect(selectA1Process({})).toEqual({ qualities: [], supportByBase: {}, hasSupportProfile: false });
  });
});

describe('supportTwinName', () => {
  it('inserts "+ Supports" before the @BBL A1 suffix (matches the provisioning script)', () => {
    expect(supportTwinName('0.20mm Standard @BBL A1')).toBe('0.20mm Standard + Supports @BBL A1');
    expect(supportTwinName('Custom')).toBe('Custom + Supports');
  });
  it('works for other model tokens', () => {
    expect(supportTwinName('0.20mm Standard @BBL H2C', '@BBL H2C')).toBe('0.20mm Standard + Supports @BBL H2C');
  });
});

describe('selectProcess with the H2C token (names verified against the live backend)', () => {
  const H2C: PresetsResponse = {
    standard: {
      process: [
        { id: 'h1', name: '0.20mm Standard @BBL H2C' },
        { id: 'h2', name: '0.08mm High Quality @BBL H2C' },
        { id: 'h3', name: '0.10mm Standard @BBL H2C 0.2 nozzle' }, // wrong nozzle
        { id: 'd1', name: '0.20mm Standard @BBL H2D' }, // different machine
        { id: 'd2', name: '0.08mm Extra Fine @BBL H2DP' }, // H2D Pro must not leak in
        { id: 'a1', name: '0.20mm Standard @BBL A1' }, // different machine
      ],
    },
  };
  it('keeps only H2C 0.4-nozzle presets — no other H2-family machines, no A1', () => {
    const { qualities } = selectProcess(H2C, '@BBL H2C');
    expect(qualities.map((q) => q.name)).toEqual(['0.20mm Standard @BBL H2C', '0.08mm High Quality @BBL H2C']);
  });
  it('the A1 token does not pick up H2C presets', () => {
    const { qualities } = selectProcess(H2C, '@BBL A1');
    expect(qualities.map((q) => q.name)).toEqual(['0.20mm Standard @BBL A1']);
  });
});

describe('pickDefaultQuality', () => {
  const q = (name: string): Preset => ({ id: name, name });
  it('prefers 0.20mm Standard', () => {
    expect(pickDefaultQuality([q('0.08mm Fine @BBL A1'), q('0.20mm Standard @BBL A1'), q('0.20mm Strength @BBL A1')])?.name).toBe(
      '0.20mm Standard @BBL A1',
    );
  });
  it('falls back to any 0.20, then the first', () => {
    expect(pickDefaultQuality([q('0.08mm Fine @BBL A1'), q('0.20mm Strength @BBL A1')])?.name).toBe('0.20mm Strength @BBL A1');
    expect(pickDefaultQuality([q('0.08mm Fine @BBL A1')])?.name).toBe('0.08mm Fine @BBL A1');
    expect(pickDefaultQuality([])).toBeNull();
  });
});

describe('nozzle variants', () => {
  const H2: PresetsResponse = {
    standard: {
      process: [
        { id: '1', name: '0.20mm Standard @BBL H2C' },
        { id: '2', name: '0.08mm High Quality @BBL H2C' },
        { id: '3', name: '0.30mm Standard @BBL H2C 0.6 nozzle' },
        { id: '4', name: '0.36mm Standard @BBL H2C 0.6 nozzle' },
        { id: '5', name: '0.10mm Standard @BBL H2C 0.2 nozzle' },
        { id: '6', name: '0.30mm Standard @BBL H2D 0.6 nozzle' }, // other machine, same suffix
      ],
    },
  };
  it('nozzle 0.6 selects ONLY that variant family (not 0.4 bases, not other machines)', () => {
    const { qualities } = selectProcess(H2, '@BBL H2C', '0.6');
    expect(qualities.map((q) => q.name)).toEqual(['0.30mm Standard @BBL H2C 0.6 nozzle', '0.36mm Standard @BBL H2C 0.6 nozzle']);
  });
  it('default 0.4 keeps the old behavior (unsuffixed only)', () => {
    const { qualities } = selectProcess(H2, '@BBL H2C');
    expect(qualities.map((q) => q.name)).toEqual(['0.20mm Standard @BBL H2C', '0.08mm High Quality @BBL H2C']);
  });
  it('printerPresetNameFor builds the stock variant name', () => {
    expect(printerPresetNameFor('Bambu Lab H2C', '0.6')).toBe('Bambu Lab H2C 0.6 nozzle');
  });
  it('mountedNozzles reads live status (H2C: 0.6 left + 0.4 right), deduped, garbage dropped', () => {
    expect(mountedNozzles({ nozzles: [{ nozzle_diameter: '0.6' }, { nozzle_diameter: '0.4' }] })).toEqual(['0.6', '0.4']);
    expect(mountedNozzles({ nozzles: [{ nozzle_diameter: 0.4 }, { nozzle_diameter: '0.4' }, { nozzle_diameter: 'x' }] })).toEqual(['0.4']);
    expect(mountedNozzles(null)).toEqual([]);
  });
  it('defaultNozzle prefers 0.4 when mounted, else first mounted, else 0.4', () => {
    expect(defaultNozzle(['0.6', '0.4'])).toBe('0.4');
    expect(defaultNozzle(['0.6', '0.2'])).toBe('0.6');
    expect(defaultNozzle([])).toBe('0.4');
  });
});

describe('isA1', () => {
  it('matches A1 but not A1 Mini / A1M', () => {
    expect(isA1('0.20mm Standard @BBL A1')).toBe(true);
    expect(isA1('0.20mm Standard @BBL A1M')).toBe(false);
    expect(isA1('Bambu A1 mini something')).toBe(false);
    expect(isA1('0.20mm Standard @BBL P1S')).toBe(false);
  });
});
