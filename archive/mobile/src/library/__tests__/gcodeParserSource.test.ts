import { GCODE_PARSER_JS } from '@/library/gcodeParserSource';

// The parser SHIPS as source embedded in the viewer page, so the only honest way to test it is to
// execute that exact string — no second TypeScript copy to drift from. This runs the same semantic
// suite the old RN-side parser had.
const parseGcode: (t: string) => {
  layers: Float32Array[];
  sup: Float32Array[];
  zs: number[];
  supportEnabled: boolean;
  hasSupport: boolean;
  segTotal: number;
  bounds: { minX: number; minY: number; maxX: number; maxY: number; minZ: number; maxZ: number };
} = new Function(`${GCODE_PARSER_JS}; return parseGcode;`)();

const arr = (a: Float32Array) => Array.from(a);

describe('in-page G-code parser', () => {
  it('splits layers at extrusion Z changes and records segments', () => {
    const g = ['G90', 'G1 Z0.2', 'G1 X0 Y0 E0', 'G1 X10 Y0 E1', 'G1 X10 Y10 E2', 'G1 Z0.4', 'G1 X0 Y0 E2.5', 'G1 X10 Y0 E3'].join('\n');
    const p = parseGcode(g);
    expect(p.layers).toHaveLength(2);
    expect(arr(p.layers[0])).toEqual([0, 0, 10, 0, 10, 0, 10, 10]);
    expect(p.zs).toEqual([0.2, 0.4]);
    expect(p.bounds).toEqual({ minX: 0, minY: 0, maxX: 10, maxY: 10, minZ: 0.2, maxZ: 0.4 });
  });

  it('ignores travel moves (no E increase)', () => {
    const p = parseGcode(['G90', 'G1 Z0.2', 'G1 X0 Y0', 'G0 X5 Y5', 'G1 X10 Y10 E1'].join('\n'));
    expect(p.layers).toHaveLength(1);
    expect(arr(p.layers[0])).toEqual([5, 5, 10, 10]);
  });

  it('does not create a spurious layer for a travel Z-hop', () => {
    const g = ['G90', 'G1 Z0.2', 'G1 X0 Y0 E0', 'G1 X10 Y0 E1', 'G1 Z1.0', 'G0 X0 Y0', 'G1 Z0.2', 'G1 X0 Y10 E2'].join('\n');
    expect(parseGcode(g).layers).toHaveLength(1);
  });

  it('handles relative extrusion (M83) and G92 E resets', () => {
    expect(parseGcode(['G90', 'M83', 'G1 Z0.2', 'G1 X0 Y0 E0', 'G1 X10 Y0 E0.5', 'G1 X10 Y10 E0.5'].join('\n')).layers[0]).toHaveLength(8);
    const g92 = parseGcode(['G90', 'G1 Z0.2', 'G1 X0 Y0 E5', 'G92 E0', 'G1 X10 Y0 E0.1'].join('\n'));
    expect(arr(g92.layers[0])).toEqual([0, 0, 10, 0]);
  });

  it('strips comments and blank lines', () => {
    const p = parseGcode(['; header', 'G90 ; absolute', '', 'G1 Z0.2', 'G1 X0 Y0 E0', 'G1 X4 Y0 E1 ; wall'].join('\n'));
    expect(arr(p.layers[0])).toEqual([0, 0, 4, 0]);
  });

  it('separates support toolpath and flags it', () => {
    const g = [
      'G90', '; enable_support = 1', 'G1 Z0.2', 'G1 X0 Y0 E0',
      '; FEATURE: Outer wall', 'G1 X10 Y0 E1',
      '; FEATURE: Support', 'G1 X0 Y5 E2', 'G1 X10 Y5 E3',
      '; FEATURE: Inner wall', 'G1 X10 Y10 E4',
    ].join('\n');
    const p = parseGcode(g);
    expect(arr(p.layers[0])).toEqual([0, 0, 10, 0, 10, 5, 10, 10]);
    expect(arr(p.sup[0])).toEqual([10, 0, 0, 5, 0, 5, 10, 5]);
    expect(p.hasSupport).toBe(true);
    expect(p.supportEnabled).toBe(true);
  });

  it('reports no supports when none are present', () => {
    const p = parseGcode(['G90', '; enable_support = 0', 'G1 Z0.2', '; FEATURE: Outer wall', 'G1 X0 Y0 E0', 'G1 X5 Y0 E1'].join('\n'));
    expect(p.hasSupport).toBe(false);
    expect(p.supportEnabled).toBe(false);
  });

  it('excludes the elevated purge layer from bounds but still renders it', () => {
    const g = ['M83', 'G1 X280 Y0 Z5.8 F3000', 'G1 X290 Y0 E5', 'G1 X10 Y10 Z0.2 F3000', 'G1 X20 Y10 E1', 'G1 X20 Y20 E1', 'G1 X10 Y10 Z0.4 F3000', 'G1 X20 Y10 E1'].join('\n');
    const p = parseGcode(g);
    expect(p.layers).toHaveLength(3); // purge layer still drawn
    expect(p.bounds.minZ).toBe(0.2); // NOT 5.8
    expect(p.bounds.maxX).toBe(20); // purge line doesn't skew the fit
  });

  it('handles a final line with no trailing newline', () => {
    expect(arr(parseGcode('G90\nG1 X0 Y0 Z0.2 E0\nG1 X5 Y0 E1').layers[0])).toEqual([0, 0, 5, 0]);
  });

  it('returns empty layers and default bounds for non-print input', () => {
    const p = parseGcode('; just comments\nM104 S200\n');
    expect(p.layers).toEqual([]);
    expect(p.bounds).toEqual({ minX: 0, minY: 0, maxX: 256, maxY: 256, minZ: 0, maxZ: 1 });
  });

  it('emits Float32Arrays and a segment count (the GPU buffer size)', () => {
    const p = parseGcode(['G90', 'G1 Z0.2', 'G1 X0 Y0 E0', 'G1 X10 Y0 E1', 'G1 X10 Y10 E2'].join('\n'));
    expect(p.layers[0]).toBeInstanceOf(Float32Array);
    expect(p.segTotal).toBe(2);
  });

  it('grows past its initial buffer without losing or reordering segments', () => {
    // 4096 floats = 1024 segments initially; 3000 segments forces two doublings.
    const lines = ['G90', 'G1 Z0.2', 'G1 X0 Y0 E0'];
    for (let i = 1; i <= 3000; i++) lines.push(`G1 X${i} Y0 E${i}`);
    const p = parseGcode(lines.join('\n'));
    expect(p.segTotal).toBe(3000);
    const L = p.layers[0];
    expect(Array.from(L.slice(0, 4))).toEqual([0, 0, 1, 0]);
    expect(Array.from(L.slice(-4))).toEqual([2999, 0, 3000, 0]);
  });
});
