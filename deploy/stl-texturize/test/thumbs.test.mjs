import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recolorGreenToNeutral } from '../thumbs.mjs';

const px = (...pixels) => Uint8Array.from(pixels.flat());

test('green model pixels become opaque neutral gray, keeping shading order', () => {
  const d = recolorGreenToNeutral(px([0, 173, 65, 255], [0, 100, 40, 255]));
  // both opaque
  assert.equal(d[3], 255);
  assert.equal(d[7], 255);
  // neutral-ish: channels within a tight band (no green cast)
  assert.ok(Math.abs(d[0] - d[1]) < 20 && Math.abs(d[1] - d[2]) < 25);
  // brighter source green stays brighter (shading preserved)
  assert.ok(d[1] > d[5]);
});

test('dark background becomes fully transparent', () => {
  const d = recolorGreenToNeutral(px([26, 26, 26, 255]));
  assert.equal(d[3], 0);
});

test('non-green content (gray text, red accents) is treated as background', () => {
  const d = recolorGreenToNeutral(px([200, 200, 200, 255], [180, 40, 40, 255]));
  assert.equal(d[3], 0);
  assert.equal(d[7], 0);
});
