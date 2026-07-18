import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSTL, parseBinarySTL, parseAsciiSTL, buildBinarySTL, surfaceArea, boundsOf } from '../stl.mjs';

// One unit right-triangle in the z=0 plane: A(0,0,0) B(1,0,0) C(0,1,0). Area = 0.5.
const TRI = Float32Array.from([0, 0, 0, 1, 0, 0, 0, 1, 0]);

test('binary STL round-trips a triangle soup exactly', () => {
  const buf = buildBinarySTL(TRI);
  assert.equal(buf.length, 84 + 50, 'one triangle = 84 header + 50 bytes');
  assert.equal(buf.readUInt32LE(80), 1, 'triangle count in header');
  const back = parseBinarySTL(buf);
  assert.deepEqual(Array.from(back), Array.from(TRI));
});

test('parseSTL auto-detects binary via the exact size arithmetic', () => {
  const buf = buildBinarySTL(TRI);
  const back = parseSTL(buf);
  assert.deepEqual(Array.from(back), Array.from(TRI));
});

test('parseSTL falls back to ASCII when the size does not match a binary layout', () => {
  const ascii = `solid t
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 1 0 0
      vertex 0 1 0
    endloop
  endfacet
endsolid t`;
  const back = parseSTL(Buffer.from(ascii, 'utf8'));
  assert.deepEqual(Array.from(back), Array.from(TRI));
});

test('ASCII parse handles scientific notation and negatives', () => {
  const ascii = 'vertex -1.5e1 0 0 vertex 2E0 -3 0 vertex 0 0 1.0';
  const pos = parseAsciiSTL(ascii);
  assert.deepEqual(Array.from(pos), [-15, 0, 0, 2, -3, 0, 0, 0, 1]);
});

test('ASCII parse rejects a non-whole-triangle vertex count', () => {
  assert.throws(() => parseAsciiSTL('vertex 0 0 0 vertex 1 0 0'), /not a multiple of 3/);
});

test('buildBinarySTL computes a correct outward normal', () => {
  const buf = buildBinarySTL(TRI);
  // normal of A,B,C above is +z
  assert.equal(Math.round(buf.readFloatLE(84 + 8)), 1, 'nz ≈ 1');
  assert.equal(Math.round(buf.readFloatLE(84)), 0, 'nx ≈ 0');
});

test('buildBinarySTL rejects a malformed (non-multiple-of-9) array', () => {
  assert.throws(() => buildBinarySTL(Float32Array.from([0, 0, 0])), /multiple of 9/);
});

test('surfaceArea sums triangle areas', () => {
  assert.ok(Math.abs(surfaceArea(TRI) - 0.5) < 1e-6);
  const two = Float32Array.from([...TRI, ...TRI]);
  assert.ok(Math.abs(surfaceArea(two) - 1.0) < 1e-6);
});

test('boundsOf returns min/max/size/center', () => {
  const b = boundsOf(TRI);
  assert.deepEqual(b.min, [0, 0, 0]);
  assert.deepEqual(b.max, [1, 1, 0]);
  assert.deepEqual(b.size, [1, 1, 0]);
  assert.deepEqual(b.center, [0.5, 0.5, 0]);
});
