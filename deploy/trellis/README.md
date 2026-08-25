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
`archive/mobile/src/liveactivity/PrintActivity.tsx`; the state/colour mapping mirrors `present.ts`.

## Two features, two sets of requirements

| | needs | independent of |
|---|---|---|
| **Push** — Live Activities, status banners | `BAMBUDDY_API_KEY`, and that is all | collections entirely |
| **MakerWorld collections** | `BAMBUDDY_API_KEY` + the `docker-compose.collections.yml` overlay + Bambuddy in Docker, **signed in to Bambu Cloud** | push entirely |

Collections live in an overlay rather than the base file because their mount is an `external`
volume, and an external volume that does not exist makes compose refuse to start the container **at
all**. In the base file that turned a collections misconfiguration into no push, reported as
`external volume "…" not found` — a volume name rather than the feature actually lost.

```bash
docker compose up -d                                                # push only
docker compose -f docker-compose.yml -f docker-compose.collections.yml up -d   # + collections
```

**Collections need Bambuddy signed in to Bambu Cloud** (Bambuddy → Cloud Profiles). Every
collections endpoint on `api.bambulab.com` is Bearer-gated and that bearer is your whole Bambu
account, so it is read from Bambuddy's database on the server and never reaches a phone. Without the
sign-in, Trellis answers with a sentence saying so — that API returns `200` with an empty list to an
unauthenticated caller, so "you have none" and "your sign-in expired" are indistinguishable on the
wire and only one of them is worth telling you about.

## Reaching Trellis from the phone

Trellis listens on **8911**, and the app must reach it to register push tokens. Push *delivery*
does not involve the phone at all — but registering does, and it happens whenever a card starts or
a token rotates. A LAN-only Trellis therefore works until a print begins while you are out, and
that card then stays frozen for the whole print.

Give it a public HTTPS hostname (`https://trellis.example.com` → `<server>:8911`), fronted the same
way as Bambuddy. iOS blocks plain HTTP to a public hostname with no useful error; only IP literals
and `.local` names are exempt, and both are LAN-only.

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

The image is **prebuilt** — `ghcr.io/sadontsev/sprout/trellis`, `linux/amd64` and `linux/arm64`.
Nothing compiles on your box, so the only files you need are the compose file and your `.env`.

```bash
mkdir -p <deploy-dir>/trellis && cd <deploy-dir>/trellis
curl -O https://raw.githubusercontent.com/sadontsev/sprout/main/deploy/trellis/docker-compose.yml
curl -O https://raw.githubusercontent.com/sadontsev/sprout/main/deploy/trellis/.env.example
cp .env.example .env    # then fill it in
printf 'BAMBUDDY_API_KEY=%s\n' "$(tr -d '[:space:]' < <secrets-dir>/bb_apikey)" >> .env
docker compose up -d
curl -s localhost:8911/health
```

Update by hand, whenever you feel like it:

```bash
docker compose pull && docker compose up -d
```

### Which version you follow

`TRELLIS_TAG` in `.env` picks the line, defaulting to `latest`:

| value | you get |
|---|---|
| `latest` | every release, including breaking ones |
| `1` | patches and features within major 1, never a major bump |
| `1.4.2` | exactly that, forever |

### Automatic updates (optional)

```bash
docker compose -f docker-compose.yml -f docker-compose.watchtower.yml up -d
```

**Watchtower needs the Docker socket, and the Docker socket is root on the host.** A container
holding it can start any other container, mount any path, and read any secret on the machine. That
is a real trade for never updating by hand, and it should be a decision rather than a default —
which is why it is a separate file you have to name. `docker compose pull` costs two commands and
no socket.

If you do use it, **set `TRELLIS_TAG=1` first**. Watchtower re-pulls whatever tag the container was
*started* with, so on `latest` it will eventually pull a major version with breaking changes,
unattended, at whatever hour the interval lands on.

### Building it yourself

Contributors, and anyone running a modified Trellis:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

That overlay is also the answer if you distrust the published image — it builds from the source in
front of you. Note the Dockerfile COPYs each `*.py` by name: a module you add and forget fails at
IMPORT, after the build reports success, and the container restarts in a loop with `docker logs` as
the only place it says so.

### Releases

Tagging `trellis-v*` builds both architectures, publishes to GHCR and opens a GitHub Release whose
notes are the commits touching `deploy/trellis/` since the previous such tag:

```bash
git tag trellis-v1.0.0 && git push origin trellis-v1.0.0
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
| `GET /health` | `{ok, registrations, relay, cards_by_client, start_tokens_by_client, push_suspended, needs_claim, unadopted_starts, cards}` — **unauthenticated**. The last three answer "why is that card not moving?" — see [A card nobody claims](#a-card-nobody-claims) |
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

### A card nobody claims

A push-to-started card is **frozen at the content the start push created** until the app hands over
that card's own update token. Only the app can: ActivityKit gives the token to a running process and
to nobody else. Nothing about that state looks broken — the ETA counts down on the device with no
push behind it, Trellis reports `ok: true`, and Apple never sees a request to reject.

It ran for thirteen days on a real deployment. The only evidence was a SQLite query against the
relay's `bindings` table, which showed one activity binding, from the day the user set the thing up.

So Trellis now **states the gap and chases it**, rather than waiting for a token that may never come:

| | |
|---|---|
| **Say it** | every non-delivery logs `[push] <tok>… NOT delivered (not_bound) — …`, rate-limited per token and reason. `_relay_send` answers `0` for all of them and every caller reads `0` as "change nothing", so without this line the whole failure is silent by construction |
| **Show it** | `/health` carries `needs_claim` (tokens the relay refuses), `unadopted_starts` (started, never claimed, with age and escalation spent) and `cards` (per card: bound, and how long since its last push) |
| **Wake it** — 90 s | a silent push, asking iOS to run the app so it can hand the token over. Bypasses the 30-minute wake floor: that floor protects the silent-push budget from a per-print *picture* fetch, and this is the push that repairs an unreachable card |
| **Say it out loud** — 300 s | a banner. iOS does not deliver a silent push to an app the user force-quit and does deliver an alert, so this is the last channel there is, and its text names the one thing that repairs it |
| **Give up** — 600 s | the pending claim expires, `/sync` reports the token as an orphan and the app ends the card rather than leaving a lie on the lock screen |

Each step is spent **once per start** (`adoption_step` in `p2s.py`), so a card that is never adopted
costs one silent push and one banner — not one of each every poll.

#### Not built yet: the second channel

Everything above still ends at a token the app must deliver. Home Assistant's companion app does not
have that single point of failure: its Live Activity content arrives as an **ordinary notification**
(or over its LAN push channel) and a *notification service extension* writes the card locally, which
runs whatever state the app is in. Sprout already has the extension and a bound, working device
token — the missing piece is a `mutable-content` payload carrying the ContentState, an
`Activity.update` in the extension, and a `/register` posted from there with the token it can read
off the live activity. That closes the loop without waiting for the app to be opened.

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

The RN app (`archive/mobile/`) and the native SwiftUI app (`native/`) ship as different TestFlight builds of
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
