import { TexturizeClient } from '../texturizeClient';

const fetchMock = jest.fn();
global.fetch = fetchMock as unknown as typeof fetch;

const client = new TexturizeClient({ baseUrl: 'https://t/', apiKey: 'bb_k' });

beforeEach(() => fetchMock.mockReset());

test('strips trailing slash from baseUrl', () => {
  expect(client.baseUrl).toBe('https://t');
});

test('listTextures GETs /textures with the API key', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => [{ id: 'dots', name: 'dots', file: 'dots.png' }] });
  const t = await client.listTextures();
  expect(t[0].id).toBe('dots');
  const [url, opts] = fetchMock.mock.calls[0];
  expect(url).toBe('https://t/textures');
  expect(opts.headers['X-API-Key']).toBe('bb_k');
});

test('textureThumbUrl encodes the id; authHeaders carries the key for RN Image', () => {
  expect(client.textureThumbUrl('carbon fiber')).toBe('https://t/textures/carbon%20fiber/thumb');
  expect(client.authHeaders()).toEqual({ 'X-API-Key': 'bb_k' });
});

test('start POSTs the job request as JSON and returns the job id', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ job_id: 'j1' }) });
  const r = await client.start({ file_id: 18, texture: { builtin: 'dots' }, amplitude: 0.4 });
  expect(r.job_id).toBe('j1');
  const [url, opts] = fetchMock.mock.calls[0];
  expect(url).toBe('https://t/texturize');
  expect(opts.method).toBe('POST');
  expect(JSON.parse(opts.body)).toEqual({ file_id: 18, texture: { builtin: 'dots' }, amplitude: 0.4 });
});

test('getJob polls the job endpoint', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ status: 'done', stage: 'done', progress: 1, result_file_id: 22 }) });
  const j = await client.getJob('j1');
  expect(j.result_file_id).toBe(22);
  expect(fetchMock.mock.calls[0][0]).toBe('https://t/texturize-jobs/j1');
});

test('non-ok responses throw with the status and body (e.g. pre-flight rejection)', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false, status: 413, text: async () => '{"error":"too many triangles"}' });
  await expect(client.start({ file_id: 1, texture: { builtin: 'dots' } })).rejects.toThrow(/413/);
});

test('preview flow: commit:false is sent; resultPath / commit / discard target the job', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ job_id: 'j9' }) });
  await client.start({ file_id: 18, texture: { builtin: 'dots' }, commit: false });
  expect(JSON.parse(fetchMock.mock.calls[0][1].body).commit).toBe(false);

  expect(client.resultPath('j9')).toBe('/texturize-jobs/j9/result.stl');

  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ file_id: 30 }) });
  expect(await client.commit('j9')).toEqual({ file_id: 30 });
  expect(fetchMock.mock.calls.at(-1)![0]).toBe('https://t/texturize-jobs/j9/commit');
  expect(fetchMock.mock.calls.at(-1)![1].method).toBe('POST');

  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ ok: true }) });
  await client.discard('j9');
  expect(fetchMock.mock.calls.at(-1)![0]).toBe('https://t/texturize-jobs/j9');
  expect(fetchMock.mock.calls.at(-1)![1].method).toBe('DELETE');
});

test('an expired preview surfaces the 410 so the sheet can explain it', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false, status: 410, text: async () => '{"error":"preview expired"}' });
  await expect(client.commit('old')).rejects.toThrow(/410/);
});
