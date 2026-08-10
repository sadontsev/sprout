# la-push — Live Activity APNs push, and MakerWorld collections, for Sprout

Two jobs, one service, because the second one needs a machine the first one already is.

**Push.** Keeps the iOS Live-Activity lock-screen cards updating **after the app is suspended**. The
app starts one Live Activity per printer and `POST /register`s each card's APNs push token here. This
service polls Bambuddy for each registered printer and pushes the ContentState to Apple
(`apns-push-type: liveactivity`), ending a card when its print finishes/fails/goes idle.

**MakerWorld collections.** Serves the owner's own MakerWorld collections to the app. See
[MakerWorld collections](#makerworld-collections) — the short version is that reading them needs a
Bambu Cloud bearer, that bearer must not go on a phone, and this is the machine that already has one.

The pushed ContentState must match `PrintActivityProps` in
`mobile/src/liveactivity/PrintActivity.tsx`; the state/colour mapping mirrors `present.ts`.

## Deploy (on the home server)

```bash
mkdir -p <deploy-dir>/la-push && cd <deploy-dir>/la-push
# copy EVERY *.py the Dockerfile COPYs, plus Dockerfile, docker-compose.yml, requirements.txt.
# A module you forget fails at IMPORT, after the build reports success — the container restarts in a
# loop and `docker logs` is the only place it says so. Adding a new module means editing the
# Dockerfile's COPY line too; that has bitten this service already.
cp .env.example .env    # then fill it in — the APNS_* values are required and YOURS
printf 'BAMBUDDY_API_KEY=%s\n' "$(tr -d '[:space:]' < <secrets-dir>/bb_apikey)" >> .env
docker compose up -d --build
curl -s localhost:8911/health
```

Needs your own APNs auth key `.p8` on the host — by default at
`<secrets-dir>/apns_key.p8`, or wherever `APNS_KEY_FILE` points. `APNS_KEY_ID`,
`APNS_TEAM_ID` and `APNS_TOPIC` use compose's fail-hard `${VAR:?}` form, so a missing one aborts
the deploy rather than surfacing as an APNs `403 InvalidProviderToken` at the first push.

### Tests

Stdlib `unittest`, no pytest, no network — deliberately, so they run anywhere the service runs:

```bash
python3 -m unittest discover deploy/la-push
```

`test_makerworld.py` additionally needs `httpx`, which the service already depends on, so run it
inside the container if your host python lacks it:

```bash
docker cp deploy/la-push/makerworld.py bambu-la-push:/tmp/
docker cp deploy/la-push/test_makerworld.py bambu-la-push:/tmp/
docker exec bambu-la-push sh -c 'cd /tmp && python3 -m unittest test_makerworld'
```

## APNs environment (important)

- **Local Xcode / dev builds** → `aps-environment: development` → use **`api.sandbox.push.apple.com`**.
- **TestFlight / App Store** → `aps-environment: production` → `APNS_HOST=api.push.apple.com` (the default).

A push against the wrong gateway fails silently (Apple returns `BadDeviceToken`).

## Endpoints

Every one is gated on a **valid Bambuddy API key** in `X-API-Key`. Validation is delegated to
Bambuddy — equality with the configured key is a fast path, any other key is accepted iff Bambuddy
answers 200 to a read with it, and an unreachable Bambuddy fails **closed**. Without that gate,
anyone who knows the public URL could register for the owner's print notifications, or read their
collections.

| | |
|---|---|
| `GET /health` | `{ok, registrations, apns_host, cards_by_client, start_tokens_by_client}` — **unauthenticated** |
| `POST /register` | `{printer_id, push_token, printer_name?, icon_uri?, kind?, ams_id?, client?}` — `kind` is `"print"` or `"dry"`; a drying card is one per AMS unit, so `ams_id` is required in practice for `"dry"` |
| `POST /unregister?printer_id=…` | drops a registration |
| `POST /register-start` | registers the token used for print-start pushes |
| `POST /register-device` | `{device_token}` — the raw APNs token for ordinary alert banners |
| `POST /sync` | `{tokens, icon_uri?}` — the app sends **every** Live-Activity push token it can currently see; answers `{end, cards}`. This is reconciliation, not a state push: a registration whose token is absent has had its card dismissed, so it is dropped |
| `GET /makerworld/collections` | `{collections: [{id, title, count, cover, is_default}]}` |
| `GET /makerworld/collections/{id}/designs?offset=&limit=` | `{total, hits}` — `hits` are MakerWorld's own shape, passed through |

## MakerWorld collections

The app can search and browse MakerWorld anonymously, but **collections are Bearer-gated**, and that
bearer is the whole Bambu account. It is not put on the phone: a phone is lost or stolen far more
often than a home server, and Bambu Lab has been actively hostile to third-party cloud access, so a
bearer used from a mobile IP by a non-Bambu client is the pattern most likely to get an account
actioned. Bambuddy exposes no collection endpoint and its `POST /cloud/token` only *accepts* a token,
so the only way to reach one is to read Bambuddy's own database — which is what this does.

**The compose file mounts Bambuddy's volume read-only.** Two things about that:

- The volume is joined from outside Bambuddy's compose project, so it is declared `external` under
  the name docker compose generated for it — **`bambuddy_bambuddy_data`** by default, project prefix
  and all. Override with `BAMBUDDY_VOLUME` in `.env` if yours differs. Check which one Bambuddy
  actually uses; a bare `bambuddy_data` may also exist as an empty leftover:

  ```bash
  docker inspect bambuddy --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}'
  ```

  Compose refuses to start when an external volume is missing, so a wrong *name* is loud — but
  mounting a real-but-empty volume fails **silently**, and collections then report "can't see
  Bambuddy's database" forever.

- It is mounted `:ro` and opened with SQLite's `file:…?mode=ro` URI. This service must never be able
  to write another application's database.

The token is re-read **per request**, not cached, so one Bambuddy refreshes is picked up at once and
one it drops stops working at once.

### The trap this code is shaped around

MakerWorld answers **`200` with an empty list** to unauthenticated callers on some paths.
`design-service/favorites/designs/{uid}` returns `total: 0` with no token and `total: 30` with one,
for the same account. So "you have no collections" and "your sign-in expired" look identical on the
wire, and the failure is not an error anyone sees — it is a screen that calmly shows nothing.

The two endpoints used here were chosen because they fail **loudly** without a bearer
(`my/favorites/listlite` → 401, `favorites/{id}/designs` → 403), and every failure path raises with a
reason rather than degrading to an empty list. The status codes are kept apart on purpose:

- **503** — this box cannot act: no database mounted, or no token stored. Fix the server.
- **502** — MakerWorld refused: expired sign-in, rate limit, unreachable. Fix the Bambu Cloud login.

Collapsing them would send the owner to the wrong machine.

### Not implemented: adding to a collection

Probed, not found. `POST /design-service/my/favorites` (create a collection) exists and validates on
a `title` field, but no add-a-design-to-a-collection route answered at any of six plausible paths —
`favorites/{id}/designs` is `Allow: GET` only. Shipping the create half alone would be a button that
makes empty folders nothing can be put into.

> ⚠️ While probing, `DELETE /design-service/my/favorites/{id}` turned out to **delete an entire
> collection**. It was found by accident and refused only because the id probed happened to be the
> protected Default Collection. Any other id would have destroyed real data. `deploy/spikes/` carries
> that warning and no longer probes `DELETE`.

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

The app reaches this over the same remote path as Bambuddy. Add an ingress route (cloudflared /
Tailscale) to `localhost:8911` and point the app's push URL at it — the app derives `lapush.<domain>`
from a `bambuddy.<domain>` host, or takes an explicit URL in Settings → Advanced. Registrations
persist in `./data/registrations.json`.

Note that the collections endpoints ride the same route, so the API-key gate above is what stands
between the public internet and the owner's MakerWorld account. Do not add an endpoint here without
`Depends(_require_key)`.
