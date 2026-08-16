import { buildProcessDelta, buildFilamentDelta, hasProcessOverrides, overrideCount } from '@/library/sliceOverrides';

const BASE = '0.20mm Standard @BBL H2C';
const NAME = 'Sprout Custom @BBL H2C';

test('no overrides -> null (no preset churn)', () => {
  expect(buildProcessDelta(BASE, {}, NAME)).toBeNull();
  expect(buildFilamentDelta('Bambu PLA Basic @BBL H2C', {}, NAME)).toBeNull();
  expect(hasProcessOverrides({})).toBe(false);
  expect(hasProcessOverrides({ flowRatio: 1 })).toBe(false); // filament key, not process
});

test('delta carries ONLY the changed keys on top of the inherits envelope', () => {
  const s = buildProcessDelta(BASE, { wallLoops: 4, infillDensity: 15 }, NAME)!;
  expect(s).toEqual({
    type: 'process',
    name: NAME,
    from: 'User',
    inherits: BASE,
    wall_loops: '4',
    sparse_infill_density: '15%',
  });
});

test('booleans serialize as "1"/"0" and enums pass through (BambuStudio preset string convention)', () => {
  const s = buildProcessDelta(BASE, { primeTower: true, support: false, supportType: 'tree(auto)', supportStyle: 'snug', infillPattern: 'gyroid', topPattern: 'monotonic' }, NAME)!;
  expect(s.enable_prime_tower).toBe('1');
  expect(s.enable_support).toBe('0');
  expect(s.support_type).toBe('tree(auto)');
  expect(s.support_style).toBe('snug');
  expect(s.sparse_infill_pattern).toBe('gyroid');
  expect(s.top_surface_pattern).toBe('monotonic');
});

test('values are clamped to slicer-legal ranges', () => {
  const s = buildProcessDelta(BASE, { wallLoops: -2, infillDensity: 250, supportAngle: 120, primeTowerWidth: 0.5 }, NAME)!;
  expect(s.wall_loops).toBe('0');
  expect(s.sparse_infill_density).toBe('100%');
  expect(s.support_threshold_angle).toBe('90');
  expect(s.prime_tower_width).toBe('2');
});

test('filament delta replicates flow across the H2-series (extruder,variant) array; clamped 0.5–2', () => {
  const f = buildFilamentDelta('Bambu PLA Basic @BBL H2C', { flowRatio: 0.95 }, NAME, 3)!;
  expect(f.filament_flow_ratio).toEqual(['0.95', '0.95', '0.95']);
  expect(f.inherits).toBe('Bambu PLA Basic @BBL H2C');
  const hi = buildFilamentDelta('x', { flowRatio: 9 }, NAME, 1)!;
  expect(hi.filament_flow_ratio).toEqual(['2']);
});

test('overrideCount drives the badge', () => {
  expect(overrideCount({})).toBe(0);
  expect(overrideCount({ wallLoops: 3, flowRatio: 1.02 })).toBe(2);
});
