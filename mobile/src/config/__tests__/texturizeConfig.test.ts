import { resolveTexturizeUrl } from '@/config/texturizeConfig';

test('derives texturize. from a bambuddy. host', () => {
  expect(resolveTexturizeUrl({ baseUrl: 'https://bambuddy.example.com' })).toBe('https://texturize.example.com');
});

test('trims whitespace and trailing slashes before deriving', () => {
  expect(resolveTexturizeUrl({ baseUrl: ' https://bambuddy.example.com/ ' })).toBe('https://texturize.example.com');
});

test('texturize:false forces OFF regardless of URLs (the user toggle)', () => {
  expect(resolveTexturizeUrl({ baseUrl: 'https://bambuddy.example.com', texturize: false })).toBeNull();
  expect(resolveTexturizeUrl({ baseUrl: 'https://x.com', texturizeUrl: 'https://tex.example.com', texturize: false })).toBeNull();
});

test('an explicit texturizeUrl wins over derivation (sidecar hosted elsewhere)', () => {
  expect(resolveTexturizeUrl({ baseUrl: 'https://bambuddy.example.com', texturizeUrl: 'https://tex.other.net' })).toBe('https://tex.other.net');
  expect(resolveTexturizeUrl({ baseUrl: 'http://192.168.1.5:8910', texturizeUrl: 'http://192.168.1.5:8912' })).toBe('http://192.168.1.5:8912');
});

test('a malformed explicit URL disables rather than pointing somewhere weird', () => {
  expect(resolveTexturizeUrl({ baseUrl: 'https://bambuddy.example.com', texturizeUrl: 'texturize.example.com' })).toBeNull();
  expect(resolveTexturizeUrl({ baseUrl: 'https://bambuddy.example.com', texturizeUrl: 'ftp://x' })).toBeNull();
});

test('returns null for non-bambuddy hosts with no explicit URL (feature hidden)', () => {
  expect(resolveTexturizeUrl({ baseUrl: 'https://printer.example.com' })).toBeNull();
  expect(resolveTexturizeUrl({ baseUrl: 'http://192.168.1.5:8910' })).toBeNull();
  expect(resolveTexturizeUrl({ baseUrl: '' })).toBeNull();
});
