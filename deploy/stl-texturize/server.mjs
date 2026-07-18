// stl-texturize sidecar HTTP service. OUR code. Plain node:http (zero HTTP deps). One job at a time
// (texturizing is single-threaded + memory-hungry); the app POSTs a job and polls for the result,
// which lands as a NEW library file. Auth mirrors la-push: X-API-Key must be a key Bambuddy accepts
// (equality with BAMBUDDY_API_KEY fast-paths; scoped keys are validated against Bambuddy itself).
import http from 'node:http';
import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import sharp from 'sharp';
import { Bambuddy, texturedName } from './bambuddy.mjs';
import { recolorGreenToNeutral, greenFraction } from './thumbs.mjs';
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
// A job with commit:false finishes as a PREVIEW: the textured STL stays in `bytes` here (never
// touching the library) until the user POSTs /commit (upload) or the job is discarded/expired.
const jobs = new Map(); // id -> { status, stage, progress, result_file_id, warnings, error, createdAt, bytes?, name? }
const queue = [];
let running = false;
const PREVIEW_TTL_MS = 30 * 60_000;
const PREVIEW_MAX_STORED = 4; // bound RAM: a preview can be tens of MB

function setJob(id, patch) { jobs.set(id, { ...jobs.get(id), ...patch }); }
function dropPreview(id) { setJob(id, { bytes: undefined, name: undefined, expired: true }); }
function evictPreviews() {
  const stored = [...jobs.entries()].filter(([, j]) => j.bytes).sort((a, b) => a[1].createdAt - b[1].createdAt);
  for (const [id, j] of stored) if (Date.now() - j.createdAt > PREVIEW_TTL_MS) dropPreview(id);
  const alive = stored.filter(([, j]) => j.bytes);
  while (alive.length > PREVIEW_MAX_STORED) dropPreview(alive.shift()[0]);
}
setInterval(evictPreviews, 60_000).unref();

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

  const outName = texturedName(sourceName, req.file_id);
  if (req.commit === false) {
    // PREVIEW: hold the bytes for /result.stl + /commit — nothing enters the library uninvited.
    evictPreviews();
    setJob(id, { status: 'done', stage: 'done', progress: 1, preview: true, bytes: out.stlBytes, name: outName, warnings, out_triangles: out.outTriangles });
    return;
  }
  setJob(id, { stage: 'upload', progress: 0.92 });
  const uploaded = await bambuddy.uploadModel(out.stlBytes, outName);
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

// Accepted-key cache: sha256(key) -> expiry ms. Only keys Bambuddy ACCEPTED are cached (a garbage
// scan can't grow it), and raw keys are never stored. Equality with our configured key fast-paths.
const _keyCache = new Map();
const KEY_CACHE_TTL_MS = 5 * 60_000;
async function isValidKey(key) {
  if (!key || typeof key !== 'string') return false;
  if (key === API_KEY) return true;
  const h = createHash('sha256').update(key).digest('hex');
  const exp = _keyCache.get(h);
  if (exp && exp > Date.now()) return true;
  try {
    const r = await fetch(`${BAMBUDDY_URL}/api/v1/printers/`, { headers: { 'X-API-Key': key }, signal: AbortSignal.timeout(8000) });
    if (!r.ok) return false;
    _keyCache.set(h, Date.now() + KEY_CACHE_TTL_MS);
    return true;
  } catch {
    return false; // Bambuddy unreachable -> fail closed
  }
}

// ---- neutral STL thumbnails (Bambuddy's green-on-dark restyled for the app) ----
let _camTok = { token: null, at: 0 };
async function cameraToken() {
  if (_camTok.token && Date.now() - _camTok.at < 45 * 60_000) return _camTok.token;
  const r = await fetch(`${BAMBUDDY_URL}/api/v1/printers/camera/stream-token`, { method: 'POST', headers: { 'X-API-Key': API_KEY } });
  if (!r.ok) throw new Error(`stream-token -> HTTP ${r.status}`);
  _camTok = { token: (await r.json()).token, at: Date.now() };
  return _camTok.token;
}
const _thumbCache = new Map(); // fileId -> { bytes, at }
async function neutralThumb(fileId) {
  const hit = _thumbCache.get(fileId);
  if (hit && Date.now() - hit.at < 10 * 60_000) return hit.bytes;
  const tok = await cameraToken();
  const r = await fetch(`${BAMBUDDY_URL}/api/v1/library/files/${fileId}/thumbnail?token=${encodeURIComponent(tok)}`);
  if (!r.ok) throw new Error(`thumbnail -> HTTP ${r.status}`);
  const src = Buffer.from(await r.arrayBuffer());
  const { data, info } = await sharp(src).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  // Only Bambuddy's own green renders get remapped (STLs AND gcode.3mf it resliced itself).
  // Real slicer plate renders (grays) pass through untouched — the remap would blank them.
  let out;
  if (greenFraction(data) >= 0.02) {
    recolorGreenToNeutral(data);
    out = await sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } }).png().toBuffer();
  } else {
    out = src;
  }
  if (_thumbCache.size > 64) _thumbCache.clear(); // tiny bound; repopulates on demand
  _thumbCache.set(fileId, { bytes: out, at: Date.now() });
  return out;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true, queued: queue.length, running });

    // Everything else requires a VALID Bambuddy key (not necessarily OUR configured one — the app
    // may hold a scoped key; Bambuddy is the authority on what's valid).
    if (!(await isValidKey(req.headers['x-api-key']))) return send(res, 401, { error: 'unauthorized' });

    if (req.method === 'GET' && url.pathname === '/textures') return send(res, 200, await listTextures());

    if (req.method === 'GET' && parts[0] === 'file-thumb' && parts[1]) {
      try {
        return send(res, 200, await neutralThumb(parts[1]), { 'Content-Type': 'image/png', 'Cache-Control': 'max-age=600' });
      } catch (e) {
        return send(res, 404, { error: String(e?.message ?? e) });
      }
    }

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

    if (parts[0] === 'texturize-jobs' && parts[1]) {
      const job = jobs.get(parts[1]);
      if (!job) return send(res, 404, { error: 'no such job' });

      if (req.method === 'GET' && parts.length === 2) {
        const { bytes, ...pub } = job; // never serialize the STL buffer into the status JSON
        return send(res, 200, pub);
      }
      if (req.method === 'GET' && parts[2] === 'result.stl') {
        if (!job.bytes) return send(res, job.expired ? 410 : 404, { error: job.expired ? 'preview expired' : 'no preview bytes for this job' });
        return send(res, 200, job.bytes, { 'Content-Type': 'model/stl', 'Content-Length': String(job.bytes.length) });
      }
      if (req.method === 'POST' && parts[2] === 'commit') {
        if (!job.bytes) return send(res, job.expired ? 410 : 404, { error: job.expired ? 'preview expired' : 'nothing to commit' });
        const uploaded = await bambuddy.uploadModel(job.bytes, job.name || 'textured.stl');
        setJob(parts[1], { bytes: undefined, preview: false, result_file_id: uploaded.id });
        return send(res, 200, { file_id: uploaded.id });
      }
      if (req.method === 'DELETE' && parts.length === 2) {
        jobs.delete(parts[1]);
        return send(res, 200, { ok: true });
      }
    }

    return send(res, 404, { error: 'not found' });
  } catch (e) {
    return send(res, 500, { error: String(e?.message ?? e) });
  }
});

server.listen(PORT, () => console.log(`stl-texturize on :${PORT} (budget ${BUDGET_TRIANGLES} tris, min refine ${MIN_REFINE_LENGTH}mm)`));
