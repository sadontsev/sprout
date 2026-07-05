import { printerProfile, slicedForMatchesPrinter } from '../profile';

test('A1 profile: token, preset base, AMS Lite, single nozzle', () => {
  const p = printerProfile({ model: 'A1', nozzle_count: 1 });
  expect(p.presetToken).toBe('@BBL A1');
  expect(p.printerPresetBase).toBe('Bambu Lab A1');
  expect(p.amsLabel).toBe('AMS Lite');
  expect(p.dualNozzle).toBe(false);
  expect(p.bedTypes[0].id).toBe('Textured PEI Plate'); // default plate first
});

test('H2C profile: token, dual nozzle, AMS 2 Pro, High Temp plate', () => {
  const p = printerProfile({ model: 'H2C', nozzle_count: 2 });
  expect(p.presetToken).toBe('@BBL H2C');
  expect(p.printerPresetBase).toBe('Bambu Lab H2C');
  expect(p.amsLabel).toBe('AMS 2 Pro');
  expect(p.dualNozzle).toBe(true);
  expect(p.bedTypes.map((b) => b.id)).toContain('High Temp Plate');
});

test('unknown model degrades to a generic profile, NOT to A1 behavior', () => {
  const p = printerProfile({ model: 'X9', nozzle_count: 2 });
  expect(p.presetToken).toBe('@BBL X9');
  expect(p.printerPresetBase).toBe('Bambu Lab X9');
  expect(p.dualNozzle).toBe(true);
});

test('null printer (list not loaded yet) falls back to the A1', () => {
  expect(printerProfile(null).presetToken).toBe('@BBL A1');
  expect(printerProfile(undefined).presetToken).toBe('@BBL A1');
});

describe('slicedForMatchesPrinter (wrong-machine G-code guard)', () => {
  const a1 = printerProfile({ model: 'A1', nozzle_count: 1 });
  const h2c = printerProfile({ model: 'H2C', nozzle_count: 2 });

  test('exact model and nozzle-suffixed variants match', () => {
    expect(slicedForMatchesPrinter('Bambu Lab A1', a1)).toBe(true);
    expect(slicedForMatchesPrinter('Bambu Lab A1 0.4 nozzle', a1)).toBe(true);
    expect(slicedForMatchesPrinter('Bambu Lab H2C', h2c)).toBe(true);
  });

  test('other machines are rejected — including the A1 mini vs A1 trap', () => {
    expect(slicedForMatchesPrinter('Bambu Lab A1', h2c)).toBe(false);
    expect(slicedForMatchesPrinter('Bambu Lab H2C', a1)).toBe(false);
    expect(slicedForMatchesPrinter('Bambu Lab A1 mini', a1)).toBe(false);
  });

  test('unknown/empty embedded printer is allowed (no data, no block)', () => {
    expect(slicedForMatchesPrinter(null, h2c)).toBe(true);
    expect(slicedForMatchesPrinter('', h2c)).toBe(true);
    expect(slicedForMatchesPrinter(undefined, a1)).toBe(true);
  });
});
