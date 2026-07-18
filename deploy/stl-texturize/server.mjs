// stl-texturize sidecar HTTP service. OUR code. Plain node:http (zero HTTP deps). One job at a time
// (texturizing is single-threaded + memory-hungry); the app POSTs a job and polls for the result,
// which lands as a NEW library file. Auth mirrors la-push: X-API-Key must equal BAMBUDDY_API_KEY.
import http from 'node:http';
import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Bambuddy, texturedName } from './bambuddy.mjs';
import { normalizeParams, preflight } from './params.mjs';
import { parseSTL, surfaceArea, boundsOf } from './stl.mjs';
import { texturize } from './pipeline.mjs';

const PORT = +(process.env.PORT || 8912);
const BAMBUDDY_URL = process.env.BAMBUDDY_URL || 'http://localhost:8910';
const API_KEY = process.env.BAMBUDDY_API_KEY;
const TEXTURES_DIR = process.env.TEXTURES_DIR || path.join(import.meta.dirname, 'textures');
const MIN_REFINE_LENGTH = +(process.env.TEXTURIZE_MIN_REFINE_LENGTH || 0.15);
const BUDGET_TRIANGLES = +(process.env.TEXTURIZE_MAX_TRIANGLES || 12_000_000);
const MAX_BODY_BYTES = +(process.env.TEXTURIZE_MAX_BODY_BYTES || 24 * 1024 * 1024); // custom textures are small

if (!API_KEY) { console.error('FATAL: BAMBUDDY_API_KEY is required (gates this service + calls Bambuddy)'); process.exit(1); }

const bambuddy = new Bambuddy({ baseUrl: BAMBUDDY_URL, apiKey: API_KEY });

// ---- in-memory job store + single-slot queue ----
const jobs = new Map(); // id -> { status, stage, progress, result_file_id, warnings, error, createdAt }
const queue = [];
let running = false;

function setJob(id, patch) { jobs.set(id, { ...jobs.get(id), ...patch }); }

async function runJob(id, req) {
  setJob(id, { status: 'running', stage: 'fetch', progress: 0.02 });
  const detail = await bambuddy.getFileDetail(req.file_id);
  const sourceName = detail.name ?? detail.filename ?? `model-${req.file_id}`;
  const token = await bambuddy.mintSlicerToken(req.file_id);
  const modelBytes = await bambuddy.downloadModel(req.file_id, token, sourceName);

  // Pre-flight on the REAL geometry now that we have it — reject before the expensive pipeline runs.
  const settings = normalizeParams(req, { minRefineLength: MIN_REFINE_LENGTH });
  const positions = parseSTL(modelBytes);
  const area = surfaceArea(positions);
  const pf = preflight({ surfaceAreaMm2: area, refineLength: settings.refineLength, budgetTriangles: BUDGET_TRIANGLES });
  if (!pf.ok) { setJob(id, { status: 'error', error: pf.reason }); return; }

  // Warn (don't block) when the displacement depth exceeds 10% of the smallest model dimension — it
  // can punch through a thin wall. Mirrors the texturizer's own guidance.
  const warnings = [];
  const minDim = Math.min(...boundsOf(positions).size.filter((d) => d > 0));
  if (Number.isFinite(minDim) && settings.amplitude > 0.1 * minDim) warnings.push('amplitude_exceeds_10pct_of_min_dimension');

  const textureBytes = await resolveTexture(req.texture);
  setJob(id, { stage: 'subdivide', progress: 0.1 });
  const out = await texturize({
    modelBytes, textureBytes, settings,
    onProgress: (fraction, stage) => setJob(id, { stage, progress: 0.1 + fraction * 0.8 }),
  });
  if (out.safetyCapHit) warnings.push('safety_triangle_cap_hit');

  setJob(id, { stage: 'upload', progress: 0.92 });
  const uploaded = await bambuddy.uploadModel(out.stlBytes, texturedName(sourceName, req.file_id));
  setJob(id, { status: 'done', stage: 'done', progress: 1, result_file_id: uploaded.id, warnings, out_triangles: out.outTriangles });
}

async function pump() {
  if (running || queue.length === 0) return;
  running = true;
  const { id, req } = queue.shift();
  try { await runJob(id, req); }
  catch (e) { setJob(id, { status: 'error', error: String(e?.message ?? e) }); }
  finally { running = false; setImmediate(pump); }
}

// ---- textures ----
async function listTextures() {
  if (!existsSync(TEXTURES_DIR)) return [];
  const files = await readdir(TEXTURES_DIR);
  return files
    .filter((f) => /\.(png|jpe?g|webp)$/i.test(f))
    .map((f) => ({ id: f.replace(/\.[^.]+$/, ''), name: f.replace(/\.[^.]+$/, '').replace(/[-_]/g, ' '), file: f }));
}
async function resolveTexture(texture) {
  if (texture?.image_b64) return Buffer.from(texture.image_b64, 'base64');
  const id = texture?.builtin ?? texture?.id;
  if (!id) throw new Error('texture must be { builtin: "<id>" } or { image_b64: "<base64>" }');
  const all = await listTextures();
  const hit = all.find((t) => t.id === id);
  if (!hit) throw new Error(`unknown builtin texture "${id}"`);
  return readFile(path.join(TEXTURES_DIR, hit.file));
}

// ---- http plumbing ----
const send = (res, code, body, headers = {}) => {
  const payload = Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body));
  res.writeHead(code, { 'Content-Type': Buffer.isBuffer(body) ? 'application/octet-stream' : 'application/json', ...headers });
  res.end(payload);
};
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on('data', (c) => { size += c.length; if (size > MAX_BODY_BYTES) { reject(new Error('request body too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true, queued: queue.length, running });

    // Everything else requires the shared key.
    if (req.headers['x-api-key'] !== API_KEY) return send(res, 401, { error: 'unauthorized' });

    if (req.method === 'GET' && url.pathname === '/textures') return send(res, 200, await listTextures());

    if (req.method === 'GET' && parts[0] === 'textures' && parts[2] === 'thumb') {
      const all = await listTextures();
      const hit = all.find((t) => t.id === parts[1]);
      if (!hit) return send(res, 404, { error: 'no such texture' });
      return send(res, 200, await readFile(path.join(TEXTURES_DIR, hit.file)), { 'Content-Type': 'image/' + hit.file.split('.').pop() });
    }

    if (req.method === 'POST' && url.pathname === '/texturize') {
      const body = JSON.parse((await readBody(req)).toString('utf8') || '{}');
      if (body.file_id == null) return send(res, 400, { error: 'file_id is required' });
      if (!body.texture) return send(res, 400, { error: 'texture is required ({builtin} or {image_b64})' });
      const id = randomUUID();
      jobs.set(id, { status: 'queued', stage: 'queued', progress: 0, createdAt: Date.now() });
      queue.push({ id, req: body });
      setImmediate(pump);
      return send(res, 202, { job_id: id });
    }

    if (req.method === 'GET' && parts[0] === 'texturize-jobs' && parts[1]) {
      const job = jobs.get(parts[1]);
      if (!job) return send(res, 404, { error: 'no such job' });
      return send(res, 200, job);
    }

    return send(res, 404, { error: 'not found' });
  } catch (e) {
    return send(res, 500, { error: String(e?.message ?? e) });
  }
});

server.listen(PORT, () => console.log(`stl-texturize on :${PORT} (budget ${BUDGET_TRIANGLES} tris, min refine ${MIN_REFINE_LENGTH}mm)`));
