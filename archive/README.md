# Archive

Nothing in here is maintained. It is kept because it is **evidence**, not because it is code
anyone should run: the git history alone would answer "what did it do", but not "why does the
current thing do it that way".

## `mobile/` — the Expo app

The original Sprout: Expo SDK 56 / React Native 0.85, iOS only, shipped to TestFlight up to
build 21. It was replaced by `native/`, a SwiftUI reimplementation of the same app against the same
Bambuddy backend. Both used the bundle id `com.mvks5.bambu`, so they were never installed side by
side — the App Store Connect record now carries the native builds for iOS and macOS.

**It is archived rather than deleted because several of its decisions are still load-bearing in the
Swift app,** and the reasoning is in the code rather than in the commit messages: the Live Activity
wire format (`PrintActivityAttributes.ContentState` field names are what Trellis pushes over APNs
and cannot be renamed), the config-plugin transforms that document what `expo prebuild` gets wrong
on a modern Xcode, and `present.ts` — the pure view-model the Swift `Dashboard.swift` is a port of,
test for test.

If you are looking for how the app works today, none of this is the answer. Read
[`../native/`](../native/) and the root [`CLAUDE.md`](../CLAUDE.md).

## `docs/` — the port specification

Thirteen documents written to specify the SwiftUI port, one per subsystem, each an exhaustive
description of what the React Native app did. They did their job; the port is finished and its
tests are the specification now.

They are here rather than in `docs/` because they describe **the old app's implementation**, and a
reader who does not know that will take them for current. The docs that survived into `docs/` are
the ones that describe something other than the RN code — the backend's API surface, MakerWorld's
measured behaviour, the printer's firmware refusals, the camera's frame rate, and the Mac
architecture.

`docs/guides/android.md` is here for the same reason: it is an honest account of what an Android
build would have cost *for the Expo app*, and that question no longer exists in this form.
