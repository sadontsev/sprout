import { test } from 'node:test';
import assert from 'node:assert/strict';
import { texturedName } from '../bambuddy.mjs';

test('texturedName strips the extension and appends -textured.stl', () => {
  assert.equal(texturedName('benchy.stl', 1), 'benchy-textured.stl');
  assert.equal(texturedName('box.3mf', 1), 'box-textured.stl');
  assert.equal(texturedName('part.gcode.3mf', 1), 'part-textured.stl');
  assert.equal(texturedName('thing.obj', 1), 'thing-textured.stl');
});

test('texturedName decodes %20-style residue from URL-encoded uploads', () => {
  assert.equal(texturedName('Adapter%20hexagon%20for%20electric%20drill.stl', 18), 'Adapter hexagon for electric drill-textured.stl');
});

test('texturedName survives a malformed percent-sequence and a missing name', () => {
  assert.equal(texturedName('bad%zz.stl', 3), 'bad%zz-textured.stl');
  assert.equal(texturedName('', 7), 'model-7-textured.stl');
  assert.equal(texturedName(null, 9), 'model-9-textured.stl');
});
