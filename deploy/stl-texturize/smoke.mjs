// Post-deploy smoke test: run one real texturize against the live sidecar + Bambuddy and poll it to
// completion. Usage:  BAMBUDDY_API_KEY=<key> FILE_ID=<library stl id> [TEXTURE=dots] node smoke.mjs
const BASE = process.env.TEXTURIZE_URL || 'http://localhost:8912';
const KEY = process.env.BAMBUDDY_API_KEY;
const FILE_ID = Number(process.env.FILE_ID);
const TEXTURE = process.env.TEXTURE || 'dots';
if (!KEY || !FILE_ID) { console.error('set BAMBUDDY_API_KEY and FILE_ID'); process.exit(1); }

const headers = { 'X-API-Key': KEY, 'Content-Type': 'application/json' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const health = await (await fetch(`${BASE}/health`)).json();
console.log('health:', health);

const start = await fetch(`${BASE}/texturize`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ file_id: FILE_ID, texture: { builtin: TEXTURE }, amplitude: 0.4, refine_length: 0.4 }),
});
if (!start.ok) { console.error('start failed:', start.status, await start.text()); process.exit(1); }
const { job_id } = await start.json();
console.log('job:', job_id);

for (let i = 0; i < 600; i++) {
  await sleep(1000);
  const job = await (await fetch(`${BASE}/texturize-jobs/${job_id}`, { headers })).json();
  process.stdout.write(`\r${job.status} · ${job.stage} · ${Math.round((job.progress ?? 0) * 100)}%   `);
  if (job.status === 'done') { console.log(`\n✅ done → new library file ${job.result_file_id}`, job.warnings?.length ? `warnings: ${job.warnings}` : ''); process.exit(0); }
  if (job.status === 'error') { console.log(`\n❌ ${job.error}`); process.exit(1); }
}
console.log('\ntimed out');
process.exit(1);
