# Docs

Two kinds of document live here, and the difference is worth knowing before you trust one.

**Guides** tell you how to run the thing. **References** record what somebody measured, usually
after being surprised — they exist because the obvious assumption was wrong, and they say what the
wrong assumption was.

## Guides — start here

| | |
|---|---|
| [`guides/push-notifications.md`](guides/push-notifications.md) | Set up Trellis so lock-screen cards keep updating. The only value you must set is `BAMBUDDY_API_KEY`. |
| [`guides/self-hosting-push.md`](guides/self-hosting-push.md) | Run your own Canopy instead of the author's, if you'd rather hold your own APNs keys. |

The backend itself is [`../deploy/README.md`](../deploy/README.md), and building the app is in the
root [`README.md`](../README.md).

## Reference

| | |
|---|---|
| [`phase0-results.md`](phase0-results.md) | The backend bring-up spike, validated end to end against a real China-market printer. URLs, auth, preset names. No secrets. |
| [`design/push-architecture.md`](design/push-architecture.md) | How Sprout → Trellis → Canopy → APNs fits together, and why the trust boundary sits where it does. |
| [`native-rewrite/01-api.md`](native-rewrite/01-api.md) | Every Bambuddy endpoint the app uses, with auth and response shapes. |
| [`native-rewrite/14-liquid-glass-tabbar.md`](native-rewrite/14-liquid-glass-tabbar.md) | Why the iOS tab bar is a system `TabView` and not a hand-rolled `HStack`. Read before "improving" it again. |
| [`native-rewrite/15-makerworld-design.md`](native-rewrite/15-makerworld-design.md) | MakerWorld's real behaviour, with the probes. Which endpoints answer anonymously, which lie with a `200`, and why no sort parameter works. |
| [`native-rewrite/16-cloud-control-design.md`](native-rewrite/16-cloud-control-design.md) | Why the H2C refuses nine actions (`mqtt message verify failed`) while status keeps flowing, and what could be done about it. Research; no code. |
| [`native-rewrite/17-camera-fps-investigation.md`](native-rewrite/17-camera-fps-investigation.md) | Where the chamber camera's frame rate is actually decided. Self-contained. |
| [`native-rewrite/18-mac-port-architecture.md`](native-rewrite/18-mac-port-architecture.md) | The macOS app: one target, two destinations, and the things that fail silently. |

The `native-rewrite/` numbering has gaps because it used to be a complete port specification —
one document per subsystem of the React Native app. Those thirteen did their job and now live in
[`../archive/docs/`](../archive/docs/); the port is finished and the Swift tests are the
specification. What stayed is what describes something *other* than the old app's code: the
backend, MakerWorld, the printer's firmware, the camera, the Mac.
