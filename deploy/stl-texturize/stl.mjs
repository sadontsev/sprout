// Pure, dependency-free STL I/O. OUR code (not derived from the AGPL texturizer) — parsing/writing
// binary+ASCII STL is mechanical. The texturizer pipeline works in "triangle soup": a Float32Array
// of length triCount*9 (three xyz vertices per triangle, no shared/indexed vertices, no normals).
// Everything here speaks that representation so it round-trips cleanly and stays unit-testable in
// plain Node with no three/sharp install.

/** Detect + parse an STL (binary or ASCII) into a Float32Array of length triCount*9. */
export function parseSTL(buf) {
  // Reliable discriminator: a binary STL is exactly 84 + 50*triCount bytes. The leading "solid"
  // token is NOT reliable (some binary writers put "solid" in the 80-byte header), so size-match
  // first and only fall back to ASCII when the arithmetic doesn't hold.
  if (buf.length >= 84) {
    const n = buf.readUInt32LE(80);
    if (buf.length === 84 + n * 50) return parseBinarySTL(buf, n);
  }
  return parseAsciiSTL(buf.toString('utf8'));
}

export function parseBinarySTL(buf, n = buf.readUInt32LE(80)) {
  const pos = new Float32Array(n * 9);
  let o = 84;
  for (let i = 0; i < n; i++) {
    o += 12; // skip the (often-zero, unreliable) per-facet normal
    for (let v = 0; v < 9; v++) {
      pos[i * 9 + v] = buf.readFloatLE(o);
      o += 4;
    }
    o += 2; // attribute byte count
  }
  return pos;
}

export function parseAsciiSTL(text) {
  const coords = [];
  const re = /vertex\s+(-?[\d.eE+-]+)\s+(-?[\d.eE+-]+)\s+(-?[\d.eE+-]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    coords.push(parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]));
  }
  if (coords.length % 9 !== 0) {
    throw new Error(`ASCII STL vertex count ${coords.length / 3} is not a multiple of 3 (not whole triangles)`);
  }
  return Float32Array.from(coords);
}

/** Serialize a triangle-soup Float32Array (triCount*9) to a binary STL Buffer. Per-facet normals are
 *  computed from the winding so slicers that read them get sane values. */
export function buildBinarySTL(pos, header = 'sprout stl-texturize') {
  const n = pos.length / 9;
  if (!Number.isInteger(n)) throw new Error(`positions length ${pos.length} is not a multiple of 9`);
  const buf = Buffer.alloc(84 + n * 50);
  buf.write(header.slice(0, 79), 0, 'ascii'); // 80-byte header, rest left zero
  buf.writeUInt32LE(n, 80);
  let o = 84;
  for (let i = 0; i < n; i++) {
    const b = i * 9;
    const ax = pos[b], ay = pos[b + 1], az = pos[b + 2];
    const bx = pos[b + 3], by = pos[b + 4], bz = pos[b + 5];
    const cx = pos[b + 6], cy = pos[b + 7], cz = pos[b + 8];
    // normal = normalize((B-A) x (C-A))
    const ux = bx - ax, uy = by - ay, uz = bz - az;
    const vx = cx - ax, vy = cy - ay, vz = cz - az;
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    const len = Math.hypot(nx, ny, nz) || 1;
    nx /= len; ny /= len; nz /= len;
    buf.writeFloatLE(nx, o); buf.writeFloatLE(ny, o + 4); buf.writeFloatLE(nz, o + 8); o += 12;
    for (let v = 0; v < 9; v++) { buf.writeFloatLE(pos[b + v], o); o += 4; }
    o += 2; // attribute byte count (0)
  }
  return buf;
}

/** Total surface area (mm²) — the axis pre-flight cost estimation scales on (see params.mjs). */
export function surfaceArea(pos) {
  const n = pos.length / 9;
  let area = 0;
  for (let i = 0; i < n; i++) {
    const b = i * 9;
    const ux = pos[b + 3] - pos[b], uy = pos[b + 4] - pos[b + 1], uz = pos[b + 5] - pos[b + 2];
    const vx = pos[b + 6] - pos[b], vy = pos[b + 7] - pos[b + 1], vz = pos[b + 8] - pos[b + 2];
    const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
    area += 0.5 * Math.hypot(cx, cy, cz);
  }
  return area;
}

/** Axis-aligned bounds as plain arrays (pipeline.mjs wraps these in THREE.Vector3). */
export function boundsOf(pos) {
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < pos.length; i += 3) {
    for (let a = 0; a < 3; a++) {
      const val = pos[i + a];
      if (val < min[a]) min[a] = val;
      if (val > max[a]) max[a] = val;
    }
  }
  const size = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
  const center = [(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2];
  return { min, max, size, center };
}
