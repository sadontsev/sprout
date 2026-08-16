import { splitDigits, confettiPieces, clamp01 } from '../animUtils';

describe('splitDigits', () => {
  it('maps each 0-9 to a digit token and everything else to a char token', () => {
    expect(splitDigits('10')).toEqual([
      { kind: 'digit', d: 1 },
      { kind: 'digit', d: 0 },
    ]);
    expect(splitDigits('1h 48m')).toEqual([
      { kind: 'digit', d: 1 },
      { kind: 'char', ch: 'h' },
      { kind: 'char', ch: ' ' },
      { kind: 'digit', d: 4 },
      { kind: 'digit', d: 8 },
      { kind: 'char', ch: 'm' },
    ]);
  });

  it('accepts numbers and preserves separators like . and :', () => {
    expect(splitDigits(12.4).map((t) => (t.kind === 'digit' ? t.d : t.ch))).toEqual([1, 2, '.', 4]);
    expect(splitDigits('12:34').filter((t) => t.kind === 'char')).toEqual([{ kind: 'char', ch: ':' }]);
  });

  it('handles empty + non-numeric', () => {
    expect(splitDigits('')).toEqual([]);
    expect(splitDigits('—')).toEqual([{ kind: 'char', ch: '—' }]);
  });
});

describe('confettiPieces', () => {
  // A simple deterministic PRNG so the test is reproducible.
  const seeded = (s: number) => () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s / 0x7fffffff;
  };

  it('produces exactly `count` pieces with colors drawn from the palette', () => {
    const colors = ['#a', '#b', '#c'];
    const pieces = confettiPieces(20, seeded(1), colors);
    expect(pieces).toHaveLength(20);
    for (const p of pieces) {
      expect(colors).toContain(p.color);
      expect(p.left).toBeGreaterThanOrEqual(0);
      expect(p.left).toBeLessThanOrEqual(100);
      expect(p.fall).toBeGreaterThan(0);
    }
  });

  it('is deterministic for a given seed and clamps count at 0', () => {
    const a = confettiPieces(5, seeded(42), ['#x']);
    const b = confettiPieces(5, seeded(42), ['#x']);
    expect(a).toEqual(b);
    expect(confettiPieces(-3, seeded(1), ['#x'])).toEqual([]);
  });

  it('never produces an undefined color even with an empty palette', () => {
    const pieces = confettiPieces(3, seeded(7), []);
    expect(pieces.every((p) => typeof p.color === 'string' && p.color.length > 0)).toBe(true);
  });
});

describe('clamp01', () => {
  it('clamps to [0,1]', () => {
    expect(clamp01(-0.5)).toBe(0);
    expect(clamp01(1.5)).toBe(1);
    expect(clamp01(0.4)).toBe(0.4);
  });
});
