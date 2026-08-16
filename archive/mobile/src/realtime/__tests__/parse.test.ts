import { parseWsFrame, parseWsMessage } from '../usePrinterStatus';

test('parseWsFrame surfaces EVERY printer on the shared socket (fleet map)', () => {
  const raw = JSON.stringify({ type: 'printer_status', printer_id: 2, data: { connected: true, state: 'RUNNING' } });
  const f = parseWsFrame(raw);
  expect(f?.printerId).toBe(2);
  expect(f?.status.state).toBe('RUNNING');
  expect(parseWsFrame(JSON.stringify({ type: 'pong' }))).toBeNull();
  expect(parseWsFrame('{bad')).toBeNull();
});

test('extracts printer_status for our printer', () => {
  const raw = JSON.stringify({
    type: 'printer_status',
    printer_id: 1,
    data: { connected: true, state: 'RUNNING', progress: 42 },
  });
  expect(parseWsMessage(raw, 1)?.state).toBe('RUNNING');
});

test('ignores other printers', () => {
  const raw = JSON.stringify({ type: 'printer_status', printer_id: 2, data: { state: 'X' } });
  expect(parseWsMessage(raw, 1)).toBeNull();
});

test('ignores non-status message types', () => {
  expect(parseWsMessage(JSON.stringify({ type: 'pong' }), 1)).toBeNull();
});

test('returns null on malformed json', () => {
  expect(parseWsMessage('{bad', 1)).toBeNull();
});
