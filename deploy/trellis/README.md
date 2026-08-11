# Trellis — Live Activity APNs push, and MakerWorld collections, for Sprout

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

## Two features, two sets of requirements

| | needs | independent of |
|---|---|---|
| **Push** — Live Activities, status banners | `BAMBUDDY_API_KEY`, and that is all | collections entirely |
| **MakerWorld collections** | `BAMBUDDY_API_KEY` + Bambuddy's docker volume mounted read-only + the server signed in to Bambu Cloud | push entirely |

One caveat that is not obvious from that table: the collections mount is declared `external` in
`docker-compose.yml`, so if the named volume does not exist **compose refuses to start the container
at all** — and the error names a volume, not a feature, so it reads as "Trellis is broken" when what
you actually lost is push, which never touches that mount. If you do not run Bambuddy in Docker,
comment out the mount and the `volumes:` block rather than guessing a name.

## Where the push goes

Every push goes through **Canopy**, which holds the APNs signing keys. Trellis holds none: no key,
no key id, no team id, no topic, no host. It cannot reach Apple at all.

`CANOPY_URL` defaults to the relay run by the app's author, which is what makes an App Store install
work with no Apple developer account. Want your own push service? Run your own Canopy and point
`CANOPY_URL` at it — see [docs/guides/self-hosting-push.md](../../docs/guides/self-hosting-push.md),
which leads with the constraint that your own Canopy also means your own *build*.

Trellis used to have a second mode that signed locally with its own `.p8`. It is gone. Every bug it
produced came from two backends having to agree about the same question — a JWT signed with an empty
issuer, a compose guard that drifted out of step with the code, two files disagreeing about the
default APNs host, a key mount naming a path that did not exist.

On first start Trellis enrols itself and prints a **recovery code, once, to the log**. Save it
somewhere that outlives the data volume: it is what lets a rebuilt server re-adopt its existing
bindings instead of enrolling as a stranger, and it is deliberately never served from an endpoint.

## Deploy (on the home server)

```bash
mkdir -p <deploy-dir>/trellis && cd <deploy-dir>/trellis
# copy EVERY *.py the Dockerfile COPYs, plus Dockerfile, docker-compose.yml, requirements.txt.
# A module you forget fails at IMPORT, after the build reports success — the container restarts in a
# loop and `docker logs` is the only place it says so. Adding a new module means editing the
# Dockerfile's COPY line too; that has bitten this service already.
cp .env.example .env    # then fill it in — the APNS_* values are required and YOURS
printf 'BAMBUDDY_API_KEY=%s\n' "$(tr -d '[:space:]' < <secrets-dir>/bb_apikey)" >> .env
docker compose up -d --build
curl -s localhost:8911/health
```

`BAMBUDDY_API_KEY` is the only required value, and compose's fail-hard `${VAR:?}` form aborts the
deploy without it. No Apple credentials of any kind: Canopy holds those.

### Tests

Stdlib `unittest`, no pytest, no network — deliberately, so they run anywhere the service runs:

```bash
python3 -m unittest discover deploy/Trellis
```

`test_makerworld.py` additionally needs `httpx`, which the service already depends on, so run it
inside the container if your host python lacks it:

```bash
docker cp deploy/Trellis/makerworld.py bambu-trellis:/tmp/
docker cp deploy/Trellis/test_makerworld.py bambu-trellis:/tmp/
docker exec bambu-trellis sh -c 'cd /tmp && python3 -m unittest test_makerworld'
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
| `POST /register` | `{printer_id, push_token, printer_name?, icon_uri?, kind?, ams_id?, client?, claim?}` — `kind` is `"print"` or `"dry"`; a drying card is one per AMS unit, so `ams_id` is required in practice for `"dry"`. Answers `{ok, bound}` — see below |
| `POST /unregister?printer_id=…` | drops a registration |
| `POST /register-start` | registers the token used for print-start pushes |
| `POST /register-device` | `{device_token}` — the raw APNs token for ordinary alert banners |
| `POST /sync` | `{tokens, device_id?, client?, icon_uri?}` — the app sends **every** Live-Activity push token it can currently see; answers `{end, cards, needs_claim}`. Reconciliation, not a state push: a registration whose token is absent no longer exists on that device, so it is dropped. `client` decides the payload shape a card adopted here is pushed with, and whether a replacement is granted |
| `GET /makerworld/collections` | `{collections: [{id, title, count, cover, is_default}]}` |
| `GET /makerworld/collections/{id}/designs?offset=&limit=` | `{total, hits}` — `hits` are MakerWorld's own shape, passed through |

### `ok` is not `bound`

`POST /register`, `/register-start` and `/register-device` all answer with both, and they answer
different questions:

```json
{"ok": true, "bound": false}
```

`ok` — Trellis stored this. `bound` — the relay can actually push to this token.

They diverge whenever the device's App Attest claim fails to build, which is routine and transient.
Reading `ok` as "registration finished" is what once froze a live card at its opening content for a
whole print while every component reported success: the app marked the pair done and never retried,
Canopy answered `not_bound` to every push, and the poll loop logged `-> 0` on every tick forever.

An absent `bound` field is read by the app as `true`, for a Trellis too old to answer.

### Replacing a card that died vs one that was dismissed

Push-to-start is armed **once per live session**, so a mid-print identity change cannot spawn a
second card. The cost is that a card which *dies* mid-print — the app was reinstalled, which
terminates running Live Activities — would never be replaced.

`/sync` and `/unregister` resolve that, and they carry opposite instructions:

- **`/unregister`** is a dismissal the app *witnessed*. The user swiped the card away; putting it
  back is the opposite of what they asked for. No replacement.
- **`/sync` reporting a card absent**, with no dismissal behind it, is a death. Trellis grants that
  **one device** a single replacement, and push-to-start makes a fresh card.

Only clients that report those two separately get the grant. The RN app's sole reconcile path is
`/sync`, so from it a swipe and a death are indistinguishable — granting on that basis would put a
deliberately dismissed card back within 45 seconds.

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

## Sharing someone else's build

If you install a TestFlight build signed by **someone else's** Apple team and point it at your own
Bambuddy and your own Trellis, you get most of the app — but **not push**, and the reason is not
fixable by configuration.

| | works? | why |
|---|---|---|
| Everything through Bambuddy | ✅ | your server, your API key |
| MakerWorld search / browse | ✅ | anonymous calls straight to `api.bambulab.com` |
| **MakerWorld collections** | ✅ | plain authenticated HTTP to *your* Trellis; `_require_key` validates the key against *your* Bambuddy. No Apple involvement |
| **Live Activities / push banners** | ❌ | see below |

Push is signed by whichever Canopy holds a key for **the team that owns the installed app's bundle
id** — Apple checks that, and no configuration works around it. Running your own Canopy against
someone else's build gets you a relay that authenticates you correctly and then cannot deliver
anything, because your key does not own their topic.

So a build signed by another team can use their relay (the default, and it just works) or nothing.
The only alternative is building the app yourself under your own team, at which point your own
Canopy signs for your own bundle id and everything works.

> Those two settings used to fight each other: the app read the push toggle to decide whether
> collections existed, so turning push off removed the Collections tab. Fixed in build 13 — see
> `ConfigRules.laPushUrl` vs `resolvePushUrl`.

For real push, build the app yourself under your own team — the repo takes `DEVELOPMENT_TEAM` from
the environment for exactly this reason (`native/.env-local.example`). Then your bundle id, your
APNs key and your Trellis all belong to you and everything above turns green.

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
