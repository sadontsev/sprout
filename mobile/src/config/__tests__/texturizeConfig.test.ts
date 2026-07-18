import { resolveTexturizeUrl } from '@/config/texturizeConfig';

test('derives texturize. from a bambuddy. host', () => {
  expect(resolveTexturizeUrl({ baseUrl: 'https://bambuddy.example.com' })).toBe('https://texturize.example.com');
});

test('trims whitespace and trailing slashes before deriving', () => {
  expect(resolveTexturizeUrl({ baseUrl: ' https://bambuddy.example.com/ ' })).toBe('https://texturize.example.com');
});

test('returns null for non-bambuddy hosts (feature hidden)', () => {
  expect(resolveTexturizeUrl({ baseUrl: 'https://printer.example.com' })).toBeNull();
  expect(resolveTexturizeUrl({ baseUrl: 'http://192.168.1.5:8910' })).toBeNull();
  expect(resolveTexturizeUrl({ baseUrl: '' })).toBeNull();
});
