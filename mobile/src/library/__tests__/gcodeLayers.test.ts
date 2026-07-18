import { parseGcodeLayers, gcodeViewerHtml } from '../gcodeLayers';

describe('parseGcodeLayers', () => {
  it('splits layers at extrusion Z changes and records segments', () => {
    const g = [
      'G90',
      'G1 Z0.2',
      'G1 X0 Y0 E0', // position move, no extrusion yet
      'G1 X10 Y0 E1', // extrude along bottom
      'G1 X10 Y10 E2', // extrude up the side
      'G1 Z0.4', // next layer
      'G1 X0 Y0 E2.5', // travel-ish but extruding -> still a segment
      'G1 X10 Y0 E3',
    ].join('\n');
    const { layers, layerZ, bounds } = parseGcodeLayers(g);
    expect(layers.length).toBe(2);
    // layer 1: two extruding segments -> 8 numbers
    expect(layers[0].length).toBe(8);
    expect(layers[0]).toEqual([0, 0, 10, 0, 10, 0, 10, 10]);
    expect(layerZ).toEqual([0.2, 0.4]); // index-aligned per-layer Z
    expect(bounds).toEqual({ minX: 0, minY: 0, maxX: 10, maxY: 10, minZ: 0.2, maxZ: 0.4 });
  });

  it('ignores travel moves (no E increase)', () => {
    const g = ['G90', 'G1 Z0.2', 'G1 X0 Y0', 'G0 X5 Y5', 'G1 X10 Y10 E1'].join('\n');
    const { layers } = parseGcodeLayers(g);
    expect(layers.length).toBe(1);
    expect(layers[0]).toEqual([5, 5, 10, 10]); // only the extruding move
  });

  it('does not create a spurious layer for a travel Z-hop (no extrusion at the hopped Z)', () => {
    const g = [
      'G90',
      'G1 Z0.2',
      'G1 X0 Y0 E0',
      'G1 X10 Y0 E1', // layer 1 extrusion
      'G1 Z1.0', // hop up (travel)
      'G0 X0 Y0', // travel at hop height, no E
      'G1 Z0.2', // hop back down
      'G1 X0 Y10 E2', // still layer 1 (same Z as first extrusion)
    ].join('\n');
    const { layers } = parseGcodeLayers(g);
    expect(layers.length).toBe(1);
  });

  it('handles relative extrusion (M83) so each E delta counts as extrusion', () => {
    const g = ['G90', 'M83', 'G1 Z0.2', 'G1 X0 Y0 E0', 'G1 X10 Y0 E0.5', 'G1 X10 Y10 E0.5'].join('\n');
    const { layers } = parseGcodeLayers(g);
    expect(layers[0].length).toBe(8); // two relative-extrude segments
  });

  it('honors G92 E reset without inventing extrusion', () => {
    const g = ['G90', 'G1 Z0.2', 'G1 X0 Y0 E5', 'G92 E0', 'G1 X10 Y0 E0.1'].join('\n');
    const { layers } = parseGcodeLayers(g);
    // After reset, E0.1 > 0 -> the move extrudes; first move had E5 from 0 -> also extrudes
    expect(layers.length).toBe(1);
    expect(layers[0]).toEqual([0, 0, 10, 0]);
  });

  it('strips comments and blank lines', () => {
    const g = ['; header', 'G90 ; absolute', '', 'G1 Z0.2', 'G1 X0 Y0 E0', 'G1 X4 Y0 E1 ; wall'].join('\n');
    const { layers } = parseGcodeLayers(g);
    expect(layers.length).toBe(1);
    expect(layers[0]).toEqual([0, 0, 4, 0]);
  });

  it('returns no layers and default bounds for empty / non-print input', () => {
    const { layers, layerZ, bounds } = parseGcodeLayers('; just comments\nM104 S200\n');
    expect(layers).toEqual([]);
    expect(layerZ).toEqual([]);
    expect(bounds).toEqual({ minX: 0, minY: 0, maxX: 256, maxY: 256, minZ: 0, maxZ: 1 });
  });
});

describe('parseGcodeLayers — supports', () => {
  it('separates support toolpath (; FEATURE: Support) from the model and flags it', () => {
    const g = [
      'G90',
      '; enable_support = 1',
      'G1 Z0.2',
      'G1 X0 Y0 E0',
      '; FEATURE: Outer wall',
      'G1 X10 Y0 E1', // model
      '; FEATURE: Support',
      'G1 X0 Y5 E2', // support
      'G1 X10 Y5 E3', // support
      '; FEATURE: Inner wall',
      'G1 X10 Y10 E4', // model
    ].join('\n');
    const { layers, supportLayers, hasSupport, supportEnabled } = parseGcodeLayers(g);
    expect(layers).toHaveLength(1);
    expect(supportLayers).toHaveLength(1);
    expect(layers[0]).toEqual([0, 0, 10, 0, 10, 5, 10, 10]); // walls only
    expect(supportLayers[0]).toEqual([10, 0, 0, 5, 0, 5, 10, 5]); // support only
    expect(hasSupport).toBe(true);
    expect(supportEnabled).toBe(true);
  });

  it('also catches "Support interface" as support', () => {
    const g = ['G90', 'G1 Z0.2', '; FEATURE: Support interface', 'G1 X0 Y0 E0', 'G1 X5 Y0 E1'].join('\n');
    const { supportLayers, hasSupport } = parseGcodeLayers(g);
    expect(hasSupport).toBe(true);
    expect(supportLayers[0]).toEqual([0, 0, 5, 0]);
  });

  it('reports no supports when none are present (enable_support = 0, no Support feature)', () => {
    const g = ['G90', '; enable_support = 0', 'G1 Z0.2', '; FEATURE: Outer wall', 'G1 X0 Y0 E0', 'G1 X5 Y0 E1'].join('\n');
    const { hasSupport, supportEnabled, supportLayers } = parseGcodeLayers(g);
    expect(hasSupport).toBe(false);
    expect(supportEnabled).toBe(false);
    expect(supportLayers[0]).toEqual([]);
  });
});

describe('gcodeViewerHtml (viewer contract)', () => {
  const tiny = parseGcodeLayers('G90\nG1 X10 Y10 Z0.2 E1\nG1 X20 Y10 E2\n');

  test('embeds the machine plate footprint; defaults to 256x256', () => {
    expect(gcodeViewerHtml(tiny, { w: 350, d: 320 })).toContain('{"w":350,"d":320}');
    expect(gcodeViewerHtml(tiny)).toContain('{"w":256,"d":256}');
  });

  test('ships the usability affordances: plate grid, reset, pan hint, axis gizmo, Z in the label', () => {
    const html = gcodeViewerHtml(tiny);
    expect(html).toContain('drawPlate');           // build plate + grid
    expect(html).toContain('resetView');           // double-tap / home button
    expect(html).toContain('2-finger pan');        // hint documents pan
    expect(html).toContain('drawGizmo');           // XYZ triad
    expect(html).toContain('mm');                  // layer label carries Z height
    expect(html).not.toContain('#0A0B0C;overflow'); // old flat-black body background is gone
  });

  test('renders extrusions via WebGL ribbons (solid-plastic look), not 1px canvas strokes', () => {
    const html = gcodeViewerHtml(tiny);
    expect(html).toContain("getContext('webgl'");
    expect(html).toContain('OES_element_index_uint'); // uint indices for >65k-vert prints
    expect(html).toContain('0.21*S');                 // ribbon half-width = half of 0.42mm extrusion
    expect(html).not.toContain('strokeLayer');        // the old line renderer is gone
  });

  test('embedded page script is syntactically valid JS', () => {
    const html = gcodeViewerHtml(tiny);
    const script = html.split('<script>')[1].split('</script>')[0];
    expect(() => new Function(script)).not.toThrow(); // compile-only — no DOM at parse time
  });
});

test('elevated leading purge layer (H2C) is excluded from bounds but still rendered', () => {
  // Purge at Z5.8 far right (X280->290), then the real model at Z0.2/0.4 around X10-20.
  const g = [
    'M83',
    'G1 X280 Y0 Z5.8 F3000',
    'G1 X290 Y0 E5', // purge line, elevated
    'G1 X10 Y10 Z0.2 F3000',
    'G1 X20 Y10 E1',
    'G1 X20 Y20 E1',
    'G1 X10 Y10 Z0.4 F3000',
    'G1 X20 Y10 E1',
  ].join('\n');
  const p = parseGcodeLayers(g);
  expect(p.layers).toHaveLength(3); // purge + 2 real layers — all kept for rendering
  expect(p.bounds.minZ).toBe(0.2); // NOT 5.8 (that made models look like they float)
  expect(p.bounds.maxZ).toBe(0.4);
  expect(p.bounds.maxX).toBe(20); // purge line no longer skews pivot/fit
  expect(p.bounds.minY).toBe(10);
});

test('no purge: normal ascending files keep full bounds', () => {
  const g = ['G1 X10 Y10 Z0.2 E1', 'G1 X30 Y10 E2', 'G1 X30 Y10 Z0.4 E3', 'G1 X10 Y10 E4'].join('\n');
  const p = parseGcodeLayers(g);
  expect(p.bounds.minZ).toBe(0.2);
  expect(p.bounds.maxZ).toBe(0.4);
  expect(p.bounds.maxX).toBe(30);
});
