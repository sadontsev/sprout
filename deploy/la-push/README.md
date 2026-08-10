# la-push — Live Activity APNs push for Sprout

Keeps the iOS Live-Activity lock-screen cards updating **after the app is suspended**. The app starts
one Live Activity per printer and `POST /register`s each card's APNs push token here. This service
polls Bambuddy for each registered printer and pushes the ContentState to Apple
(`apns-push-type: liveactivity`), ending a card when its print finishes/fails/goes idle.

The pushed ContentState must match `PrintActivityProps` in
`mobile/src/liveactivity/PrintActivity.tsx`; the state/colour mapping mirrors `present.ts`.

## Deploy (on <your-server>)

```bash
mkdir -p <deploy-dir>/la-push && cd <deploy-dir>/la-push
# copy app.py clients.py cooldown.py p2s.py Dockerfile docker-compose.yml requirements.txt here
# (every *.py the Dockerfile COPYs — a missing module fails at import, after the build succeeds)
printf 'BAMBUDDY_API_KEY=%s\n' "$(tr -d '[:space:]' < <secrets-dir>/bb_apikey)" > .env   # gitignored
docker compose up -d --build
curl -s localhost:8911/health
```

Requires the APNs key at `<secrets-dir>/apns_key.p8` (Key ID `<YOUR_APNS_KEY_ID>`, Team `<YOUR_TEAM_ID>`).

## APNs environment (important)

- **Local Xcode / dev builds** → `aps-environment: development` → use **`api.sandbox.push.apple.com`** (the default).
- **TestFlight / App Store** → `aps-environment: production` → set `APNS_HOST=api.push.apple.com` in `.env` and recreate.

A push against the wrong gateway fails silently (Apple returns `BadDeviceToken`).

## Endpoints

- `GET  /health` → `{ok, registrations, apns_host, cards_by_client, start_tokens_by_client}`
- `POST /register` `{printer_id, activity_id, push_token, printer_name?, icon_uri?, client?}`
- `POST /unregister?activity_id=…`

## Two clients

The RN app (`mobile/`) and the native SwiftUI app (`native/`) ship as different TestFlight builds of
the same bundle id and both register here. Their Live-Activity wire shapes are incompatible — a
wrapped `{name, props}` content state and `LiveActivityAttributes` for expo-widgets, a flat content
state and `PrintActivityAttributes{printerId, amsId}` for the native app — and a mismatch is
**silent**: APNs returns 200 and the card never updates (or never appears). So `/register` and
`/register-start` take `client: "expo" | "native"`, defaulting to `"expo"` for the installed RN
build, which does not send the field. `GET /health` reports the split, which is the only way to see a
native build that registered as expo without picking up the phone. Shapes live in `clients.py`.

## Exposure

The app reaches this over the same remote path as Bambuddy. Add an ingress route (cloudflared/Tailscale)
to `localhost:8911` and point the app's push URL at it. Registrations persist in `./data/registrations.json`.
