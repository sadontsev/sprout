# Push notifications: the default, and how to run your own

Live Activities and alert banners need Apple Push Notification service, and APNs will only accept a
push signed by a key belonging to **the team that owns the app's bundle id**. That single fact
determines everything below.

## The default: nothing to do

Trellis defaults to the push relay run by this app's author:

```
https://canopy.sadontsev.com
```

That hostname lives in `deploy/trellis/app.py` as `DEFAULT_CANOPY_URL` and needs no configuration.
Install the App Store build, run Trellis next to your Bambuddy, and push works.

**It is a public address, not a secret.** Canopy holds APNs signing keys and per-device bindings and
nothing else. Every endpoint requires either a tenant bearer or a claim signed by Apple App Attest,
so knowing the URL grants nothing.

### What the author can and cannot see

Canopy is deliberately built so the person running it cannot read your data:

| | |
|---|---|
| **Can see** | that a device exists, how many cards it holds, when a push was sent, and the push payload itself |
| **Cannot see** | your printer, your files, your camera, your Bambu account, or anything on your Bambuddy — it never talks to your server |

The payload caveat is real and stated rather than hidden: a Live Activity's content-state travels
through Canopy in the clear, because APNs requires the relay to build the request. That includes the
print's name and progress. Encrypting it end-to-end is future work (§14 of the design spec). If a
print's *name* is sensitive to you, self-host.

## Self-hosting Canopy

You can, and here is the constraint to understand **before** you start:

> Running your own Canopy also means running your own **build** of the app, signed by your own Apple
> Developer team, with your own bundle id.

APNs keys are team-scoped and the Live Activity topic is the bundle id, so a key issued by your team
cannot push to a build signed by another team — APNs refuses it. Pointing `CANOPY_URL` at your own
relay while running the App Store build gets you a relay that authenticates you correctly and then
cannot deliver anything. There is no configuration that works around this; it is Apple's model.

So self-hosting the push path is worth it if you are already building the app yourself, and is not
otherwise.

### What you need

- An Apple Developer account (paid), and the app rebuilt under your own bundle id
- An **APNs auth key** (`.p8`) from Certificates, Identifiers & Profiles → Keys, with *Apple Push
  Notification service* enabled
- Apple's **App Attest root CA** certificate
- A host reachable over HTTPS by your phone
- Optional: a **DeviceCheck** key, if you want the fraud-assessment metric (see `canopy/README.md`)

### Bring it up

```bash
git clone <this repo> && cd canopy
cp .env.example .env    # then edit
docker compose up -d --build
```

`canopy/docker-compose.yml` documents every variable inline. The ones that matter:

| Variable | What it is |
|---|---|
| `CANOPY_BUNDLE_ID` | your bundle id — must match the build you install |
| `CANOPY_TEAM_ID` | your 10-character team id |
| `CANOPY_APNS_KEY_ID` | the key id of your `.p8` |
| `CANOPY_APPLE_ROOT_CA` | path to Apple's App Attest root certificate |
| `CANOPY_INVITE_CODE` | optional; gates enrolment. Set it if the relay is publicly reachable |
| `CANOPY_ALLOW_DEVELOPMENT_ATTEST` | `1` while you install builds from Xcode; turn **off** once only TestFlight and App Store builds talk to it |

Then point Trellis at it:

```bash
# deploy/trellis/.env
CANOPY_URL=https://canopy.example.com
CANOPY_INVITE_CODE=<if you set one>
```

Setting `CANOPY_URL` **and** the `APNS_*` variables together is refused at startup — that is
ambiguous about which key is expected to sign, and a deployment that guessed would fail at the first
push instead of at boot.

### Back it up

`canopy/data/` holds the bindings and attested keys. A device **cannot re-attest on demand**, so
losing this costs every install a re-attestation round it has no way to know it needs.
`canopy/scripts-deploy.sh` takes a WAL-correct backup before every deploy; if you deploy some other
way, take one yourself.

## The third option: sign locally, no relay at all

If you build the app yourself and would rather not run a separate service, Trellis can sign its own
pushes. Set the `APNS_*` variables and leave `CANOPY_URL` empty:

```bash
# deploy/trellis/.env
APNS_KEY_ID=ABCD123456
APNS_TEAM_ID=YOURTEAMID
APNS_TOPIC=com.example.yourapp.push-type.liveactivity
APNS_HOST=api.push.apple.com     # api.sandbox.push.apple.com for Xcode builds
```

and mount your key at `/keys/apns_key.p8`.

This is the simplest self-hosted setup — one fewer service, one fewer thing to back up. What you give
up is App Attest: nothing verifies that a claim came from a genuine build, because in this mode
there is no relay to verify against and your Trellis is the only thing that can push to your own
device anyway.

## Which am I running?

Trellis says so on startup:

```
trellis up — relay https://canopy.sadontsev.com, 1 cards, 2 device(s)
```

and reports it at `GET /health`.
