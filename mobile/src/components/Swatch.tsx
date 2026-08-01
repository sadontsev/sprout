import React from 'react';
import { View } from 'react-native';
import { Feather } from '@expo/vector-icons';
import { c } from '@/theme';

/**
 * A filament colour swatch that stays visible whatever the colour is.
 *
 * Every site used to paint the raw hex straight into `backgroundColor`, and most dropped the border
 * as soon as a colour was present. So a white spool on a white card was a hole in the layout — the
 * reported bug — and a black spool on a dark card was the same bug in the other theme. The sites
 * that DID keep a hairline were no better: `c.line2` is ~1.4:1 against its own surface.
 *
 * The ring exists to separate the swatch from the CARD, so it is a fixed per-theme colour chosen for
 * contrast against the surfaces (>= 3:1 on every one), not something computed from the fill. That is
 * a proof rather than a sampled result: it holds for colours nobody has tested.
 *
 * Three distinct states, deliberately not collapsed into two:
 *   empty   — no spool in the slot:        transparent fill, DASHED ring
 *   unknown — a spool whose colour we do not know: dashed ring + a "?" glyph, never black
 *   colour  — the fill, with a solid ring
 */
export function Swatch({
  value,
  size,
  radius,
  empty = false,
  ink,
  style,
}: {
  /** #RRGGBB, or null when the colour is unknown. Pass through normColor() first. */
  value?: string | null;
  size: number;
  radius: number;
  /** True when the slot holds nothing at all — distinct from "colour unknown". */
  empty?: boolean;
  /** Optional glyph drawn on top of the fill (the nozzle chip's chevron). */
  ink?: React.ReactNode;
  style?: object;
}) {
  const known = !empty && !!value;
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: radius,
        backgroundColor: known ? (value as string) : 'transparent',
        borderWidth: 1,
        borderColor: c.swatchRing,
        // Dashed reads as "nothing here" for both empty and unknown; solid means "this is the colour".
        borderStyle: known ? 'solid' : 'dashed',
        alignItems: 'center',
        justifyContent: 'center',
        ...style,
      }}>
      {known ? ink : !empty && size >= 16 ? <Feather name="help-circle" size={Math.round(size * 0.5)} color={c.t3} /> : null}
    </View>
  );
}
