// Pure pixel transform for Bambuddy's STL thumbnails. OUR code.
//
// Bambuddy renders STL previews as a GREEN model on an OPAQUE dark background (observed:
// bg=(26,26,26,255), model≈(0,173,65) with shading). That clashes with the app's look. This remaps:
// greenish pixels -> a neutral light gray that keeps the shading (luminance from the green channel),
// everything else -> fully transparent, so the card's own background shows through.

/** Fraction of visible pixels that read as "Bambuddy green". Used to decide recolor vs passthrough —
 *  real slicer plate renders (grays) must NOT be remapped (the remap would blank them). */
export function greenFraction(data) {
  let green = 0, visible = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] > 10) {
      visible++;
      if (data[i + 1] > data[i] + 18 && data[i + 1] > data[i + 2] + 18) green++;
    }
  }
  return visible ? green / visible : 0;
}

/** In-place RGBA remap. `data` is a Uint8Array/Buffer of RGBA pixels. Returns the same buffer. */
export function recolorGreenToNeutral(data) {
  for (let i = 0; i < data.length; i += 4) {
    const r = data[i], g = data[i + 1], b = data[i + 2];
    if (g > r + 18 && g > b + 18) {
      // Shaded neutral: keep the model's lighting via the green channel, lift into a light range.
      const L = Math.min(255, 96 + g * 0.62);
      data[i] = Math.round(L * 0.93);
      data[i + 1] = Math.round(L * 0.96);
      data[i + 2] = Math.min(255, Math.round(L * 1.04));
      data[i + 3] = 255;
    } else {
      data[i + 3] = 0; // background (and any non-green residue) -> transparent
    }
  }
  return data;
}
