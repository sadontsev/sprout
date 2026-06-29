import { parseGcodeLayers } from '../gcodeLayers';

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
