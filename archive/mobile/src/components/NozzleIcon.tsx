import React from 'react';
import Svg, { Rect, Polygon, Circle } from 'react-native-svg';

/**
 * Monochrome brand nozzle glyph (the app-icon mark, single-colour) for the Printer tab.
 * Tints with `color` so it matches the other tab icons (accent when active, muted when not).
 * Same proportions as the Live Activity glyph (src/liveactivity/nozzle-glyph.svg).
 */
export function NozzleIcon({ color, size = 24 }: { color: string; size?: number }) {
  return (
    <Svg width={size} height={size} viewBox="48 30 96 142" fill="none">
      <Rect x="60" y="36" width="72" height="50" rx="12" fill={color} />
      <Rect x="60" y="80" width="72" height="9" rx="4.5" fill={color} />
      <Polygon points="74,92 118,92 106,128 96,150 86,128" fill={color} />
      <Circle cx="96" cy="120" r="11" fill={color} />
      <Rect x="58" y="150" width="76" height="15" rx="7.5" fill={color} />
    </Svg>
  );
}
