import { parseWsMessage } from '../usePrinterStatus';

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
