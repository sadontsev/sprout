# 14 — The Liquid Glass tab bar

Why the bottom bar is a system `TabView` and not the hand-rolled `HStack` it used to be, with the
sources that settle it. Read this before "improving" the bar again.

## The question this answers

The first native port shipped a hand-rolled bar: an `HStack` of buttons inside a
`GlassEffectContainer`, with `.glassEffect(.regular.tint(…).interactive(), in: .capsule)` on the
selected item, floated over the content by a `ZStack(alignment: .bottom)`.

It looked approximately right in a screenshot and wrong in the hand. The specific complaint was that
there was **no gloss response when the bar is pressed and pulled** — the thing first-party apps do
where the selected pill lenses, stretches and drags the specular highlight with your finger.

`.glassEffect(…​.interactive())` does *not* reproduce that. `.interactive()` gives a custom view a
press/scale reaction to touch; the tab bar's held-and-dragged behaviour is the *system tab bar's own*
interaction, driven by the platform's tab-bar gesture recognisers and its privileged access to the
real Liquid Glass material. There is no public API that hands a custom `HStack` that behaviour.

## What Apple actually says

**Leverage system frameworks — don't rebuild the control.** From Apple's
[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
technology overview, which is the decisive source here:

> Leverage system frameworks to adopt Liquid Glass automatically.

and, on tab bars specifically, that they

> adopt a Liquid Glass appearance and float in a distinct functional layer to help people focus on
> underlying content.

The same page warns against exactly what the old bar did:

> Reduce custom backgrounds in controls and navigation elements — custom backgrounds might overlay or
> interfere with Liquid Glass effects.

> Avoid overusing Liquid Glass effects — if you apply Liquid Glass effects to custom controls, do so
> sparingly to avoid distracting from content.

[Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
is the page that documents `.glassEffect` / `GlassEffectContainer`. It is scoped to *custom* views —
bespoke controls that have no system equivalent. A bottom tab bar has a system equivalent, so it is
the wrong tool for this job.

[WWDC25 session 323, "Build a SwiftUI app with the new design"](https://developer.apple.com/videos/play/wwdc2025/323/)
covers the tab bar as a `TabView` feature throughout and never suggests hand-rolling one.

**Conclusion: stop hand-rolling. Adopt `TabView` + the `Tab` builder.** The system then renders the
bar in the real material, and the held-and-pulled gloss comes for free because it is the system's
own control doing it.

## The API, verified against the SDK

Signatures below were read out of the shipping SDK's
`SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`, not from memory —
several of these were renamed late in the iOS 26 beta cycle and blog posts still carry the old names.
To re-verify after an Xcode bump, grep that file.

| API | Signature | Availability |
| --- | --- | --- |
| Tab, SF Symbol icon | `Tab(_ titleKey: LocalizedStringKey, systemImage: String, value: Value, @ContentBuilder content: () -> Content)` | iOS 18.0+ |
| Tab, asset-catalog icon | `Tab(_ titleKey: LocalizedStringKey, image: String, value: Value, @ContentBuilder content: () -> Content)` | iOS 18.0+ |
| Tab, custom label view | `Tab(value: Value, @ContentBuilder content: () -> Content, @ContentBuilder label: () -> Label)` | iOS 18.0+ |
| Tab role | `Tab(… , role: TabRole?, …)`; `TabRole.search` | iOS 18.0+ (`.prominent` is 27.0) |
| Minimise on scroll | `func tabBarMinimizeBehavior(_ behavior: TabBarMinimizeBehavior) -> some View` | **iOS 26.0+** |
| …its cases | `.automatic`, `.onScrollDown`, `.onScrollUp`, `.never` | `.onScrollDown` etc. are iOS-only, 26.0+ |
| Bottom accessory | `func tabViewBottomAccessory<Content>(@ContentBuilder content: () -> Content) -> some View` (and an `isEnabled:` overload) | iOS 26.0+ |
| …its placement | `EnvironmentValues.tabViewBottomAccessoryPlacement: TabViewBottomAccessoryPlacement?` | iOS 26.0+ |
| Scroll edge effect | `func scrollEdgeEffectStyle(_:for:)` | iOS 26.0+ |
| Sidebar adaptation | `TabViewStyle.sidebarAdaptable` | iOS 18.0+ |

Notes that cost time if you don't know them:

- **`tabBarMinimizeBehavior` is the modifier that makes the bar recede on scroll.** Apple's
  [reference page](https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:))
  documents it as iOS 26.0+, "Sets the behavior for tab bar minimization", with `.onScrollDown` as
  the example. It goes on the `TabView`, not on the inner `ScrollView`.
- **`tabViewBottomAccessory` puts a view in the space the minimising bar vacates.** Per session 323:
  "Place a view above the bar with the `tabViewBottomAccessory` modifier. This takes advantage of the
  extra space provided by the tab bar's collapsing behavior." Read
  `tabViewBottomAccessoryPlacement` from the environment to reflow when it collapses inline. This app
  does not use one yet — a live print-progress pill is the obvious candidate.
- **A search tab is a *role*, not a layout.** `Tab(role: .search) { … }` plus `.searchable` on the
  `TabView`; the system moves it to the trailing end on its own. Sprout has no search tab, so this is
  documented but unused.
- **Scroll edge effect is automatic** for content under a system bar. `scrollEdgeEffectStyle(.hard,
  for: .top)` only exists to sharpen it for dense UIs. Sprout's screens leave it at the default.

## Deployment target

`native/project.yml` already pins `IPHONEOS_DEPLOYMENT_TARGET: "26.0"`, so **every API above is
unconditionally available and no `if #available` guards are needed.** That is why the implementation
has none — do not add them back "for safety"; they would be dead code. The one thing to watch is
`TabRole.prominent`, which is iOS 27.0+ and *would* need a guard if it is ever used.

## What this bought us, concretely

- **The held-and-pulled gloss is real**, because the control is the system's.
- **Reduce Transparency is handled by the system.** The old bar carried an explicit
  `@Environment(\.accessibilityReduceTransparency)` branch that swapped the glass for a flat fill.
  The system tab bar already does the right thing, so that code is gone — deleting it *is* the fix,
  not a regression.
- **The bar contributes a safe-area inset.** This is the load-bearing layout consequence: the old bar
  floated in a `ZStack` and took no layout space, so five screens hand-reserved `.padding(.bottom,
  120)` to keep content out from under it. A system `TabView` insets its children's safe area
  automatically and `ScrollView` honours that, so those 120 pt became *dead space stacked on top of
  the system inset*. They are now 32 pt of ordinary end-of-content breathing room — the value
  `PowerView` already used, with a comment that had correctly predicted this.

## What we deliberately did not keep

- **The `FadeRise(dy: 8, duration: 0.3)` entrance keyed on the tab.** The RN build replayed a
  fade-and-rise on every tab change because it had no system transition to lean on. `TabView` has
  one, and it also keeps each tab's view alive rather than rebuilding it, so a re-keyed entrance both
  fights the system cross-fade and no longer has a natural trigger. Dropped.
- **`withAnimation(Motion.spring(0.42))` around the selection write.** The system animates its own
  selection change; wrapping the binding write only adds a second, conflicting curve.

`Motion` and `FadeRise` themselves are untouched — they are used all over the rest of the app.

## The one real friction: a brand glyph in a system tab bar

The Printer tab uses the app's nozzle mark, not an SF Symbol. `NozzleIcon` draws it with `Canvas`,
and a `Canvas` cannot be a tab-bar icon: the system bar renders items through UIKit and needs an
*image* it can treat as a template, so that it can tint it for selected/unselected state. A custom
`label:` closure wrapping a `Canvas` gets you a fixed-colour glyph that ignores the tab bar's tint at
best.

The fix is a **vector asset**: `Sprout/Resources/Assets.xcassets/TabNozzle.imageset` holds an SVG of
the same artwork with `"template-rendering-intent": "template"` and `"preserves-vector-representation":
true`, consumed via the `Tab(_:image:value:content:)` initialiser. The system tints it exactly like
the SF Symbols on the other four tabs.

This does mean the nozzle geometry exists twice — once as `Canvas` drawing commands in
`NozzleIcon.swift` (still used at 44 pt in Settings, where we control the drawing) and once as the
SVG. Both are generated from the same `48 30 96 142` viewBox and the same five shapes, and both files
say so. Keep them in step, or collapse them if the Settings usage ever stops needing the Canvas.
