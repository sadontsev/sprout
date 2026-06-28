import { BambuddyClient } from '../bambuddyClient';

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
