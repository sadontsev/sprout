import { selectA1Process, pickDefaultQuality, isA1, supportTwinName, type PresetsResponse, type Preset } from '../presetSelect';

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

describe('isA1', () => {
  it('matches A1 but not A1 Mini / A1M', () => {
    expect(isA1('0.20mm Standard @BBL A1')).toBe(true);
    expect(isA1('0.20mm Standard @BBL A1M')).toBe(false);
    expect(isA1('Bambu A1 mini something')).toBe(false);
    expect(isA1('0.20mm Standard @BBL P1S')).toBe(false);
  });
});
