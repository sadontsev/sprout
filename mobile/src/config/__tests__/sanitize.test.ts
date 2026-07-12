import { sanitizeApiKey, sanitizeBaseUrl } from '@/config/sanitize';

// Fixture keys are SYNTHETIC — never paste a real credential into a test (it lives in git forever).
const FAKE_KEY = 'bb_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U1v2';

describe('sanitizeApiKey', () => {
  it('passes a clean key through unchanged', () => {
    expect(sanitizeApiKey(FAKE_KEY)).toBe(FAKE_KEY);
  });
  it('strips a trailing % (zsh EOL / URL-encode artifact)', () => {
    expect(sanitizeApiKey('bb_abc123%')).toBe('bb_abc123');
  });
  it('strips trailing/leading whitespace and newlines', () => {
    expect(sanitizeApiKey('  bb_abc123\n')).toBe('bb_abc123');
    expect(sanitizeApiKey('\tbb_abc123 ')).toBe('bb_abc123');
  });
  it('never touches interior characters', () => {
    expect(sanitizeApiKey('bb_a1B2c3D4')).toBe('bb_a1B2c3D4');
  });
});

describe('sanitizeBaseUrl', () => {
  it('trims whitespace and a trailing slash', () => {
    expect(sanitizeBaseUrl('  https://bambuddy.example.com/  ')).toBe('https://bambuddy.example.com');
  });
  it('removes internal whitespace from a fat-fingered paste', () => {
    expect(sanitizeBaseUrl('https://host .com')).toBe('https://host.com');
  });
});
