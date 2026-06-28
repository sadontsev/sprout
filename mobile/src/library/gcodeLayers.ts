// Pure G-code -> per-layer toolpath parser for the layer viewer.
//
// We parse on the RN/JS side (testable, off the WebView) and hand the WebView only the rendered
// geometry as JSON. Each layer is a flat array of extrusion segments [x0,y0,x1,y1, x0,y0,x1,y1, ...]
// (numbers, not objects) to keep the payload compact for large prints.

export interface GcodeLayers {
  /** One entry per layer: flat [x0,y0,x1,y1,...] of extruding XY moves. */
  layers: number[][];
  /** XY extent of all extrusion, for fit-to-view. Always finite. */
  bounds: { minX: number; minY: number; maxX: number; maxY: number };
}

const EPS = 1e-6;

/**
 * Parse G0/G1 moves into layers, splitting a new layer at the first *extruding* move whose Z differs
 * from the current layer's Z. Keying layers off extrusion Z (not raw Z changes) makes this robust to
 * travel Z-hops, which would otherwise fragment layers. Honors G90/G91 (XYZ abs/rel), M82/M83 and
 * G90/G91 (E abs/rel), and G92 E (extruder reset). Comments (`;`) are stripped.
 */
export function parseGcodeLayers(gcode: string): GcodeLayers {
  const lines = gcode.split('\n');
  const layers: number[][] = [];
  let seg: number[] = [];
  let x = 0,
    y = 0,
    z = 0,
    e = 0;
  let absXYZ = true,
    absE = true;
  let layerZ: number | null = null;
  let minX = Infinity,
    minY = Infinity,
    maxX = -Infinity,
    maxY = -Infinity;

  const pushLayer = () => {
    if (seg.length) {
      layers.push(seg);
      seg = [];
    }
  };

  for (let li = 0; li < lines.length; li++) {
    let line = lines[li];
    const sc = line.indexOf(';');
    if (sc >= 0) line = line.slice(0, sc);
    line = line.trim();
    if (!line) continue;
    const t = line.split(/\s+/);
    const cmd = t[0];

    if (cmd === 'G90') {
      absXYZ = true;
      absE = true;
      continue;
    }
    if (cmd === 'G91') {
      absXYZ = false;
      absE = false;
      continue;
    }
    if (cmd === 'M82') {
      absE = true;
      continue;
    }
    if (cmd === 'M83') {
      absE = false;
      continue;
    }
    if (cmd === 'G92') {
      for (let i = 1; i < t.length; i++) {
        if (t[i][0] === 'E') {
          const v = parseFloat(t[i].slice(1));
          if (!isNaN(v)) e = v;
        }
      }
      continue;
    }
    if (cmd !== 'G0' && cmd !== 'G1') continue;

    let nx = x,
      ny = y,
      nz = z,
      ne = e,
      hasE = false,
      movedXY = false;
    for (let i = 1; i < t.length; i++) {
      const p = t[i];
      const v = parseFloat(p.slice(1));
      if (isNaN(v)) continue;
      const a = p[0];
      if (a === 'X') {
        nx = absXYZ ? v : x + v;
        movedXY = true;
      } else if (a === 'Y') {
        ny = absXYZ ? v : y + v;
        movedXY = true;
      } else if (a === 'Z') {
        nz = absXYZ ? v : z + v;
      } else if (a === 'E') {
        ne = absE ? v : e + v;
        hasE = true;
      }
    }

    const extruding = hasE && ne > e + EPS && movedXY && (nx !== x || ny !== y);
    if (extruding) {
      if (layerZ === null) layerZ = nz;
      else if (Math.abs(nz - layerZ) > 0.001) {
        pushLayer();
        layerZ = nz;
      }
      seg.push(x, y, nx, ny);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (nx < minX) minX = nx;
      if (nx > maxX) maxX = nx;
      if (ny < minY) minY = ny;
      if (ny > maxY) maxY = ny;
    }

    x = nx;
    y = ny;
    z = nz;
    if (hasE) e = ne;
  }
  pushLayer();

  if (!isFinite(minX)) {
    minX = 0;
    minY = 0;
    maxX = 256;
    maxY = 256;
  }
  return { layers, bounds: { minX, minY, maxX, maxY } };
}
