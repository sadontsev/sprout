// Pure parameter normalization + pre-flight cost estimation. OUR code. Keeps the request surface the
// app sends small and safe, and rejects jobs that would blow the RAM budget BEFORE the pipeline runs
// (a fine refineLength on a big model can peak multiple GB — see the research bench numbers).

// The pipeline reads far more knobs than a person should tune. We expose a handful and pin the rest
// to the texturizer's own known-good defaults (bench-pipeline.mjs snapshot @ 80b471c). Anything not
// overridden below comes from here.
export const PIPELINE_DEFAULTS = {
  mappingMode: 5, scaleU: 0.5, scaleV: 0.5, amplitude: 0.5, textureHeight: 0.5,
  invertDisplacement: false, offsetU: 0, offsetV: 0, rotation: 0,
  refineLength: 0.3, maxTriangles: 500000, lockScale: true,
  bottomAngleLimit: 5, topAngleLimit: 0, mappingBlend: 1, seamBandWidth: 0.5,
  textureSmoothing: 0, blendNormalSmoothing: 32, capAngle: 20, boundaryFalloff: 0,
  symmetricDisplacement: false, noDownwardZ: false, smoothBottom: true,
  harvestFlatFaces: true, harvestTol: 0.005, snapSeamlessWrap: true,
  cylinderCenterX: null, cylinderCenterY: null, cylinderRadius: null,
  regularizeEnabled: true, regularizeAspectThreshold: 5, regularizeSlack: 3.0,
  regularizeAggressiveSlack: 8.0, regularizeExtremeAspect: 8,
  regularizeNormalDeg: 15, regularizeAggressiveNormalDeg: 25, regularizeSecondPassMul: 1.1,
};

// Projection modes the app's segmented control maps onto. Values are the texturizer's mappingMode ints.
export const MAPPING_MODES = { triplanar: 5, cubic: 1, cylindrical: 2, spherical: 3, planar_xy: 4, planar_xz: 6, planar_yz: 7 };

const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const num = (v, fallback) => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);

/**
 * Merge a small, validated app request onto the pinned defaults. Unknown keys are ignored (the app
 * can't set arbitrary pipeline internals). `refineLength` is floored so a malicious/fat-fingered tiny
 * value can't force a multi-GB subdivision — pre-flight then rejects anything still too big.
 */
export function normalizeParams(req = {}, { minRefineLength = 0.15 } = {}) {
  const s = { ...PIPELINE_DEFAULTS };
  if (req.mapping_mode != null) {
    s.mappingMode = typeof req.mapping_mode === 'string' ? (MAPPING_MODES[req.mapping_mode] ?? s.mappingMode) : req.mapping_mode;
  }
  s.amplitude = clamp(num(req.amplitude, s.amplitude), 0, 5);
  s.textureHeight = s.amplitude; // the pipeline reads both; keep them in lockstep
  s.scaleU = clamp(num(req.scale_u, s.scaleU), 0.01, 100);
  s.scaleV = req.lock_scale === false ? clamp(num(req.scale_v, s.scaleV), 0.01, 100) : s.scaleU;
  s.lockScale = req.lock_scale !== false;
  s.rotation = num(req.rotation, s.rotation);
  s.offsetU = num(req.offset_u, s.offsetU);
  s.offsetV = num(req.offset_v, s.offsetV);
  s.invertDisplacement = req.invert === true;
  s.symmetricDisplacement = req.symmetric === true;
  if (req.protect_bed === false) s.bottomAngleLimit = 0; // default protects the bed-contact face
  else if (req.bottom_angle_limit != null) s.bottomAngleLimit = clamp(num(req.bottom_angle_limit, 5), 0, 90);
  if (req.top_angle_limit != null) s.topAngleLimit = clamp(num(req.top_angle_limit, 0), 0, 90);
  s.refineLength = Math.max(minRefineLength, num(req.refine_length, s.refineLength));
  if (req.max_triangles != null) s.maxTriangles = clamp(Math.round(num(req.max_triangles, s.maxTriangles)), 1000, 4_000_000);
  return s;
}

// Empirically (research bench @ 80b471c) the intermediate triangle count is dominated by adaptive
// subdivision to edge length `refineLength`, i.e. ~ surfaceArea / refineLength². The 2.1 factor fits
// the measured rows (175k tris / 0.2mm on an 11,310mm² sphere peaked at ~2.14M intermediate tris).
const SUBDIV_FACTOR = 2.1;
export function estimateIntermediateTriangles(surfaceAreaMm2, refineLength) {
  if (!(surfaceAreaMm2 > 0) || !(refineLength > 0)) return 0;
  return Math.round((SUBDIV_FACTOR * surfaceAreaMm2) / (refineLength * refineLength));
}

// The pipeline holds ~145 bytes per intermediate triangle at peak (figure cited in the source).
export const BYTES_PER_TRIANGLE = 145;

/**
 * Pre-flight gate. Returns {ok, estTriangles, estPeakBytes, reason?}. Reject when the estimated peak
 * exceeds the configured triangle budget so we fail fast with a clear message instead of OOMing the
 * container mid-job.
 */
export function preflight({ surfaceAreaMm2, refineLength, budgetTriangles }) {
  const estTriangles = estimateIntermediateTriangles(surfaceAreaMm2, refineLength);
  const estPeakBytes = estTriangles * BYTES_PER_TRIANGLE;
  if (estTriangles > budgetTriangles) {
    return {
      ok: false,
      estTriangles,
      estPeakBytes,
      reason:
        `This model at ${refineLength}mm detail would subdivide to ~${(estTriangles / 1e6).toFixed(1)}M triangles ` +
        `(budget ${(budgetTriangles / 1e6).toFixed(1)}M). Use a coarser detail (larger refine_length) or a smaller model.`,
    };
  }
  return { ok: true, estTriangles, estPeakBytes };
}
