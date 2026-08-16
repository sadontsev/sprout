// Pure helpers for the animation kit — kept import-free so they stay unit-testable (the animated
// components themselves pull in react-native-reanimated / react-native-svg, which jest can't load).

/** A displayed value split into render tokens: digit columns roll; everything else is static. */
export type DigitToken = { kind: 'digit'; d: number } | { kind: 'char'; ch: string };

/** "12.4" -> [1,2,'.',4]. Mirrors the Claude Design roll(): only 0-9 animate, the rest is static. */
export function splitDigits(value: string | number): DigitToken[] {
  const str = String(value);
  const out: DigitToken[] = [];
  for (const ch of str) {
    if (ch >= '0' && ch <= '9') out.push({ kind: 'digit', d: ch.charCodeAt(0) - 48 });
    else out.push({ kind: 'char', ch });
  }
  return out;
}

export type ConfettiPiece = {
  left: number; // % across the parent
  size: number; // px (width; height is 0.6×)
  color: string;
  dx: number; // horizontal drift, px
  rotate: number; // total rotation, deg
  delay: number; // start stagger, ms
  fall: number; // fall distance, px
};

/**
 * Deterministic when given a seeded rand() — so it's testable and so each mounted instance varies by
 * index without Math.random at module scope. `rand` must return [0, 1).
 */
export function confettiPieces(count: number, rand: () => number, colors: string[]): ConfettiPiece[] {
  const palette = colors.length ? colors : ['#2BD4C0'];
  const out: ConfettiPiece[] = [];
  for (let i = 0; i < Math.max(0, count); i++) {
    out.push({
      left: rand() * 100,
      size: 6 + rand() * 5,
      color: palette[Math.floor(rand() * palette.length)] ?? palette[0],
      dx: (rand() - 0.5) * 130,
      rotate: (rand() - 0.5) * 560,
      delay: rand() * 180,
      fall: 240 + rand() * 130,
    });
  }
  return out;
}

/** Clamp to [0,1]. */
export function clamp01(n: number): number {
  return n < 0 ? 0 : n > 1 ? 1 : n;
}
