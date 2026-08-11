# Push: Live Activities + status banners

How Sprout keeps the lock-screen print cards updating **after iOS suspends the app**, and
how the "print finished / needs attention / drying finished" banners work. Everything runs
through the bundled **Trellis** service (`deploy/trellis/`) — no third-party push
provider, no Expo push service.

```
                ┌──────────── your server ────────────┐
 printer ──► Bambuddy ──► Trellis (polls /status) ──► APNs ──► iPhone
                                   ▲
        app registers tokens ──────┘   (Live-Activity token per printer + one device token)
```

## 1. One-time Apple setup

1. In [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list),
   create an **APNs Auth Key** and download the `.p8`. Note the **Key ID** (10 chars) and
   your **Team ID**.
   - ⚠️ Apple caps you at **2 APNs keys per team**, team-wide. If you're blocked, audit the
     existing keys before revoking — EAS-managed apps on the same team may be using one.
   - The same key signs pushes for **all** apps on the team; no per-app key needed.
2. No push *certificate* is needed — Trellis uses token-based auth (ES256 JWT from the `.p8`).

## 1b. Each person runs their OWN Trellis

Trellis polls **your** Bambuddy with **your** API key and signs pushes with **your** APNs `.p8`,
so you can't share someone else's instance — everyone self-hosts one next to their own Bambuddy.
The app is pointed at yours in **Settings → Background push**:

- **Background push toggle** — ON = the app registers each Live-Activity card's push token with
  Trellis (cards keep updating after iOS suspends the app + you get print-done/error banners). OFF =
  **local mode**: Live Activities update only while the app is open, no banners, no server required.
- **Push server (Trellis)** field — your Trellis base URL. Leave blank to derive it from your
  Bambuddy host (`bambuddy.` → `lapush.`); set it explicitly if Trellis runs somewhere else (a LAN
  IP:8911, a different subdomain, etc.). The resolver lives in `mobile/src/config/pushConfig.ts`.

If you don't want to run Trellis at all, just leave **Background push** off — everything else in the
app works; you only lose closed-app Live-Activity updates and the status banners.

## 2. App-side prerequisites (already wired in this repo)

- `app.json` → `expo-widgets` plugin with `enablePushNotifications: true` — this adds the
  `aps-environment` entitlement and enables ActivityKit push tokens. **Requires a prebuild.**
- `expo-notifications` — regular alert banners (permission prompt + device token).
- `usePrinterActivities(entries, pushUrl)` starts one Live Activity **per printing machine**,
  grabs each card's ActivityKit push token (`getPushToken()` + `addPushTokenListener`), and
  POSTs it to Trellis `/register` keyed by printer id.
- `useStatusNotifications(pushUrl)` asks notification permission once, then POSTs the raw
  APNs **device token** to `/register-device`.
- `pushUrl` is derived from the backend host by swapping `bambuddy.` → `lapush.` in the
  hostname, or set explicitly (`pushUrl` in the stored config).

## 3. Deploy Trellis

```bash
# on your server
cp -r deploy/trellis <deploy-dir>/Trellis && cd <deploy-dir>/Trellis
cp .env.example .env            # then fill it in — every APNS_* below is REQUIRED
#   BAMBUDDY_API_KEY=bb_...            (scoped key, can_read_status is enough)
#   APNS_KEY_ID=XXXXXXXXXX             (from step 1 — YOURS, not the repo owner's)
#   APNS_TEAM_ID=YYYYYYYYYY
#   APNS_TOPIC=<your-bundle-id>.push-type.liveactivity
#   APNS_KEY_FILE=/path/to/your/apns_key.p8   (defaults to <secrets-dir>/apns_key.p8)
#   APNS_HOST=api.sandbox.push.apple.com      # see "sandbox vs production" below
# Leave APNS_BUNDLE_ID OUT unless your bundle id is not APNS_TOPIC minus the suffix — an
# EMPTY value defeats the derived default and sends an empty alert topic.
docker compose up -d --build
curl -s localhost:8911/health   # {"ok":true,"registrations":0,"devices":0,...}
```

The `APNS_*` values use compose's fail-hard `${VAR:?}` form, so a missing one aborts the deploy
rather than failing at the first push. They were hardcoded literals for a while: anyone else
deploying signed with **their** `.p8` while claiming the original owner's key id and team, and
APNs answered `403 InvalidProviderToken` / `400 TopicDisallowed` — the first and third rows of
the troubleshooting table below, whose stated cause then sends you looking in the wrong place.

**One more mount.** `docker-compose.yml` also attaches Bambuddy's data volume read-only, for the
native app's MakerWorld **collections** endpoints — see
[deploy/trellis/README.md](../../deploy/trellis/README.md#makerworld-collections). The volume is
declared `external`, so it must already exist under the expected name:

```bash
docker inspect bambuddy --format '{{range .Mounts}}{{.Name}}{{end}}'   # e.g. bambuddy_bambuddy_data
# if yours differs, set BAMBUDDY_VOLUME=<that name> in .env
```

Compose **refuses to start** when an external volume is missing (`external volume "…" not found`),
so a wrong name is loud here. If you do not want collections at all, comment out the
`bambuddy_data:` volume entry and `BAMBUDDY_DB` — everything else works without them.

Expose port 8911 to the phone the same way you exposed Bambuddy (Tailscale / tunnel / LAN),
at a hostname matching the `bambuddy.` → `lapush.` convention (e.g.
`https://lapush.example.com`) or configure the URL explicitly in the app.

### Sandbox vs production — the classic silent failure

APNs has two gateways and **tokens from one are invalid on the other**:

| build | `aps-environment` | `APNS_HOST` |
|---|---|---|
| Xcode / local install | `development` | `api.sandbox.push.apple.com` |
| TestFlight / App Store | `production` | `api.push.apple.com` |

Wrong pairing ⇒ every push gets HTTP **400 `BadDeviceToken`**. Flip `APNS_HOST` when you
move to TestFlight.

## 4. What Trellis does (behaviors you should expect)

- **Live-Activity cards**: polls each *registered* printer's `/status` every ~5s, pushes the
  ContentState on meaningful change (throttled), and **ends** the card on
  complete/error/idle. Dead tokens (400/410) are dropped. The ContentState shape must match
  `PrintActivityProps` in `mobile/src/liveactivity/` — if you change one, change both.
- **Status banners** (need ≥1 registered device token; the poll then covers the whole
  fleet, cards or not). Edge-triggered — the first observation after a restart is silent:
  - `live → complete` ⇒ "✅ <printer> — print finished"
  - `→ error` ⇒ "⚠️ <printer> — needs attention"
  - AMS `dry_time` running out (≤15 min → 0) ⇒ "💨 <printer> — drying finished".
    A manual stop (big remaining → 0) stays deliberately silent.
- **Restart-safe**: registrations, device tokens, and the edge-detection state persist in
  `data/registrations.json`, so a redeploy mid-print doesn't swallow the finish banner.

## 5. Verifying the pipeline

```bash
# 1. auth sanity — a FAKE token must yield 400 BadDeviceToken (proves the JWT/key works):
docker logs bambu-Trellis | grep -i apns
# 2. real registration — launch the app, allow notifications, then:
curl -s localhost:8911/health          # devices: 1; registrations: N while printing
# 3. real banner through the production path without waiting for a print:
docker exec -i bambu-Trellis python - <<'EOF'
import asyncio, httpx, app
app._load()
async def main():
    async with httpx.AsyncClient(http2=True) as c:
        await app._notify(c, "test banner", "hello from Trellis")
asyncio.run(main())
EOF
```

## 6. Troubleshooting

| symptom | cause |
|---|---|
| 403 `InvalidProviderToken` | wrong Key ID / Team ID, or the `.p8` content is mangled |
| 400 `BadDeviceToken` on REAL tokens | sandbox/production mismatch (see table above) |
| 400 `TopicDisallowed` | `APNS_TOPIC` doesn't match the bundle id (+ `.push-type.liveactivity` for cards) |
| cards start but freeze when the app closes | the app never registered the token — check `pushUrl` reachability from the phone, and `/health` `registrations` |
| banners never fire | no device token (`devices: 0`) — notification permission denied, or `/register-device` unreachable |
| everything worked, then stopped after weeks | APNs keys don't expire, but check the container is up and Bambuddy's API key is still valid |
