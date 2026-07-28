// Reusable animation kit — the motion layer from the Claude Design mockup (Bambu.dc.html), ported to
// react-native-reanimated. Everything here is presentational; pure helpers live in ./animUtils.
//
// Components: Tap (press-scale), RollingNumber (rolling digits), PulseDot (breathing status dot),
// ProgressRing (animated SVG ring + glow), HeatBar (temp bar w/ heating shimmer), Skeleton (sweep),
// Confetti (celebration burst), FadeRise (mount entrance), Breathe (idle glow pulse).
import React, { useEffect, useMemo, useState } from 'react';
import { Pressable, Text, View, type StyleProp, type ViewStyle, type TextStyle, type LayoutChangeEvent } from 'react-native';
import Animated, {
  Easing,
  cancelAnimation,
  interpolateColor,
  useAnimatedProps,
  useAnimatedStyle,
  useSharedValue,
  withDelay,
  withRepeat,
  withSequence,
  withTiming,
} from 'react-native-reanimated';
import Svg, { Circle, Rect, Polygon } from 'react-native-svg';
import { c } from '@/theme';
import { splitDigits, confettiPieces, clamp01, type ConfettiPiece } from './animUtils';

// The design's signature springy ease (cubic-bezier(.34,1.56,.64,1)) and the digit-roll ease.
const SPRING = Easing.bezier(0.34, 1.56, 0.64, 1);
const ROLL_EASE = Easing.bezier(0.3, 1.1, 0.5, 1);
const RISE_EASE = Easing.bezier(0.22, 1, 0.36, 1);

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);
const AnimatedCircle = Animated.createAnimatedComponent(Circle);

// ---------------------------------------------------------------- Tap
// Drop-in for Pressable that scales to .955 + dims while held (design: .tap:active).
type TapProps = {
  onPress?: () => void;
  onLongPress?: () => void;
  children?: React.ReactNode;
  style?: StyleProp<ViewStyle>;
  disabled?: boolean;
  hitSlop?: number;
  scale?: number;
  dim?: number;
};
export function Tap({ onPress, onLongPress, children, style, disabled, hitSlop, scale = 0.955, dim = 0.62 }: TapProps) {
  const p = useSharedValue(0);
  // Cancel a mid-press animation on unmount — flushing updates for a view being torn down is the
  // reanimated-4 New-Arch crash/freeze race (swmansion/react-native-reanimated#9402).
  useEffect(() => () => cancelAnimation(p), [p]);
  const a = useAnimatedStyle(() => ({
    transform: [{ scale: 1 - (1 - scale) * p.value }],
    opacity: 1 - (1 - dim) * p.value,
  }));
  return (
    <AnimatedPressable
      disabled={disabled}
      hitSlop={hitSlop}
      onPress={onPress}
      onLongPress={onLongPress}
      onPressIn={() => {
        p.value = withTiming(1, { duration: 90, easing: Easing.out(Easing.quad) });
      }}
      onPressOut={() => {
        p.value = withTiming(0, { duration: 170, easing: SPRING });
      }}
      style={[style, a]}>
      {children}
    </AnimatedPressable>
  );
}

// ---------------------------------------------------------------- RollingNumber
function RollDigit({ d, h, fontSize, weight, color, letterSpacing }: { d: number; h: number; fontSize: number; weight: TextStyle['fontWeight']; color: string; letterSpacing: number }) {
  const ty = useSharedValue(-d * h);
  useEffect(() => {
    ty.value = withTiming(-d * h, { duration: 600, easing: ROLL_EASE });
    return () => cancelAnimation(ty);
  }, [d, h, ty]);
  const a = useAnimatedStyle(() => ({ transform: [{ translateY: ty.value }] }));
  return (
    <View style={{ height: h, overflow: 'hidden' }}>
      <Animated.View style={a}>
        {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((g) => (
          <Text key={g} style={{ height: h, lineHeight: h, fontSize, fontWeight: weight, color, letterSpacing, fontVariant: ['tabular-nums'], textAlign: 'center' }}>
            {g}
          </Text>
        ))}
      </Animated.View>
    </View>
  );
}

/** Animated numeric readout: each digit rolls vertically when the value changes. */
export function RollingNumber({ value, fontSize, weight = '700', color = c.t1, letterSpacing = 0, style }: { value: string | number; fontSize: number; weight?: TextStyle['fontWeight']; color?: string; letterSpacing?: number; style?: StyleProp<ViewStyle> }) {
  const tokens = splitDigits(value);
  const h = Math.round(fontSize * 1.08);
  return (
    <View style={[{ flexDirection: 'row', alignItems: 'flex-end' }, style]}>
      {tokens.map((t, i) =>
        t.kind === 'digit' ? (
          <RollDigit key={`d${i}`} d={t.d} h={h} fontSize={fontSize} weight={weight} color={color} letterSpacing={letterSpacing} />
        ) : (
          <Text key={`c${i}`} style={{ height: h, lineHeight: h, fontSize, fontWeight: weight, color, letterSpacing }}>
            {t.ch}
          </Text>
        ),
      )}
    </View>
  );
}

// ---------------------------------------------------------------- PulseDot
/** Status dot that breathes opacity 1 → .22 → 1 (design: @keyframes pulsedot). */
export function PulseDot({ color, size = 8, glow = true, period = 2400, style }: { color: string; size?: number; glow?: boolean; period?: number; style?: StyleProp<ViewStyle> }) {
  const o = useSharedValue(1);
  useEffect(() => {
    o.value = withRepeat(withSequence(withTiming(0.22, { duration: period / 2, easing: Easing.inOut(Easing.quad) }), withTiming(1, { duration: period / 2, easing: Easing.inOut(Easing.quad) })), -1, false);
    return () => cancelAnimation(o);
  }, [period, o]);
  const a = useAnimatedStyle(() => ({ opacity: o.value }));
  return (
    <Animated.View
      style={[
        { width: size, height: size, borderRadius: size / 2, backgroundColor: color },
        glow ? { shadowColor: color, shadowOpacity: 0.85, shadowRadius: size * 0.7, shadowOffset: { width: 0, height: 0 } } : null,
        a,
        style,
      ]}
    />
  );
}

// ---------------------------------------------------------------- ProgressRing
/** SVG progress ring with an eased stroke-dashoffset transition and an optional glow pulse. */
export function ProgressRing({ size = 128, stroke = 9, progress, color, track = c.s3, glow = false, children }: { size?: number; stroke?: number; progress: number; color: string; track?: string; glow?: boolean; children?: React.ReactNode }) {
  const r = (size - stroke) / 2;
  const circ = 2 * Math.PI * r;
  const target = circ * (1 - clamp01(progress / 100));
  const off = useSharedValue(target);
  useEffect(() => {
    off.value = withTiming(target, { duration: 700, easing: Easing.bezier(0.4, 0, 0.2, 1) });
    return () => cancelAnimation(off);
  }, [target, off]);
  const ringProps = useAnimatedProps(() => ({ strokeDashoffset: off.value }));

  const g = useSharedValue(0);
  useEffect(() => {
    if (glow) {
      g.value = withRepeat(withSequence(withTiming(1, { duration: 1200 }), withTiming(0, { duration: 1200 })), -1, false);
    } else {
      cancelAnimation(g);
      g.value = withTiming(0, { duration: 300 });
    }
    return () => cancelAnimation(g);
  }, [glow, g]);
  const glowStyle = useAnimatedStyle(() => ({ shadowOpacity: 0.6 * g.value }));

  return (
    <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
      <Animated.View style={[{ position: 'absolute', width: size * 0.7, height: size * 0.7, borderRadius: size, shadowColor: color, shadowRadius: 9, shadowOffset: { width: 0, height: 0 } }, glowStyle]} />
      <Svg width={size} height={size}>
        <Circle cx={size / 2} cy={size / 2} r={r} stroke={track} strokeWidth={stroke} fill="none" />
        <AnimatedCircle cx={size / 2} cy={size / 2} r={r} stroke={color} strokeWidth={stroke} fill="none" strokeLinecap="round" strokeDasharray={circ} animatedProps={ringProps} transform={`rotate(-90 ${size / 2} ${size / 2})`} />
      </Svg>
      <View style={{ position: 'absolute', alignItems: 'center', justifyContent: 'center' }}>{children}</View>
    </View>
  );
}

// ---------------------------------------------------------------- HeatBar
/** Thin progress bar; the fill shimmers (opacity) while `heating` (design: @keyframes heatshimmer). */
export function HeatBar({ pct, color, heating = false, height = 3, track = c.s3, style }: { pct: number; color: string; heating?: boolean; height?: number; track?: string; style?: StyleProp<ViewStyle> }) {
  const w = useSharedValue(clamp01(pct / 100));
  useEffect(() => {
    w.value = withTiming(clamp01(pct / 100), { duration: 600, easing: Easing.out(Easing.quad) });
    return () => cancelAnimation(w);
  }, [pct, w]);
  const o = useSharedValue(1);
  useEffect(() => {
    if (heating) {
      o.value = withRepeat(withSequence(withTiming(0.5, { duration: 700 }), withTiming(1, { duration: 700 })), -1, false);
    } else {
      cancelAnimation(o);
      o.value = withTiming(1, { duration: 250 });
    }
    return () => cancelAnimation(o);
  }, [heating, o]);
  const fill = useAnimatedStyle(() => ({ width: `${w.value * 100}%`, opacity: o.value }));
  return (
    <View style={[{ height, borderRadius: height / 2, backgroundColor: track, overflow: 'hidden' }, style]}>
      <Animated.View style={[{ height: '100%', borderRadius: height / 2, backgroundColor: color }, fill]} />
    </View>
  );
}

// ---------------------------------------------------------------- Skeleton
/** Loading placeholder with a sweeping highlight (design: .skel). No gradient dep — a soft bar pans. */
export function Skeleton({ style }: { style?: StyleProp<ViewStyle> }) {
  const [w, setW] = useState(0);
  const x = useSharedValue(-160);
  useEffect(() => {
    if (!w) return;
    x.value = -160;
    x.value = withRepeat(withTiming(w, { duration: 1400, easing: Easing.inOut(Easing.ease) }), -1, false);
    return () => cancelAnimation(x);
  }, [w, x]);
  const a = useAnimatedStyle(() => ({ transform: [{ translateX: x.value }] }));
  const onLayout = (e: LayoutChangeEvent) => setW(e.nativeEvent.layout.width);
  return (
    <View onLayout={onLayout} style={[{ overflow: 'hidden', backgroundColor: c.s2 }, style]}>
      <Animated.View style={[{ position: 'absolute', top: 0, bottom: 0, width: 150, backgroundColor: 'rgba(255,255,255,0.06)' }, a]} />
    </View>
  );
}

// ---------------------------------------------------------------- Confetti
function Piece({ p }: { p: ConfettiPiece }) {
  const t = useSharedValue(0);
  useEffect(() => {
    t.value = withDelay(p.delay, withTiming(1, { duration: 1100 + p.fall, easing: Easing.bezier(0.2, 0.6, 0.4, 1) }));
    return () => cancelAnimation(t);
  }, [t, p]);
  const a = useAnimatedStyle(() => ({
    opacity: t.value < 0.12 ? t.value / 0.12 : 1 - (t.value - 0.12) / 0.88,
    transform: [{ translateX: p.dx * t.value }, { translateY: -14 + (p.fall + 14) * t.value }, { rotate: `${p.rotate * t.value}deg` }],
  }));
  return <Animated.View style={[{ position: 'absolute', top: 0, left: `${p.left}%`, width: p.size, height: p.size * 0.62, borderRadius: 2, backgroundColor: p.color }, a]} />;
}

/** A one-shot celebration burst that falls + fades (design: @keyframes confettiFall). */
export function Confetti({ count = 18, colors }: { count?: number; colors?: string[] }) {
  const palette = colors ?? [c.accent, c.running, c.heating, c.paused, c.t1];
  const pieces = useMemo(() => confettiPieces(count, Math.random, palette), [count]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <View pointerEvents="none" style={{ position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, overflow: 'hidden' }}>
      {pieces.map((p, i) => (
        <Piece key={i} p={p} />
      ))}
    </View>
  );
}

// ---------------------------------------------------------------- FadeRise
/** Mount entrance: fade + rise (design: @keyframes riseIn / screenIn). Stagger via `delay`. */
export function FadeRise({ children, delay = 0, dy = 11, duration = 340, style }: { children?: React.ReactNode; delay?: number; dy?: number; duration?: number; style?: StyleProp<ViewStyle> }) {
  const t = useSharedValue(0);
  useEffect(() => {
    t.value = withDelay(delay, withTiming(1, { duration, easing: RISE_EASE }));
    return () => cancelAnimation(t);
  }, [t, delay, duration]);
  const a = useAnimatedStyle(() => ({ opacity: t.value, transform: [{ translateY: (1 - t.value) * dy }] }));
  return <Animated.View style={[style, a]}>{children}</Animated.View>;
}

// ---------------------------------------------------------------- Toggle
/** iOS-style switch with an animated knob + track color (design: the auto-off toggle). */
export function Toggle({ value, onChange, onColor = c.accent, offColor = c.s3, disabled = false }: { value: boolean; onChange: (v: boolean) => void; onColor?: string; offColor?: string; disabled?: boolean }) {
  const p = useSharedValue(value ? 1 : 0);
  useEffect(() => {
    p.value = withTiming(value ? 1 : 0, { duration: 240, easing: SPRING });
    return () => cancelAnimation(p);
  }, [value, p]);
  const track = useAnimatedStyle(() => ({ backgroundColor: interpolateColor(p.value, [0, 1], [offColor, onColor]) }));
  const knob = useAnimatedStyle(() => ({ transform: [{ translateX: 3 + p.value * 21 }] }));
  return (
    <Tap onPress={() => onChange(!value)} disabled={disabled} scale={0.92} style={{ width: 48, height: 30, opacity: disabled ? 0.4 : 1 }}>
      <Animated.View style={[{ width: 48, height: 30, borderRadius: 15, justifyContent: 'center' }, track]}>
        <Animated.View style={[{ width: 24, height: 24, borderRadius: 12, backgroundColor: '#fff' }, knob]} />
      </Animated.View>
    </Tap>
  );
}

// ---------------------------------------------------------------- Pop
/** Scale-bounce entrance: 0.4 → 1.12 → 1 (design: @keyframes popIn). */
export function Pop({ children, delay = 0, style }: { children?: React.ReactNode; delay?: number; style?: StyleProp<ViewStyle> }) {
  const s = useSharedValue(0.4);
  const o = useSharedValue(0);
  useEffect(() => {
    o.value = withDelay(delay, withTiming(1, { duration: 200, easing: Easing.out(Easing.quad) }));
    s.value = withDelay(delay, withSequence(withTiming(1.12, { duration: 320, easing: Easing.out(Easing.cubic) }), withTiming(1, { duration: 220, easing: SPRING })));
    return () => {
      cancelAnimation(o);
      cancelAnimation(s);
    };
  }, [delay, s, o]);
  const a = useAnimatedStyle(() => ({ opacity: o.value, transform: [{ scale: s.value }] }));
  return <Animated.View style={[style, a]}>{children}</Animated.View>;
}

// ---------------------------------------------------------------- Spark
function SparkParticle({ i, count, color, size, spread }: { i: number; count: number; color: string; size: number; spread: number }) {
  const t = useSharedValue(0);
  useEffect(() => {
    t.value = withDelay((i / count) * 1200, withRepeat(withTiming(1, { duration: 1300, easing: Easing.out(Easing.cubic) }), -1, false));
    return () => cancelAnimation(t);
  }, [t, i, count]);
  const ang = (i / count) * Math.PI * 2;
  const dx = Math.cos(ang) * spread;
  const dy = Math.sin(ang) * spread - 8; // bias slightly upward
  const a = useAnimatedStyle(() => ({
    opacity: t.value < 0.18 ? t.value / 0.18 : 1 - (t.value - 0.18) / 0.82,
    transform: [{ translateX: dx * t.value }, { translateY: dy * t.value }, { scale: 1 - 0.8 * t.value }],
  }));
  return <Animated.View style={[{ position: 'absolute', width: size, height: size, borderRadius: size / 2, backgroundColor: color }, a]} />;
}

/** A small cluster of particles drifting outward on a loop (design: @keyframes spark). Absolutely
 * positioned — drop it inside a relative parent at the emit point. */
export function Spark({ color = c.accent, count = 6, size = 4, spread = 20 }: { color?: string; count?: number; size?: number; spread?: number }) {
  return (
    <View pointerEvents="none" style={{ position: 'absolute', width: 0, height: 0 }}>
      {Array.from({ length: count }).map((_, i) => (
        <SparkParticle key={i} i={i} count={count} color={color} size={size} spread={spread} />
      ))}
    </View>
  );
}

// ---------------------------------------------------------------- ExtrudeBar
/** Progress bar with a nozzle glyph riding the leading edge + a glowing fill (design: extrudeBar). */
export function ExtrudeBar({ pct, color = c.accent, height = 8, track = c.s3 }: { pct: number; color?: string; height?: number; track?: string }) {
  const w = useSharedValue(clamp01(pct / 100));
  // Track width lives in a shared value (set from onLayout) so the nozzle can ride the edge via a
  // TRANSFORM — animating `left`/layout props commits a ShadowTree transaction per frame, which
  // both costs more and widens the New-Arch teardown race window.
  const trackW = useSharedValue(0);
  useEffect(() => {
    w.value = withTiming(clamp01(pct / 100), { duration: 700, easing: Easing.bezier(0.4, 0, 0.2, 1) });
    return () => cancelAnimation(w);
  }, [pct, w]);
  const fill = useAnimatedStyle(() => ({ width: `${w.value * 100}%` }));
  const noz = useAnimatedStyle(() => ({ transform: [{ translateX: w.value * trackW.value - 12 }] }));
  return (
    <View style={{ height: height + 30, paddingTop: 30 }}>
      <View onLayout={(e: LayoutChangeEvent) => { trackW.value = e.nativeEvent.layout.width; }} style={{ height, borderRadius: height / 2, backgroundColor: track }}>
        <Animated.View style={[{ position: 'absolute', left: 0, top: 0, bottom: 0, borderRadius: height / 2, backgroundColor: color, shadowColor: color, shadowOpacity: 0.85, shadowRadius: 6, shadowOffset: { width: 0, height: 0 } }, fill]} />
      </View>
      <Animated.View style={[{ position: 'absolute', top: 0, left: 0 }, noz]}>
        <Svg width={24} height={32} viewBox="48 30 96 128">
          <Rect x={60} y={36} width={72} height={50} rx={12} fill="#C2C7CC" />
          <Rect x={60} y={80} width={72} height={9} rx={4.5} fill="#878D94" />
          <Polygon points="74,92 118,92 106,128 96,150 86,128" fill="#C2C7CC" />
          <Circle cx={96} cy={117} r={11} fill={color} />
        </Svg>
      </Animated.View>
    </View>
  );
}

// ---------------------------------------------------------------- Breathe
/**
 * Wraps children in a pulsing colored HALO while `active` (design: powerBreathe / bulbPulse). Uses a
 * real sibling view (opacity + scale) rather than an iOS shadow — a shadow on a transparent wrapper
 * doesn't render, so the old version was invisible. `grow` controls how far the halo extends.
 */
export function Breathe({ active, color, children, grow = 0.22, maxOpacity = 0.45, style }: { active: boolean; color: string; children?: React.ReactNode; grow?: number; maxOpacity?: number; style?: StyleProp<ViewStyle> }) {
  const g = useSharedValue(0);
  useEffect(() => {
    if (active) {
      g.value = withRepeat(withSequence(withTiming(1, { duration: 1200, easing: Easing.inOut(Easing.quad) }), withTiming(0, { duration: 1200, easing: Easing.inOut(Easing.quad) })), -1, false);
    } else {
      cancelAnimation(g);
      g.value = withTiming(0, { duration: 300 });
    }
    return () => cancelAnimation(g);
  }, [active, g]);
  const halo = useAnimatedStyle(() => ({ opacity: maxOpacity * g.value, transform: [{ scale: 1 + grow * g.value }] }));
  return (
    <View style={[{ alignItems: 'center', justifyContent: 'center' }, style]}>
      <Animated.View pointerEvents="none" style={[{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0, borderRadius: 999, backgroundColor: color }, halo]} />
      {children}
    </View>
  );
}
