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

test('printerFileDownloadUrl encodes paths with spaces AND literal %20 (both exist on the real SD card)', () => {
  expect(client.printerFileDownloadUrl(2, '/Bambu_Cube_XYZ.gcode.3mf')).toBe(
    'https://x/api/v1/printers/2/files/download?path=%2FBambu_Cube_XYZ.gcode.3mf',
  );
  // Spaces -> +/%20; a literal "%20" in the NAME must round-trip as %2520, not collapse to a space.
  expect(client.printerFileDownloadUrl(2, '/Print%20plate Donor.gcode.3mf')).toBe(
    'https://x/api/v1/printers/2/files/download?path=%2FPrint%2520plate+Donor.gcode.3mf',
  );
});

test('printerPlateThumbUrl defaults to plate 1', () => {
  expect(client.printerPlateThumbUrl(2, '/a b.3mf')).toBe('https://x/api/v1/printers/2/files/plate-thumbnail/1?path=%2Fa+b.3mf');
  expect(client.printerPlateThumbUrl(2, '/a.3mf', 2)).toBe('https://x/api/v1/printers/2/files/plate-thumbnail/2?path=%2Fa.3mf');
});

test('deletePrinterFile DELETEs with the path query', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await client.deletePrinterFile(2, '/junk file.3mf');
  const [url, opts] = fetchMock.mock.calls.at(-1)!;
  expect(url).toBe('https://x/api/v1/printers/2/files?path=%2Fjunk+file.3mf');
  expect(opts.method).toBe('DELETE');
});

test('getPrinterFilePlates hits the plates endpoint', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ printer_id: 2, path: '/a.3mf', filename: 'a.3mf', plates: [] }) });
  await client.getPrinterFilePlates(2, '/a.3mf');
  expect(fetchMock.mock.calls.at(-1)![0]).toBe('https://x/api/v1/printers/2/files/plates?path=%2Fa.3mf');
});

test('authHeaders exposes the API key + extra headers for image/download requests', () => {
  expect(client.authHeaders()).toEqual({ 'X-API-Key': 'bb_k' });
  const c2 = new BambuddyClient({ baseUrl: 'https://x', apiKey: 'k', extraHeaders: { 'CF-Access-Client-Id': 'id' } });
  expect(c2.authHeaders()).toEqual({ 'X-API-Key': 'k', 'CF-Access-Client-Id': 'id' });
});

test('getPrinterFileGcode returns raw text from the SD gcode endpoint', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, text: async () => '; HEADER_BLOCK_START\nG1 X0' });
  const g = await client.getPrinterFileGcode(2, '/Bambu_Cube_XYZ.gcode.3mf');
  expect(g).toContain('HEADER_BLOCK_START');
  expect(fetchMock.mock.calls.at(-1)![0]).toBe('https://x/api/v1/printers/2/files/gcode?path=%2FBambu_Cube_XYZ.gcode.3mf');
});
