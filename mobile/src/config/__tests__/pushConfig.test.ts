import { resolvePushUrl } from '../pushConfig';

const base = { baseUrl: 'https://bambuddy.example.com' } as const;

test('derives lapush host from a bambuddy.* base URL (server default on)', () => {
  expect(resolvePushUrl({ ...base })).toBe('https://lapush.example.com');
});

test('explicit pushUrl wins over the heuristic, trailing slash stripped', () => {
  expect(resolvePushUrl({ ...base, pushUrl: 'https://push.myhost.net/' })).toBe('https://push.myhost.net');
});

test('serverPush=false forces LOCAL (null) even with a resolvable URL', () => {
  expect(resolvePushUrl({ ...base, serverPush: false })).toBeNull();
  expect(resolvePushUrl({ ...base, pushUrl: 'https://push.x', serverPush: false })).toBeNull();
});

test('serverPush=true is the same as default (on)', () => {
  expect(resolvePushUrl({ ...base, serverPush: true })).toBe('https://lapush.example.com');
});

test('non-bambuddy host with no explicit pushUrl -> null (no server to derive)', () => {
  expect(resolvePushUrl({ baseUrl: 'https://printer.lan:8910' })).toBeNull();
});

test('a LAN IP base needs an explicit pushUrl', () => {
  expect(resolvePushUrl({ baseUrl: 'http://192.168.1.5:8910' })).toBeNull();
  expect(resolvePushUrl({ baseUrl: 'http://192.168.1.5:8910', pushUrl: 'http://192.168.1.5:8911' })).toBe('http://192.168.1.5:8911');
});

test('blank/whitespace pushUrl falls through to the heuristic', () => {
  expect(resolvePushUrl({ ...base, pushUrl: '   ' })).toBe('https://lapush.example.com');
});
