// Glue between OUR request/response world and the vendored texturizer. This is the ONE module that
// imports the AGPL code (fetched into ./vendor at Docker-build from the pinned SHA — see Dockerfile).
// It runs only inside the sidecar container; the app and Bambuddy never import it. Keeping the AGPL
// surface confined here is deliberate (see README §License).
import * as THREE from 'three';
import sharp from 'sharp';
import { runExportPipeline } from './vendor/js/exportPipeline.js';
import { buildFaceWeights } from './vendor/js/exclusion.js';
import { parseSTL, buildBinarySTL, surfaceArea, boundsOf } from './stl.mjs';

/** Decode any image (PNG/JPG/WebP) to greyscale-usable raw RGBA — the shape the pipeline samples. */
export async function decodeTexture(buffer) {
  const { data, info } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return { data: new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength), width: info.width, height: info.height };
}

// Angle-based bed/top masking, ported from bench-pipeline.mjs's buildCombinedFaceWeights (@80b471c).
// Faces whose normal points near-straight down (or up) within the limit are excluded from
// displacement so the bed-contact surface stays flat and the print still adheres.
function buildCombinedFaceWeights(geometry, settings) {
  // excludedFaces must be an ITERABLE of face indices (empty Set = "no painted exclusions"); the
  // vendored buildFaceWeights iterates it unconditionally, so null throws. Caught by smoke.mjs.
  const weights = buildFaceWeights(geometry, new Set(), /* invert */ false);
  if (settings.bottomAngleLimit <= 0 && settings.topAngleLimit <= 0) return weights;
  const posAttr = geometry.attributes.position;
  const triCount = posAttr.count / 3;
  const vA = new THREE.Vector3(), vB = new THREE.Vector3(), vC = new THREE.Vector3();
  const e1 = new THREE.Vector3(), e2 = new THREE.Vector3(), fn = new THREE.Vector3();
  for (let t = 0; t < triCount; t++) {
    if (weights[t * 3] > 0.99) continue;
    vA.fromBufferAttribute(posAttr, t * 3); vB.fromBufferAttribute(posAttr, t * 3 + 1); vC.fromBufferAttribute(posAttr, t * 3 + 2);
    e1.subVectors(vB, vA); e2.subVectors(vC, vA); fn.crossVectors(e1, e2);
    const area = fn.length();
    const nz = area > 1e-12 ? fn.z / area : 0;
    const ang = Math.acos(Math.abs(nz)) * (180 / Math.PI);
    const masked = nz < 0
      ? settings.bottomAngleLimit > 0 && ang <= settings.bottomAngleLimit
      : settings.topAngleLimit > 0 && ang <= settings.topAngleLimit;
    if (masked) { weights[t * 3] = 1; weights[t * 3 + 1] = 1; weights[t * 3 + 2] = 1; }
  }
  return weights;
}

function regularizeOpts(s) {
  return {
    aspectThreshold: s.regularizeAspectThreshold,
    slack: s.regularizeSlack,
    aggressiveSlack: s.regularizeAggressiveSlack,
    extremeSliverAspect: s.regularizeExtremeAspect,
    maxNormalDeltaCos: Math.cos((s.regularizeNormalDeg * Math.PI) / 180),
    aggressiveNormalDeltaCos: Math.cos((s.regularizeAggressiveNormalDeg * Math.PI) / 180),
  };
}

// Coarse stage → overall-progress mapping for the job status. The pipeline emits stages in this order.
const STAGE_PROGRESS = { subdivide: 0.15, regularize: 0.3, resubdivide: 0.4, displace: 0.55, decimate: 0.9, repair: 0.97 };

/**
 * Run the full texturize for one model + texture. Returns { stlBytes, inTriangles, outTriangles,
 * areaMm2 }. `onProgress(fraction, stage)` is called as the pipeline advances.
 */
export async function texturize({ modelBytes, textureBytes, settings, onProgress = () => {} }) {
  const positions = parseSTL(modelBytes);
  const inTriangles = positions.length / 9;
  const areaMm2 = surfaceArea(positions);

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  geometry.computeVertexNormals();
  const b = boundsOf(positions);
  const bounds = {
    min: new THREE.Vector3(...b.min),
    max: new THREE.Vector3(...b.max),
    size: new THREE.Vector3(...b.size),
    center: new THREE.Vector3(...b.center),
  };

  const img = await decodeTexture(textureBytes);
  const faceWeights = buildCombinedFaceWeights(geometry, settings);

  let lastStage = null;
  const onEvent = (stage, p, info) => {
    if (stage && stage !== lastStage) {
      lastStage = stage;
      onProgress(STAGE_PROGRESS[stage] ?? 0.5, stage);
    }
  };

  const result = await runExportPipeline(
    {
      positions: geometry.attributes.position.array,
      faceWeights,
      imageData: img,
      imgWidth: img.width,
      imgHeight: img.height,
      settings,
      bounds,
      regularizeOpts: regularizeOpts(settings),
      mode: 'export',
    },
    onEvent,
  );

  const outPositions = result.positions;
  const stlBytes = buildBinarySTL(outPositions);
  onProgress(1, 'done');
  return { stlBytes, inTriangles, outTriangles: outPositions.length / 9, areaMm2, safetyCapHit: !!result.safetyCapHit };
}
