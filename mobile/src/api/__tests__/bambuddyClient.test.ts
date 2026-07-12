import { BambuddyClient, apiErrorDetail } from '../bambuddyClient';

const fetchMock = jest.fn();
global.fetch = fetchMock as unknown as typeof fetch;

const client = new BambuddyClient({ baseUrl: 'https://x/', apiKey: 'bb_k' });

beforeEach(() => fetchMock.mockReset());

test('strips trailing slash from baseUrl', () => {
  expect(client.baseUrl).toBe('https://x');
});

test('wsBaseUrl converts https to wss', () => {
  expect(client.wsBaseUrl).toBe('wss://x');
});

test('getStatus hits the right URL with the API key header', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ connected: true, state: 'IDLE' }) });
  const s = await client.getStatus(1);
  expect(s.state).toBe('IDLE');
  const [url, opts] = fetchMock.mock.calls[0];
  expect(url).toBe('https://x/api/v1/printers/1/status');
  expect(opts.headers['X-API-Key']).toBe('bb_k');
});

test('setLight POSTs chamber-light with on query', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await client.setLight(1, false);
  const [url, opts] = fetchMock.mock.calls.at(-1)!;
  expect(url).toBe('https://x/api/v1/printers/1/chamber-light?on=false');
  expect(opts.method).toBe('POST');
});

test('setSpeed POSTs print-speed with mode', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await client.setSpeed(1, 3);
  expect(fetchMock.mock.calls.at(-1)![0]).toBe('https://x/api/v1/printers/1/print-speed?mode=3');
});

test('mintWsToken returns the token field', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ token: 'wstok' }) });
  expect(await client.mintWsToken()).toBe('wstok');
});

test('snapshotUrl includes the camera token', () => {
  expect(client.snapshotUrl(1, 'cam tok')).toBe('https://x/api/v1/printers/1/camera/snapshot?token=cam%20tok');
});

test('streamUrl includes the camera token and fps', () => {
  expect(client.streamUrl(1, 'tok', 10)).toBe('https://x/api/v1/printers/1/camera/stream?token=tok&fps=10');
});

test('fileThumbUrl embeds the camera token, and returns "" without a token or a server thumbnail', () => {
  expect(client.fileThumbUrl(7, 'cam tok')).toBe('https://x/api/v1/library/files/7/thumbnail?token=cam%20tok');
  expect(client.fileThumbUrl(7, null)).toBe('');
  expect(client.fileThumbUrl(7, 'tok', null)).toBe(''); // no server-side thumbnail -> don't request
  expect(client.fileThumbUrl(7, 'tok', '/some/path.png')).toBe('https://x/api/v1/library/files/7/thumbnail?token=tok');
});

test('throws with status on non-ok', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false, status: 401, text: async () => 'no' });
  await expect(client.getStatus(1)).rejects.toThrow(/401/);
});

test('extra headers (e.g. CF Access) are sent', async () => {
  const c = new BambuddyClient({ baseUrl: 'https://x', apiKey: 'bb_k', extraHeaders: { 'CF-Access-Client-Id': 'id' } });
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await c.getStatus(1);
  expect(fetchMock.mock.calls.at(-1)![1].headers['CF-Access-Client-Id']).toBe('id');
});

test('dryingStart sends hours (not minutes), filament and rotate_tray as query params', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await client.dryingStart(2, 0, { temp: 65, hours: 8, filament: 'PETG', rotate: true });
  const [url, opts] = fetchMock.mock.calls.at(-1)!;
  expect(url).toBe('https://x/api/v1/printers/2/drying/start?ams_id=0&temp=65&duration=8&filament=PETG&rotate_tray=true');
  expect(opts.method).toBe('POST');
});

test('dryingStart omits filament/rotate when not provided', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await client.dryingStart(2, 0, { temp: 55, hours: 4 });
  expect(fetchMock.mock.calls.at(-1)![0]).toBe('https://x/api/v1/printers/2/drying/start?ams_id=0&temp=55&duration=4');
});

test('dryingStop targets the unit', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await client.dryingStop(2, 0);
  expect(fetchMock.mock.calls.at(-1)![0]).toBe('https://x/api/v1/printers/2/drying/stop?ams_id=0');
});

test('apiErrorDetail surfaces the JSON detail from a Bambuddy error, else the raw message', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false, status: 409, text: async () => '{"detail":"AMS is busy"}' });
  const err = await client.dryingStart(2, 0, { temp: 55, hours: 4 }).catch((e) => e);
  expect(apiErrorDetail(err)).toBe('AMS is busy');
  expect(apiErrorDetail(new Error('plain failure'))).toBe('plain failure');
});
