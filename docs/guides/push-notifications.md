# Push: Live Activities + status banners

How Sprout keeps the lock-screen print cards updating **after iOS suspends the app**, and
how the "print finished / needs attention / drying finished" banners work. Everything runs
through the bundled **`la-push`** service (`deploy/la-push/`) — no third-party push
provider, no Expo push service.

```
                ┌──────────── your server ────────────┐
 printer ──► Bambuddy ──► la-push (polls /status) ──► APNs ──► iPhone
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
2. No push *certificate* is needed — `la-push` uses token-based auth (ES256 JWT from the `.p8`).

## 1b. Each person runs their OWN la-push

`la-push` polls **your** Bambuddy with **your** API key and signs pushes with **your** APNs `.p8`,
so you can't share someone else's instance — everyone self-hosts one next to their own Bambuddy.
The app is pointed at yours in **Settings → Background push**:

- **Background push toggle** — ON = the app registers each Live-Activity card's push token with
  la-push (cards keep updating after iOS suspends the app + you get print-done/error banners). OFF =
  **local mode**: Live Activities update only while the app is open, no banners, no server required.
- **Push server (la-push)** field — your la-push base URL. Leave blank to derive it from your
  Bambuddy host (`bambuddy.` → `lapush.`); set it explicitly if la-push runs somewhere else (a LAN
  IP:8911, a different subdomain, etc.). The resolver lives in `mobile/src/config/pushConfig.ts`.

If you don't want to run la-push at all, just leave **Background push** off — everything else in the
app works; you only lose closed-app Live-Activity updates and the status banners.

## 2. App-side prerequisites (already wired in this repo)

- `app.json` → `expo-widgets` plugin with `enablePushNotifications: true` — this adds the
  `aps-environment` entitlement and enables ActivityKit push tokens. **Requires a prebuild.**
- `expo-notifications` — regular alert banners (permission prompt + device token).
- `usePrinterActivities(entries, pushUrl)` starts one Live Activity **per printing machine**,
  grabs each card's ActivityKit push token (`getPushToken()` + `addPushTokenListener`), and
  POSTs it to `la-push` `/register` keyed by printer id.
- `useStatusNotifications(pushUrl)` asks notification permission once, then POSTs the raw
  APNs **device token** to `/register-device`.
- `pushUrl` is derived from the backend host by swapping `bambuddy.` → `lapush.` in the
  hostname, or set explicitly (`pushUrl` in the stored config).

## 3. Deploy `la-push`

```bash
# on your server
cp -r deploy/la-push <deploy-dir>/la-push && cd <deploy-dir>/la-push
# put the .p8 where docker-compose.yml mounts it (default: a path OUTSIDE the repo)
# fill .env:
#   BAMBUDDY_API_KEY=bb_...            (scoped key, can_read_status is enough)
#   APNS_KEY_ID=XXXXXXXXXX             (from step 1)
#   APNS_TEAM_ID=YYYYYYYYYY
#   APNS_TOPIC=<bundle-id>.push-type.liveactivity
#   APNS_BUNDLE_ID=<bundle-id>         (alert topic; defaults to APNS_TOPIC minus the suffix)
#   APNS_HOST=api.sandbox.push.apple.com   # see "sandbox vs production" below
docker compose up -d --build
curl -s localhost:8911/health   # {"ok":true,"registrations":0,"devices":0,...}
```

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

## 4. What `la-push` does (behaviors you should expect)

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
docker logs bambu-la-push | grep -i apns
# 2. real registration — launch the app, allow notifications, then:
curl -s localhost:8911/health          # devices: 1; registrations: N while printing
# 3. real banner through the production path without waiting for a print:
docker exec -i bambu-la-push python - <<'EOF'
import asyncio, httpx, app
app._load()
async def main():
    async with httpx.AsyncClient(http2=True) as c:
        await app._notify(c, "test banner", "hello from la-push")
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
