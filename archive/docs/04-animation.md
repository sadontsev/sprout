<!-- Generated as the port specification for the native Swift rewrite. -->
# Motion primitives — durations, easings, springs

## anim

`src/components/anim/index.tsx` (376 lines) + `src/components/anim/animUtils.ts` (53 lines, pure/testable) + `src/components/anim/__tests__/animUtils.test.ts`.

This is the **entire motion layer** of the app, ported by hand from the Claude Design mockup `docs/design/Bambu.dc.html` (CSS keyframes → `react-native-reanimated` v4). File header comment:

> Reusable animation kit — the motion layer from the Claude Design mockup (Bambu.dc.html), ported to react-native-reanimated. Everything here is presentational; pure helpers live in ./animUtils.

13 exported components: `Tap`, `RollingNumber`, `PulseDot`, `ProgressRing`, `HeatBar`, `Skeleton`, `Confetti`, `FadeRise`, `Toggle`, `Pop`, `Spark`, `ExtrudeBar`, `Breathe` (+ 3 private sub-components `RollDigit`, `Piece`, `SparkParticle`).

Imports: `Animated, { Easing, cancelAnimation, interpolateColor, useAnimatedProps, useAnimatedStyle, useSharedValue, withDelay, withRepeat, withSequence, withTiming }` from `react-native-reanimated`; `Svg, { Circle, Rect, Polygon }` from `react-native-svg`; `c` from `@/theme`; `splitDigits, confettiPieces, clamp01, type ConfettiPiece` from `./animUtils`.

Two animated wrappers are created at module scope (must be, not inside render):
```ts
const AnimatedPressable = Animated.createAnimatedComponent(Pressable);
const AnimatedCircle    = Animated.createAnimatedComponent(Circle);
```

---

### The three shared easing curves (module constants)

```ts
// The design's signature springy ease (cubic-bezier(.34,1.56,.64,1)) and the digit-roll ease.
const SPRING    = Easing.bezier(0.34, 1.56, 0.64, 1);
const ROLL_EASE = Easing.bezier(0.3,  1.1,  0.5,  1);
const RISE_EASE = Easing.bezier(0.22, 1,    0.36, 1);
```

Measured behaviour of every curve used in the file (computed numerically — these matter because two of them **overshoot past 1.0**):

| Name | Control points | Peak value | Peak at t | y(0.1) / y(0.25) / y(0.5) / y(0.75) / y(0.9) |
|---|---|---|---|---|
| `SPRING` | `.34, 1.56, .64, 1` | **1.0978** | t=0.573 | 0.4039 / 0.8163 / 1.0874 / 1.0596 / 1.0126 |
| `ROLL_EASE` | `.3, 1.1, .5, 1` | **1.0024** | t=0.789 | 0.3334 / 0.6942 / 0.9570 / 1.0020 / 1.0010 |
| `RISE_EASE` | `.22, 1, .36, 1` | 1.0 (monotone) | t=1 | 0.4011 / 0.7649 / 0.9614 / 0.9969 / 0.9998 |
| Material std (`ProgressRing`, `ExtrudeBar`) | `.4, 0, .2, 1` | 1.0 | t=1 | 0.0259 / 0.2366 / 0.7756 / 0.9594 / 0.9944 |
| Confetti fall | `.2, .6, .4, 1` | 1.0 | t=1 | 0.2778 / 0.5865 / 0.8617 / 0.9723 / 0.9960 |

Non-bezier easings used, with exact math (Reanimated definitions, verified in `node_modules/react-native-reanimated/src/Easing.ts`):
- `Easing.quad`  = `t*t`
- `Easing.cubic` = `t*t*t`
- `Easing.ease`  = `Bezier(0.42, 0, 1, 1)` (NOT CSS `ease` — it is CSS `ease-in`)
- `Easing.out(f)(t)` = `1 - f(1 - t)` → **out-quad** = `1-(1-t)²`, **out-cubic** = `1-(1-t)³`
- `Easing.inOut(f)(t)` = `t < 0.5 ? f(2t)/2 : 1 - f(2(1-t))/2` → **inOut-quad** = `t<.5 ? 2t² : 1-2(1-t)²`

**Implicit Reanimated defaults** (several call sites pass a duration but no easing, and one passes nothing): `withTiming` defaults are `{ duration: 300, easing: Easing.inOut(Easing.quad) }` (`src/animation/timing.ts:88-89`). Sites relying on the default easing: `ProgressRing` glow loop (1200/1200), `HeatBar` shimmer loop (700/700), and every "settle to rest" off-transition.

**Every repeating animation in this file uses `withRepeat(withSequence(down, up), -1, false)`** — i.e. infinite, `reverse = false`. The sequence itself contains both legs and returns to its starting value, so the loop is seamless; `false` means each iteration restarts from the value captured when the repeat began.

---

### Universal gotcha: `cancelAnimation` on unmount (do not drop this)

**Every single component** returns a cleanup that calls `cancelAnimation(sharedValue)`. The `Tap` comment states why:

```ts
// Cancel a mid-press animation on unmount — flushing updates for a view being torn down is the
// reanimated-4 New-Arch crash/freeze race (swmansion/react-native-reanimated#9402).
useEffect(() => () => cancelAnimation(p), [p]);
```

This is a **real crash/freeze fix**, not hygiene. In the Swift port the equivalent hazard mostly evaporates, but any hand-rolled `CADisplayLink`/`Timer`-driven animation must still be invalidated in `onDisappear`/`deinit`.

---

### `Tap` — press feedback (the most-used primitive in the app)

Drop-in `Pressable` replacement. Comment: *"scales to .955 + dims while held (design: `.tap:active`)"*.

Props: `onPress?`, `onLongPress?`, `children?`, `style?: StyleProp<ViewStyle>`, `disabled?: boolean`, `hitSlop?: number`, **`scale = 0.955`**, **`dim = 0.62`**.

State: one shared value `p` ∈ [0,1] (0 = released, 1 = held).

```ts
const a = useAnimatedStyle(() => ({
  transform: [{ scale: 1 - (1 - scale) * p.value }],
  opacity:   1 - (1 - dim)   * p.value,
}));
onPressIn:  p.value = withTiming(1, { duration: 90,  easing: Easing.out(Easing.quad) });
onPressOut: p.value = withTiming(0, { duration: 170, easing: SPRING });
```

Exact numbers:
- **Press in: 90 ms, out-quad.** End state scale **0.955**, opacity **0.62**.
- **Press out: 170 ms, SPRING (`.34,1.56,.64,1`).**
- Because `SPRING` peaks at **1.0978**, `p` goes to **−0.0978** during release → **scale overshoots to ≈1.0044** (0.44 % larger than rest) and opacity computes to **1.0372** (clamped to 1 by the platform). That tiny scale bounce on release **is** the signature feel — reproduce it.
- Long-press uses RN `Pressable` defaults (**500 ms** delay).
- `hitSlop` is a plain number (uniform inset). Values used across the app: `6`, `8`, `10`, `12`.
- `style` is applied **before** the animated style: `style={[style, a]}`.
- The only non-default `scale` in the whole codebase is `0.92`, used by `Toggle` internally. Nothing overrides `dim`.

Consumers: `TabBar.tsx`, `DashboardView.tsx`, `TabScreens.tsx`, `Overlays.tsx`, `AlertsOverlay.tsx`, `settings.tsx`.

---

### `RollingNumber` + `RollDigit` — rolling odometer digits

`/** Animated numeric readout: each digit rolls vertically when the value changes. */`

**`RollingNumber` props:** `value: string | number`, `fontSize: number` (required), `weight = '700'`, `color = c.t1`, `letterSpacing = 0`, `style?`.

Layout algorithm:
```ts
const tokens = splitDigits(value);          // see animUtils below
const h = Math.round(fontSize * 1.08);      // digit-column height, ROUNDED
// container: { flexDirection: 'row', alignItems: 'flex-end' }  (+ caller style)
// digit token  -> <RollDigit d h fontSize weight color letterSpacing/>  key={`d${i}`}
// char  token  -> <Text style={{ height: h, lineHeight: h, fontSize, fontWeight: weight,
//                               color, letterSpacing }}>{ch}</Text>      key={`c${i}`}
```

**`RollDigit`** — the strip:
```ts
const ty = useSharedValue(-d * h);                       // initialised AT target: no mount animation
useEffect(() => {
  ty.value = withTiming(-d * h, { duration: 600, easing: ROLL_EASE });
  return () => cancelAnimation(ty);
}, [d, h, ty]);
// outer:  <View style={{ height: h, overflow: 'hidden' }}>
// strip:  <Animated.View style={{ transform: [{ translateY: ty.value }] }}>
//           0..9, each a <Text> with:
//           { height: h, lineHeight: h, fontSize, fontWeight: weight, color, letterSpacing,
//             fontVariant: ['tabular-nums'], textAlign: 'center' }
```

Exact numbers:
- **Roll duration 600 ms, `ROLL_EASE` = cubic-bezier(0.3, 1.1, 0.5, 1)** → a 0.24 % overshoot past the target row before settling.
- Column height `h = round(fontSize * 1.08)`; strip is 10 rows tall (`10h`); `translateY = -d*h`.
- `fontVariant: ['tabular-nums']` + `textAlign:'center'` on digits; the **separator `<Text>` does NOT get tabular-nums**.
- On first mount the shared value already equals the target, so nothing animates in — only *changes* roll.
- Column width is intrinsic (no explicit width) — the wrapper sizes to the widest of 0–9, which tabular-nums makes uniform.

**Gotcha (index-keyed tokens):** children are keyed `d${i}`/`c${i}` by **position**. When the string length changes (e.g. `"9"` → `"10"`, or `"9m"` → `"10m"`), the digit at index 0 rolls 9→1 and a *new* column appears at index 1, rather than the number shifting sideways. Reproduce this literally or the motion will differ.

Real call sites (fontSize / weight / letterSpacing): `46/700/−1` (slice %, wizard), `46/700/−2` (history total), `32/700/−1` (dashboard progress %), `28/700/−1` (watts, kWh), `26/700/−0.5` (temperature readout), `25/700/−1` (stat tile), `20/700/−0.5` (small ring center), `19/600/0` (layer, ETA text).

---

### `PulseDot` — breathing status dot

`/** Status dot that breathes opacity 1 → .22 → 1 (design: @keyframes pulsedot). */`

Props: `color: string` (required), **`size = 8`**, **`glow = true`**, **`period = 2400`** (ms), `style?`.

```ts
o.value = withRepeat(
  withSequence(
    withTiming(0.22, { duration: period / 2, easing: Easing.inOut(Easing.quad) }),
    withTiming(1,    { duration: period / 2, easing: Easing.inOut(Easing.quad) }),
  ), -1, false);
```
View style, in order:
```ts
{ width: size, height: size, borderRadius: size / 2, backgroundColor: color }
glow ? { shadowColor: color, shadowOpacity: 0.85, shadowRadius: size * 0.7,
         shadowOffset: { width: 0, height: 0 } } : null
{ opacity: o.value }          // animated
style                          // caller override LAST
```

Exact numbers: opacity floor **0.22**, each half **`period/2`** (default **1200 ms** each), **inOut-quad**, infinite, no autoreverse. Glow shadow opacity **0.85**, blur radius **`size * 0.7`**, zero offset, shadow colour = dot colour. The view's animated `opacity` multiplies the shadow too, so the glow breathes with the dot.

Periods actually used: **1400** (heating indicator, `DashboardView.tsx:60`), **2000** (camera live, plug reachable, running chips), **2400** (default; plug on/off dot, history). Sizes used: 5, 6, 7, 8, 9.

---

### `ProgressRing` — SVG ring + optional glow pulse

`/** SVG progress ring with an eased stroke-dashoffset transition and an optional glow pulse. */`

Props: **`size = 128`**, **`stroke = 9`**, `progress: number` (0–100), `color: string`, **`track = c.s3`**, **`glow = false`**, `children?`.

Geometry + progress animation:
```ts
const r      = (size - stroke) / 2;
const circ   = 2 * Math.PI * r;
const target = circ * (1 - clamp01(progress / 100));
const off    = useSharedValue(target);            // again: starts AT target, no sweep-in on mount
useEffect(() => {
  off.value = withTiming(target, { duration: 700, easing: Easing.bezier(0.4, 0, 0.2, 1) });
  return () => cancelAnimation(off);
}, [target, off]);
const ringProps = useAnimatedProps(() => ({ strokeDashoffset: off.value }));
```

Glow pulse (a **separate, independent** shared value):
```ts
if (glow) g.value = withRepeat(withSequence(withTiming(1, { duration: 1200 }),
                                            withTiming(0, { duration: 1200 })), -1, false);
else    { cancelAnimation(g); g.value = withTiming(0, { duration: 300 }); }
const glowStyle = useAnimatedStyle(() => ({ shadowOpacity: 0.6 * g.value }));
```
(no easing given → **default inOut-quad**, both for the 1200 ms legs and the 300 ms release.)

Render tree:
```
View  { width: size, height: size, alignItems:'center', justifyContent:'center' }
  Animated.View (glow)  { position:'absolute', width: size*0.7, height: size*0.7,
                          borderRadius: size, shadowColor: color, shadowRadius: 9,
                          shadowOffset:{0,0} }  + animated shadowOpacity 0..0.6
  Svg width=size height=size
    Circle          cx=size/2 cy=size/2 r=r stroke=track  strokeWidth=stroke fill="none"
    AnimatedCircle  cx=size/2 cy=size/2 r=r stroke=color  strokeWidth=stroke fill="none"
                    strokeLinecap="round" strokeDasharray={circ}
                    animatedProps={{strokeDashoffset}}
                    transform={`rotate(-90 ${size/2} ${size/2})`}
    View { position:'absolute', alignItems:'center', justifyContent:'center' } → children
```

Exact numbers: progress transition **700 ms, cubic-bezier(0.4, 0, 0.2, 1)** (Material standard). Ring starts at **12 o'clock** (`rotate(-90)`), sweeps **clockwise**, **round** cap. Glow: max shadow opacity **0.6**, blur **9**, halo box **0.7 × size** square with `borderRadius: size` (a circle), 1200 ms up / 1200 ms down.

Instantiated sizes: default `128/9` → r = 59.5, circ ≈ **373.85** (`DashboardView.tsx:285`, `glow={!vm.isPaused}`); `size=76 stroke=7` → r = 34.5, circ ≈ **216.77** (`TabScreens.tsx:1560`, no glow).

---

### `HeatBar` — thin temperature/progress bar with heating shimmer

`/** Thin progress bar; the fill shimmers (opacity) while `heating` (design: @keyframes heatshimmer). */`

Props: `pct: number` (0–100), `color: string`, **`heating = false`**, **`height = 3`**, **`track = c.s3`**, `style?`.

```ts
const w = useSharedValue(clamp01(pct / 100));           // starts at value: no fill-in on mount
useEffect(() => {
  w.value = withTiming(clamp01(pct / 100), { duration: 600, easing: Easing.out(Easing.quad) });
  return () => cancelAnimation(w);
}, [pct, w]);

const o = useSharedValue(1);
useEffect(() => {
  if (heating) o.value = withRepeat(withSequence(withTiming(0.5, { duration: 700 }),
                                                 withTiming(1,   { duration: 700 })), -1, false);
  else { cancelAnimation(o); o.value = withTiming(1, { duration: 250 }); }
  return () => cancelAnimation(o);
}, [heating, o]);

const fill = useAnimatedStyle(() => ({ width: `${w.value * 100}%`, opacity: o.value }));
// track: { height, borderRadius: height/2, backgroundColor: track, overflow: 'hidden' } + style
// fill : { height: '100%', borderRadius: height/2, backgroundColor: color } + fill
```

Exact numbers: width **600 ms out-quad**; shimmer **opacity 1 → 0.5 → 1**, **700 ms per leg** (default inOut-quad), infinite; heating→idle settles to opacity 1 over **250 ms**.

**State machine (2 states):** `idle` (opacity pinned 1) ⇄ `heating` (looping 1↔0.5). Transition `heating→idle` **cancels first, then eases to 1 over 250 ms** — it does not wait for the loop to finish. Transition `idle→heating` starts the loop immediately from opacity 1.

Note the fill animates a **percentage width** (a layout prop) — inconsistent with the `ExtrudeBar` comment below, but it is what ships.

Call sites: `height={3}` (dashboard temp rows, with `heating`), `height={5}` + `width:'78%'` (slice progress in the wizard, no heating).

---

### `Skeleton` — loading placeholder with sweeping highlight

`/** Loading placeholder with a sweeping highlight (design: .skel). No gradient dep — a soft bar pans. */`

Props: `style?` only.

```ts
const [w, setW] = useState(0);                 // measured via onLayout
const x = useSharedValue(-160);
useEffect(() => {
  if (!w) return;                              // gate: nothing runs until laid out
  x.value = -160;
  x.value = withRepeat(withTiming(w, { duration: 1400, easing: Easing.inOut(Easing.ease) }), -1, false);
  return () => cancelAnimation(x);
}, [w, x]);
// container: { overflow:'hidden', backgroundColor: c.s2 } + style
// highlight: { position:'absolute', top:0, bottom:0, width:150,
//              backgroundColor:'rgba(255,255,255,0.06)' } + translateX
```

Exact numbers: highlight bar is **150 pt wide**, travels **from x = −160 to x = measuredWidth**, **1400 ms**, `Easing.inOut(Easing.ease)` (= inOut of bezier(0.42,0,1,1)), looping forever with no reverse (snaps back to −160 each cycle, off-screen so invisible). Highlight colour is a hardcoded **`rgba(255,255,255,0.06)`**; base is `c.s2`.

**Gotcha:** the highlight is white-on-dark only — in light theme (`c.s2` = `#F5F6F8`) a 6 % white sweep is effectively invisible. Dark-first design decision worth revisiting in the port.

Call sites (`DashboardView.tsx:501-507`, the dashboard loading state): `{width:'100%', aspectRatio: 16/10, borderRadius: 18}`, `{width:110, height:110, borderRadius:55}`, `{height:13, width:'55%', borderRadius:5}`, `{height:22, width:'85%', borderRadius:6}`, `{height:13, width:'42%', borderRadius:5}`.

---

### `Confetti` + `Piece` — one-shot celebration burst

`/** A one-shot celebration burst that falls + fades (design: @keyframes confettiFall). */`

Props: **`count = 18`**, `colors?: string[]`.

```ts
const palette = colors ?? [c.accent, c.running, c.heating, c.paused, c.t1];
const pieces  = useMemo(() => confettiPieces(count, Math.random, palette), [count]); // eslint-disable-line
// container: pointerEvents="none", { position:'absolute', top:0,left:0,right:0,bottom:0, overflow:'hidden' }
```
Default palette in **dark**: `#2BD4C0`, `#30D158`, `#FF9F0A`, `#0A84FF`, `#F3F5F7`. In **light**: `#0EAE9C`, `#23B24A`, `#E0860A`, `#0A84FF`, `#0D1012`.

**Gotcha:** `useMemo` deps are **`[count]` only** (with an explicit eslint-disable). Changing the palette (e.g. a theme switch) does **not** regenerate the pieces. Deliberate — regenerating mid-flight would restart the burst.

Per-piece animation:
```ts
t.value = withDelay(p.delay,
  withTiming(1, { duration: 1100 + p.fall, easing: Easing.bezier(0.2, 0.6, 0.4, 1) }));

opacity: t < 0.12 ? t / 0.12 : 1 - (t - 0.12) / 0.88,       // 12% fade-in, 88% linear fade-out to 0
transform: [
  { translateX: p.dx * t },
  { translateY: -14 + (p.fall + 14) * t },                   // starts 14pt ABOVE the top edge
  { rotate: `${p.rotate * t}deg` },
],
// style: { position:'absolute', top:0, left:`${p.left}%`, width:p.size,
//          height:p.size*0.62, borderRadius:2, backgroundColor:p.color }
```

Exact numbers per piece (`p.fall ∈ [240, 370)`): duration = **1100 + fall** → **1340–1470 ms**; delay **0–180 ms**; horizontal drift **±65 pt**; total rotation **±280°**; width **6–11 pt**, height **0.62 × width** (3.72–6.82 pt); corner radius **2**. Fires **once** — pieces end at opacity 0 and stay mounted.

Only call site: `<Confetti count={22} />` in the print-complete state (`DashboardView.tsx:418`).

---

### `FadeRise` — mount entrance (fade + rise)

`/** Mount entrance: fade + rise (design: @keyframes riseIn / screenIn). Stagger via `delay`. */`

Props: **`delay = 0`**, **`dy = 11`**, **`duration = 340`**, `children?`, `style?`.

```ts
t.value = withDelay(delay, withTiming(1, { duration, easing: RISE_EASE }));
// deps: [t, delay, duration]  — NOTE: dy is not a dep (read live in the worklet)
const a = useAnimatedStyle(() => ({ opacity: t.value, transform: [{ translateY: (1 - t.value) * dy }] }));
// <Animated.View style={[style, a]}>
```

Exact numbers: opacity **0 → 1**, translateY **`dy` → 0**, over **`duration` ms** with **`RISE_EASE` = cubic-bezier(0.22, 1, 0.36, 1)** (ease-out-quint-ish: 76 % of the distance covered in the first 25 % of the time).

Runs **once per mount**; replay is achieved by changing React's `key`. Real call sites:
- `src/app/index.tsx:424` — `<FadeRise key={tab} dy={8} duration={300} style={{flex:1}}>` — **the tab-change screen transition** (keyed on the active tab).
- `Overlays.tsx:1178` — `<FadeRise key={step} dy={10} duration={300}>` — the print-wizard step transition.
- `DashboardView.tsx:195` — `dy={-6} duration={180}` — **negative dy**, so it drops *down* into place (a popover under a header).
- `DashboardView.tsx:336` — `dy={6} duration={170}` inside an absolutely-positioned overlay (`{position:'absolute', left:-6, right:-6, bottom:62, zIndex:30}`).
- Bare `<FadeRise>` (defaults 0 / 11 / 340) in `DashboardView.tsx` (221, 240, 389, 419, 451, 480), `TabScreens.tsx:1579`, `AlertsOverlay.tsx:50` (`key={a.id}` — per-alert entrance).

---

### `Toggle` — custom iOS-style switch

`/** iOS-style switch with an animated knob + track color (design: the auto-off toggle). */`

Props: `value: boolean`, `onChange: (v:boolean)=>void`, **`onColor = c.accent`**, **`offColor = c.s3`**, **`disabled = false`**.

```ts
p.value = withTiming(value ? 1 : 0, { duration: 240, easing: SPRING });
const track = useAnimatedStyle(() => ({ backgroundColor: interpolateColor(p.value, [0,1], [offColor, onColor]) }));
const knob  = useAnimatedStyle(() => ({ transform: [{ translateX: 3 + p.value * 21 }] }));

<Tap onPress={() => onChange(!value)} disabled={disabled} scale={0.92}
     style={{ width: 48, height: 30, opacity: disabled ? 0.4 : 1 }}>
  <Animated.View style={[{ width: 48, height: 30, borderRadius: 15, justifyContent: 'center' }, track]}>
    <Animated.View style={[{ width: 24, height: 24, borderRadius: 12, backgroundColor: '#fff' }, knob]} />
  </Animated.View>
</Tap>
```

Exact geometry: track **48 × 30**, radius **15**. Knob **24 × 24**, radius **12**, **`#fff`** (hardcoded, both themes). Knob x: **3 (off) → 24 (on)**, travel **21 pt**, vertically centred (3 pt inset all round). Transition **240 ms `SPRING`**. Disabled → wrapper opacity **0.4** (press still animates unless `disabled` blocks it — `Tap` passes `disabled` to `Pressable`, so it does). The whole control also gets `Tap`'s press-scale at **0.92** (not the 0.955 default) and the 0.62 dim.

**Overshoot detail:** `SPRING` peaks at 1.0978, so turning **on** the knob overshoots to x ≈ **26.05** (right edge at 50.05 vs a 48-wide track — the track has **no `overflow:'hidden'`**, so the knob visibly pokes ~2 pt outside the pill at the peak); turning **off** it undershoots to x ≈ **0.95**. `interpolateColor` clamps by default (RGB space), so the track colour does **not** overshoot.

Call sites: `settings.tsx:188` (server push), `settings.tsx:220` (texturize), `TabScreens.tsx:1150` (camera rotate), `TabScreens.tsx:1317` (plug on/off, `disabled={!reachable}`).

---

### `Pop` — scale-bounce entrance

`/** Scale-bounce entrance: 0.4 → 1.12 → 1 (design: @keyframes popIn). */`

Props: **`delay = 0`**, `children?`, `style?`.

```ts
const s = useSharedValue(0.4);
const o = useSharedValue(0);
o.value = withDelay(delay, withTiming(1, { duration: 200, easing: Easing.out(Easing.quad) }));
s.value = withDelay(delay, withSequence(
  withTiming(1.12, { duration: 320, easing: Easing.out(Easing.cubic) }),
  withTiming(1,    { duration: 220, easing: SPRING }),
));
```

Exact numbers: scale **0.4 → 1.12 over 320 ms (out-cubic) → 1.0 over 220 ms (SPRING)**; total scale duration **540 ms**. Opacity **0 → 1 over 200 ms (out-quad)** — deliberately much shorter than the scale, so it is fully opaque while still bouncing. The SPRING settle overshoots *downward*: scale dips to ≈**0.988** before resting at 1.0.

Only call site: `DashboardView.tsx:422` — the checkmark/celebration glyph in the print-complete state.

---

### `Spark` + `SparkParticle` — looping outward particle cluster

> A small cluster of particles drifting outward on a loop (design: @keyframes spark). Absolutely positioned — drop it inside a relative parent at the emit point.

`Spark` props: **`color = c.accent`**, **`count = 6`**, **`size = 4`**, **`spread = 20`**.
Container: `pointerEvents="none"`, `{ position:'absolute', width: 0, height: 0 }` — a **zero-size anchor**; particles are positioned relative to its top-left origin.

```ts
// per particle i of count:
t.value = withDelay((i / count) * 1200,
  withRepeat(withTiming(1, { duration: 1300, easing: Easing.out(Easing.cubic) }), -1, false));

const ang = (i / count) * Math.PI * 2;
const dx  = Math.cos(ang) * spread;
const dy  = Math.sin(ang) * spread - 8;      // bias slightly upward

opacity: t < 0.18 ? t / 0.18 : 1 - (t - 0.18) / 0.82,
transform: [{ translateX: dx * t }, { translateY: dy * t }, { scale: 1 - 0.8 * t }],
// style: { position:'absolute', width:size, height:size, borderRadius:size/2, backgroundColor:color }
```

Exact numbers: **6 particles** evenly on a circle (60° apart, first at 0° = due east). Travel radius **`spread`** (default 20 pt) with a constant **−8 pt upward bias** applied to the y component *before* multiplying by t. Each particle: **1300 ms out-cubic**, looping forever, staggered by **`(i/count) × 1200` ms** (200 ms apart at count 6). Opacity **18 % fade-in / 82 % linear fade-out**. Scale **1 → 0.2** (`1 − 0.8t`).

**Phase gotcha:** the stagger window is **1200 ms** but the loop period is **1300 ms**, so the six particles occupy 1200 ms of a 1300 ms cycle — very slightly uneven, with a ~100 ms gap. Preserve if you want a byte-exact port; it is imperceptible.

Only call site: `TabScreens.tsx:1415` — `<Spark color={c.accent} count={6} size={3} spread={14} />` nested inside a 5×5 dot, shown when `watts != null && watts > 5`.

---

### `ExtrudeBar` — progress bar with a nozzle glyph riding the leading edge

`/** Progress bar with a nozzle glyph riding the leading edge + a glowing fill (design: extrudeBar). */`

Props: `pct: number`, **`color = c.accent`**, **`height = 8`**, **`track = c.s3`**.

**Load-bearing comment (a real performance/crash fix — must survive the port conceptually):**
```
// Track width lives in a shared value (set from onLayout) so the nozzle can ride the edge via a
// TRANSFORM — animating `left`/layout props commits a ShadowTree transaction per frame, which
// both costs more and widens the New-Arch teardown race window.
```

```ts
const w      = useSharedValue(clamp01(pct / 100));
const trackW = useSharedValue(0);                  // set in onLayout, NOT React state
w.value = withTiming(clamp01(pct / 100), { duration: 700, easing: Easing.bezier(0.4, 0, 0.2, 1) });
const fill = useAnimatedStyle(() => ({ width: `${w.value * 100}%` }));
const noz  = useAnimatedStyle(() => ({ transform: [{ translateX: w.value * trackW.value - 12 }] }));
```

Layout:
```
View { height: height + 30, paddingTop: 30 }                       // 30pt gutter above for the nozzle
  View onLayout→trackW  { height, borderRadius: height/2, backgroundColor: track }
    Animated.View (fill) { position:'absolute', left:0, top:0, bottom:0, borderRadius: height/2,
                           backgroundColor: color, shadowColor: color, shadowOpacity: 0.85,
                           shadowRadius: 6, shadowOffset:{0,0} } + animated width %
  Animated.View (nozzle) { position:'absolute', top:0, left:0 } + translateX
    Svg width=24 height=32 viewBox="48 30 96 128"                  // uniform 0.25× scale, origin (48,30)
      Rect    x=60  y=36  width=72 height=50 rx=12    fill="#C2C7CC"
      Rect    x=60  y=80  width=72 height=9  rx=4.5   fill="#878D94"
      Polygon points="74,92 118,92 106,128 96,150 86,128"  fill="#C2C7CC"
      Circle  cx=96 cy=117 r=11                       fill={color}
```

Exact numbers: fill transition **700 ms cubic-bezier(0.4, 0, 0.2, 1)** (same as `ProgressRing`). Nozzle `translateX = w·trackW − 12` — the **−12** centres the 24-pt-wide glyph on the fill edge (so at 0 % it is half off the left edge; at 100 % centred on the right edge). Fill glow: shadow opacity **0.85**, blur **6**, zero offset, colour = fill colour. Nozzle colours: body/tip **`#C2C7CC`**, collar band **`#878D94`**, the hot-end dot is the **live `color`**.

Nozzle glyph in rendered 24×32 points (viewBox translated by (−48,−30) then ×0.25): body rect (3, 1.5) 18×12.5 r3; collar rect (3, 12.5) 18×2.25 r1.125; polygon (6.5,15.5) (17.5,15.5) (14.5,24.5) (12,30) (9.5,24.5); circle centre (12, 21.75) r 2.75.

Only call site: `TabScreens.tsx:745` — `<ExtrudeBar pct={vm.progressInt} color={c.running} height={5} />`.

---

### `Breathe` — pulsing halo behind children

Comment (documents a bug that was actually shipped broken once):
> Wraps children in a pulsing colored HALO while `active` (design: powerBreathe / bulbPulse). Uses a **real sibling view (opacity + scale) rather than an iOS shadow — a shadow on a transparent wrapper doesn't render, so the old version was invisible.** `grow` controls how far the halo extends.

Props: `active: boolean`, `color: string`, `children?`, **`grow = 0.22`**, **`maxOpacity = 0.45`**, `style?`.

```ts
if (active) g.value = withRepeat(withSequence(
    withTiming(1, { duration: 1200, easing: Easing.inOut(Easing.quad) }),
    withTiming(0, { duration: 1200, easing: Easing.inOut(Easing.quad) })), -1, false);
else { cancelAnimation(g); g.value = withTiming(0, { duration: 300 }); }

const halo = useAnimatedStyle(() => ({ opacity: maxOpacity * g.value,
                                       transform: [{ scale: 1 + grow * g.value }] }));
// wrapper: { alignItems:'center', justifyContent:'center' } + style
// halo:    pointerEvents="none", { position:'absolute', left:0,right:0,top:0,bottom:0,
//                                  borderRadius: 999, backgroundColor: color } + halo
// then children (halo is BEHIND, rendered first)
```

Exact numbers: **1200 ms up / 1200 ms down, inOut-quad**, infinite. Opacity **0 → `maxOpacity`** (default 0.45). Scale **1 → 1 + `grow`** (default 1.22). Deactivate: cancel then ease to 0 over **300 ms**. Halo is a solid, fully-rounded (`borderRadius: 999`) rect filling the wrapper's bounds.

**State machine (2 states):** `inactive` (opacity 0, scale 1) ⇄ `active` (looping). Entering `inactive` cancels immediately and fades over 300 ms; entering `active` starts the loop from wherever it is.

Call sites: `TabScreens.tsx:1396` — `<Breathe active={on && reachable} color={c.accent} grow={0.18} maxOpacity={0.5} style={{borderRadius:65}}>` (the big plug button); `DashboardView.tsx:323` — `<Breathe active={vm.lightOn} color={c.accent} grow={0.8} maxOpacity={0.5}>` (chamber-light button, a **huge 1.8×** halo).

---

### `animUtils.ts` — the pure, unit-tested helpers

> Pure helpers for the animation kit — kept import-free so they stay unit-testable (the animated components themselves pull in react-native-reanimated / react-native-svg, which jest can't load).

```ts
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
  left: number;   // % across the parent
  size: number;   // px (width; height is 0.6× — actually 0.62× at the render site)
  color: string;
  dx: number;     // horizontal drift, px
  rotate: number; // total rotation, deg
  delay: number;  // start stagger, ms
  fall: number;   // fall distance, px
};

/** Deterministic when given a seeded rand() … `rand` must return [0, 1). */
export function confettiPieces(count: number, rand: () => number, colors: string[]): ConfettiPiece[] {
  const palette = colors.length ? colors : ['#2BD4C0'];
  const out: ConfettiPiece[] = [];
  for (let i = 0; i < Math.max(0, count); i++) {
    out.push({
      left:   rand() * 100,
      size:   6 + rand() * 5,
      color:  palette[Math.floor(rand() * palette.length)] ?? palette[0],
      dx:     (rand() - 0.5) * 130,
      rotate: (rand() - 0.5) * 560,
      delay:  rand() * 180,
      fall:   240 + rand() * 130,
    });
  }
  return out;
}

export function clamp01(n: number): number { return n < 0 ? 0 : n > 1 ? 1 : n; }
```
`rand()` is consumed **7 times per piece, in this exact order** — preserve it if you want seeded reproducibility. Empty-palette fallback is the hardcoded **`'#2BD4C0'`**. Negative `count` yields `[]`.

Test contract already asserted in `__tests__/animUtils.test.ts`: `splitDigits('1h 48m')` token sequence; `splitDigits(12.4)` → `[1,2,'.',4]`; `splitDigits('')` → `[]`; `splitDigits('—')` → one char token; confetti determinism for a fixed seed; `count = -3` → `[]`; never an undefined colour; `clamp01(-0.5)=0`, `clamp01(1.5)=1`.

---

### Theme tokens the kit defaults to (`src/theme.ts`)

| Token | dark | light | Used as |
|---|---|---|---|
| `c.t1` | `#F3F5F7` | `#0D1012` | `RollingNumber` default colour; confetti palette member |
| `c.s2` | `#191C1F` | `#F5F6F8` | `Skeleton` base |
| `c.s3` | `#23272B` | `#EAECEF` | `ProgressRing`/`HeatBar`/`ExtrudeBar` track; `Toggle` off colour |
| `c.accent` | `#2BD4C0` | `#0EAE9C` | `Toggle` on colour; `Spark`/`ExtrudeBar` default colour; confetti |
| `c.running` | `#30D158` | `#23B24A` | confetti |
| `c.heating` | `#FF9F0A` | `#E0860A` | confetti |
| `c.paused` | `#0A84FF` | `#0A84FF` | confetti |

`c` is a **live mutable object** (`Object.assign(c, themes[name])` on `setTheme`), read inline at render, so default props re-resolve on re-render — except inside `Confetti`'s memo and any value already captured in a shared value.

---

### Cross-cutting behaviours to preserve

1. **No mount-in animation for value-driven components.** `RollDigit` (`-d*h`), `ProgressRing` (`target`), `HeatBar` (`pct/100`), `ExtrudeBar` (`pct/100`) all **initialise their shared value at the target**, so first paint is the correct state and only subsequent changes animate. `FadeRise`/`Pop`/`Confetti` are the opposite — they exist purely for mount entrances.
2. **Every loop is `withRepeat(withSequence(a, b), -1, false)`**, and every `a`/`b` pair is symmetric, so `reverse:false` is visually identical to an autoreversed half-animation.
3. **Every "turn the loop off" path cancels first, then eases to rest** (`ProgressRing` glow 300 ms, `HeatBar` shimmer 250 ms, `Breathe` 300 ms). Never let the loop finish its cycle first.
4. **No haptics anywhere in this kit** — press feedback is purely visual.
5. **No Reduce-Motion handling anywhere** — all loops run unconditionally. This is a gap, not a design choice; decide explicitly during the port.
6. **All glow effects are iOS `shadow*` props** on the view itself (`PulseDot`, `ProgressRing`, `ExtrudeBar` fill), except `Breathe`, which deliberately uses a real sibling view (see its comment).

---

### Port notes

| RN piece | SwiftUI equivalent | Difficulty / caveats |
|---|---|---|
| **The bezier easings** | `Animation.timingCurve(x1, y1, x2, y2, duration:)` — accepts control points **including y > 1**, so `SPRING`, `ROLL_EASE`, `RISE_EASE`, `(0.4,0,0.2,1)` and `(0.2,0.6,0.4,1)` all port 1:1. | Easy. **Do not** substitute `.spring(...)` for `SPRING` — a physical spring has a different overshoot profile and settling tail than `cubic-bezier(.34,1.56,.64,1)` (peak exactly **1.0978 at t = 0.573**, done at exactly the stated duration). |
| **`Easing.out(Easing.quad)` / `out(cubic)` / `inOut(quad)` / `inOut(ease)`** | Not native. `.easeOut` is `bezier(0,0,0.58,1)` — **not** out-quad. | Medium. Either approximate (`timingCurve(0.25,0.46,0.45,0.94)` ≈ out-quad; `(0.215,0.61,0.355,1)` ≈ out-cubic; `(0.455,0.03,0.515,0.955)` ≈ inOut-quad) **or**, preferred, implement a `struct RNEasing: CustomAnimation` (iOS 17+) that evaluates the exact formulas above. Do the latter once and every number in this doc transfers verbatim. |
| **`Tap`** | `ButtonStyle` reading `configuration.isPressed` → `.scaleEffect(pressed ? 0.955 : 1)`, `.opacity(pressed ? 0.62 : 1)`, with `.animation(pressed ? in90 : out170, value: pressed)`. | Easy, but **use two different animations for in vs out** (90 ms out-quad vs 170 ms SPRING). Keep the ~1.0044 release overshoot — that's the whole feel. `hitSlop` → `.contentShape(Rectangle()).padding(-n)` or `.contentShape(.rect(inset: -n))`. Long-press = `.onLongPressGesture(minimumDuration: 0.5)` to match RN's default. |
| **`RollingNumber`** | Per digit: `VStack(spacing:0){ ForEach(0...9) }` with `.frame(height: h)` each, `.offset(y: -CGFloat(d)*h)`, wrapped in `.frame(height: h).clipped()`. `.monospacedDigit()`, `.tracking(letterSpacing)`. | Medium. **Do not use `.contentTransition(.numericText())`** — its blur/slide is a different motion. `h = (fontSize * 1.08).rounded()`; `lineHeight == h` means you must also pin line spacing (`.lineSpacing(0)` + a fixed `.frame(height:h)` per row). Row is `HStack(alignment: .bottom, spacing: 0)`. Watch the index-keyed identity gotcha: give each column `.id(index)` so a length change rolls in place rather than sliding. |
| **`PulseDot`** | `Circle().fill(color).frame(width:size,height:size).opacity(o).shadow(color: color.opacity(0.85), radius: size*0.7)` + `.animation(.timingCurve(inOutQuad, duration: period/2).repeatForever(autoreverses: true), value: phase)`. | Easy. `autoreverses: true` at half-period is **exactly** equivalent here (inOut-quad is time-symmetric). Note SwiftUI's `.shadow(radius:)` blur is not numerically identical to CALayer/RN `shadowRadius` — verify the 0.7× ratio visually and re-tune if needed. Bake `shadowOpacity: 0.85` into the colour's alpha. |
| **`ProgressRing`** | `Circle().trim(from: 0, to: progress/100).stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round)).rotationEffect(.degrees(-90))` inside a `.frame(size)` with `.padding(stroke/2)` so `r = (size-stroke)/2`. | Easy — `trim` maps exactly onto `strokeDashoffset = circ*(1-p)`. Glow: a `Circle().frame(size*0.7).shadow(...)` sibling, or `.blur()` + opacity. Animate `trim` with `.timingCurve(0.4,0,0.2,1, duration: 0.7)`. |
| **`HeatBar`** | `GeometryReader` → `Capsule().fill(color).frame(width: geo.size.width * pct/100)`. | Easy. **Don't** use `.scaleEffect(x:, anchor:.leading)` — it would squash the rounded caps, which the RN percentage-width version does not do. |
| **`Skeleton`** | `GeometryReader` gives width synchronously — the RN `useState`+`onLayout` round-trip (and its `if (!w) return` gate) disappears. Highlight = `Rectangle().fill(.white.opacity(0.06)).frame(width:150).offset(x:)` inside `.clipped()`. | Easy, and simpler than the original. Consider fixing the light-theme invisibility (white 6 % on `#F5F6F8`) while porting. |
| **`Confetti`** | Generate the pieces once into `@State` (never in `body`), then either a `Canvas` (best perf for 22 pieces) or `ForEach` with a single 0→1 driver per piece via `.task { withAnimation(...) { t = 1 } }`. | Medium. The piecewise opacity (`t<0.12 ? t/0.12 : 1-(t-0.12)/0.88`) is **not** a standard animation curve — drive it from a single `t` in a `TimelineView`/`KeyframeAnimator`, or split into two chained `withAnimation` phases (12 %/88 % of the piece's 1340–1470 ms). Rotation is `.rotationEffect(.degrees(rotate*t))`. |
| **`FadeRise`** | `.opacity` + `.offset(y:)` driven from `.onAppear`, or an `.transition(.opacity.combined(with: .offset(y: dy)))`. | Easy. The **replay-on-key** idiom (`key={tab}` / `key={step}` / `key={a.id}`) becomes `.id(tab)` — keep it, it is how the app does its tab and wizard-step transitions. Remember `dy` can be **negative** (−6 at `DashboardView.tsx:195`). |
| **`Toggle`** | **Custom control — not SwiftUI's `Toggle`.** System switch geometry is 51×31 with different colours; this one is 48×30 / knob 24 / travel 21. | Easy but must be hand-built. Track colour: SwiftUI interpolates `Color` in a different space than Reanimated's RGB `interpolateColor` — do a manual sRGB component lerp on a clamped `p` to match. The knob's ~2 pt overshoot outside the un-clipped track at the SPRING peak is visible — do **not** add `.clipShape`. |
| **`Pop`** | `KeyframeAnimator` (iOS 17+) is the clean fit: scale track `0.4 →(320 ms, out-cubic)→ 1.12 →(220 ms, SPRING)→ 1.0`; opacity track `0 →(200 ms, out-quad)→ 1`. | Easy with keyframes; awkward without (needs a `Task.sleep(320ms)` chain). Keep the ~0.988 dip on the settle leg. |
| **`Spark`** | `PhaseAnimator` or a `TimelineView(.animation)` driving `t` per particle with a `(i/count)*1200 ms` start offset and a 1300 ms period. | Medium. Same piecewise-opacity issue as Confetti (18 %/82 %). The zero-size absolute anchor becomes a `.overlay(alignment: .topLeading)` on the emit view — note the RN version emits from the parent's **top-left**, not its centre (in `TabScreens.tsx:1415` the parent is a 5×5 dot, so the offset is deliberate and small). |
| **`ExtrudeBar`** | `GeometryReader` for the track width; nozzle via `.offset(x: w*trackW - 12)`. Glyph is 4 shapes — port to a `Shape`/`Path` or an SF-free vector: body `RoundedRectangle(3)` at (3,1.5) 18×12.5, collar `RoundedRectangle(1.125)` at (3,12.5) 18×2.25, tip `Path` through (6.5,15.5)(17.5,15.5)(14.5,24.5)(12,30)(9.5,24.5), hot-end `Circle` centre (12,21.75) r 2.75 in the live colour. Body/tip `#C2C7CC`, collar `#878D94`. | Medium (the glyph). The RN comment's transform-vs-layout warning is moot in SwiftUI (`.offset` is already a render-tree change) — but keep using `.offset`, not `.frame`/`.padding`, for the same reason. |
| **`Breathe`** | `ZStack { Circle-ish halo (Capsule/RoundedRectangle(999)).fill(color).opacity(maxOpacity*g).scaleEffect(1+grow*g).allowsHitTesting(false); content }`. | Easy. The RN bug it works around ("a shadow on a transparent wrapper doesn't render") **does not exist in SwiftUI** — `.shadow` would work. Keep the solid-halo approach anyway: at `grow: 0.8, maxOpacity: 0.5` (`DashboardView.tsx:323`) a shadow cannot reproduce a 1.8× solid bloom. |

**Things that will be genuinely harder / need a different approach natively:**

1. **Piecewise opacity curves** (`Confetti`'s 12/88 split, `Spark`'s 18/82 split). Reanimated derives them from one shared `t` inside a worklet; SwiftUI's declarative `.animation` has no equivalent. Use `TimelineView(.animation)` + manual `t`, or `KeyframeAnimator` with a linear opacity track split at the breakpoint.
2. **Exact easing fidelity.** The whole design leans on non-standard curves (`out-quad` at 90 ms, `out-cubic` at 320 ms, `inOut(bezier(.42,0,1,1))` at 1400 ms). Build one `CustomAnimation` easing type up front rather than approximating each site; otherwise the port will feel subtly "off" everywhere at once and be impossible to debug.
3. **Shadow-based glows.** `PulseDot` (blur `size*0.7`, opacity 0.85), `ProgressRing` (blur 9, animated opacity 0→0.6), `ExtrudeBar` fill (blur 6, opacity 0.85) — SwiftUI's shadow radius does not map 1:1 to CALayer's, and `ProgressRing` animates `shadowOpacity` itself, which SwiftUI cannot animate directly (you must animate the shadow **colour's alpha**, or cross-fade two `.shadow` layers).
4. **`RollingNumber` column identity.** RN keys by position; with SwiftUI's `ForEach` the default identity choice will change the transition on length changes (`"9"` → `"10"`). Pin `.id(index)` to match the shipped behaviour, and decide deliberately if you'd rather fix it.
5. **`c` as a live mutable token bag.** `theme.ts` mutates a single object and notifies via `useSyncExternalStore`, so default props like `track = c.s3` re-resolve on every render. In Swift this becomes an `@Observable` theme or `@Environment` — but note `Confetti`'s memo intentionally *doesn't* re-resolve; replicate that (generate once, keep the colours) or the burst will restart on theme change.
6. **Reduce Motion.** Nothing in this kit respects it today. Adding `@Environment(\.accessibilityReduceMotion)` is cheap in the port — recommend gating the four infinite loops (`PulseDot`, `HeatBar` shimmer, `ProgressRing` glow, `Breathe`, `Spark`) and `Confetti`, while keeping `Tap`, `FadeRise`, `RollingNumber` and the progress transitions (which convey state, not decoration).
