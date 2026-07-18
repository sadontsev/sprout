import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeParams, estimateIntermediateTriangles, preflight, MAPPING_MODES, PIPELINE_DEFAULTS } from '../params.mjs';

test('defaults come through untouched when the request is empty', () => {
  const s = normalizeParams({});
  assert.equal(s.mappingMode, PIPELINE_DEFAULTS.mappingMode);
  assert.equal(s.amplitude, 0.5);
  assert.equal(s.bottomAngleLimit, 5, 'bed is protected by default');
  assert.equal(s.lockScale, true);
});

test('maps a projection name to the pipeline mappingMode int', () => {
  assert.equal(normalizeParams({ mapping_mode: 'cylindrical' }).mappingMode, MAPPING_MODES.cylindrical);
  assert.equal(normalizeParams({ mapping_mode: 'triplanar' }).mappingMode, 5);
  // unknown name is ignored, keeping the default
  assert.equal(normalizeParams({ mapping_mode: 'nonsense' }).mappingMode, PIPELINE_DEFAULTS.mappingMode);
});

test('amplitude and scale are clamped to sane ranges', () => {
  assert.equal(normalizeParams({ amplitude: 999 }).amplitude, 5);
  assert.equal(normalizeParams({ amplitude: -1 }).amplitude, 0);
  assert.equal(normalizeParams({ amplitude: 0.8 }).textureHeight, 0.8, 'textureHeight tracks amplitude');
  assert.equal(normalizeParams({ scale_u: 0 }).scaleU, 0.01);
});

test('locked scale forces scaleV = scaleU regardless of scale_v', () => {
  const locked = normalizeParams({ scale_u: 2, scale_v: 9 });
  assert.equal(locked.scaleV, 2);
  const unlocked = normalizeParams({ scale_u: 2, scale_v: 9, lock_scale: false });
  assert.equal(unlocked.scaleV, 9);
});

test('protect_bed:false drops the bottom angle mask; else it can be tuned', () => {
  assert.equal(normalizeParams({ protect_bed: false }).bottomAngleLimit, 0);
  assert.equal(normalizeParams({ bottom_angle_limit: 20 }).bottomAngleLimit, 20);
});

test('refineLength is floored to protect against a runaway tiny value', () => {
  assert.equal(normalizeParams({ refine_length: 0.001 }).refineLength, 0.15);
  assert.equal(normalizeParams({ refine_length: 0.5 }).refineLength, 0.5);
  assert.equal(normalizeParams({ refine_length: 0.05 }, { minRefineLength: 0.4 }).refineLength, 0.4);
});

test('estimate scales with area / refineLength² (finer detail costs quadratically more)', () => {
  const coarse = estimateIntermediateTriangles(11310, 0.4);
  const fine = estimateIntermediateTriangles(11310, 0.2);
  assert.ok(fine > coarse);
  assert.ok(Math.abs(fine / coarse - 4) < 0.01, 'halving refineLength ≈ 4× triangles');
  assert.equal(estimateIntermediateTriangles(0, 0.2), 0);
  assert.equal(estimateIntermediateTriangles(100, 0), 0);
});

test('preflight passes a reasonable job and rejects an oversized one with a helpful reason', () => {
  const ok = preflight({ surfaceAreaMm2: 11310, refineLength: 0.3, budgetTriangles: 12_000_000 });
  assert.equal(ok.ok, true);
  assert.ok(ok.estTriangles > 0 && ok.estPeakBytes > 0);

  const bad = preflight({ surfaceAreaMm2: 500000, refineLength: 0.1, budgetTriangles: 12_000_000 });
  assert.equal(bad.ok, false);
  assert.match(bad.reason, /coarser detail|smaller model/);
  assert.ok(bad.estTriangles > 12_000_000);
});
