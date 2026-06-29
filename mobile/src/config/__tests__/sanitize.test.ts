import { sanitizeApiKey, sanitizeBaseUrl } from '@/config/sanitize';

describe('sanitizeApiKey', () => {
  it('passes a clean key through unchanged', () => {
    expect(sanitizeApiKey('bb_REDACTED_ROTATED')).toBe(
      'bb_REDACTED_ROTATED',
    );
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
