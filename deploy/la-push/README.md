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
# copy app.py Dockerfile docker-compose.yml requirements.txt here
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

- `GET  /health` → `{ok, registrations, apns_host}`
- `POST /register` `{printer_id, activity_id, push_token, printer_name?, icon_uri?}`
- `POST /unregister?activity_id=…`

## Exposure

The app reaches this over the same remote path as Bambuddy. Add an ingress route (cloudflared/Tailscale)
to `localhost:8911` and point the app's push URL at it. Registrations persist in `./data/registrations.json`.
