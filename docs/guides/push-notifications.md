# Push: Live Activities + status banners

How Sprout keeps the lock-screen print cards updating **after iOS suspends the app**, and how the
"print finished / needs attention / drying finished" banners work.

There are three ways to run this, and the first needs no Apple account at all.

```
                    ┌─────────── your server ───────────┐   ┌─ the app author's ─┐
     printer ──► Bambuddy ──► Trellis ────────────────────►  Canopy ──► APNs ──► iPhone
                                 ▲                              │
        app registers tokens ────┘        holds the signing keys ┘
                                          and decides who may push to which token
```

**Trellis** runs next to *your* Bambuddy and knows everything about your printer. **Canopy** holds
the APNs signing keys and knows nothing about printers — it never contacts your server, and stores
hashes, public keys and counters rather than payloads or raw tokens. Splitting them is what lets you
use push without an Apple developer account while the author still cannot read your data.

## Which mode am I in?

| | who signs | what you need | who can read your printer data |
|---|---|---|---|
| **Relay (default)** | the author's Canopy | nothing | nobody but you |
| **Self-hosted relay** | your Canopy | Apple account + **your own build** | nobody but you |
| **Direct** | your Trellis | Apple account + **your own build** | nobody but you |

Trellis says which on startup and at `GET /health`:

```
trellis up — relay https://canopy.sadontsev.com, 1 cards, 2 device(s)
```

In every mode, the Live Activity's content — the print name and progress — passes through whoever
signs the push. In relay mode that is the author. If a print's *name* is sensitive to you, use one
of the self-hosted modes. End-to-end encryption of the content-state is future work, not something
this already does.

---

## Mode 1 — Relay (the default, nothing to configure)

Leave `CANOPY_URL` unset. Trellis defaults to `https://canopy.sadontsev.com`, enrols itself as a
tenant on first start, and stores the credentials in `data/tenant.json`.

**Save the recovery code it prints once, at enrolment.** It is the only way to recover your tenant
if that file is lost; it is deliberately never served from an endpoint.

If the relay is gated by an invite, enrolment answers 403 and Trellis logs the variable to set
(`CANOPY_INVITE_CODE`). Push stays off until enrolment succeeds; nothing else is affected.

### How a token becomes pushable

Not by registering. A registration tells Trellis a card exists; it does **not** mean the relay can
push to it. The device proves ownership of each token with an **App Attest** claim, and Canopy binds
the token to your tenant.

`POST /register` answers with both facts, and they are not the same question:

```json
{"ok": true, "bound": true}
```

`ok` means Trellis stored the card. `bound` means the relay can actually push to that token. A
registration with `bound:false` is retried by the app; treating it as finished is what once froze a
card at its opening content for a whole print while every component reported success.

Trellis logs the unbound case rather than leaving it silent:

```
[canopy] 4005bdfc… registered WITHOUT a claim (…); it cannot be pushed to until the device claims it
[register] dry printer 2 (H2C) [native] token 4005bdfc… bound=False
```

---

## Mode 2 — Self-hosted relay

See **[self-hosting-push.md](self-hosting-push.md)**. Read the constraint at the top first: running
your own Canopy also means running your own **build** of the app, because APNs keys are team-scoped
and the topic is the bundle id, so another team's key cannot push to this app.

---

## Mode 3 — Direct (Trellis signs its own pushes)

The simplest self-hosted setup — one fewer service to run and back up. You still need your own
Apple account and your own build, for the same reason.

### 3a. Apple setup

1. In [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list), create
   an **APNs Auth Key**, download the `.p8`, note the **Key ID** and your **Team ID**.
   - Apple caps you at **2 APNs keys per team**, team-wide. Audit before revoking — an
     EAS-managed app on the same team may be using one.
2. No push *certificate* is needed; this is token auth (ES256 JWT from the `.p8`).

### 3b. Configure

```bash
# deploy/trellis/.env — leave CANOPY_URL unset/empty
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=YYYYYYYYYY
APNS_TOPIC=<your-bundle-id>.push-type.liveactivity
APNS_KEY_FILE=/path/to/your/apns_key.p8
APNS_HOST=api.sandbox.push.apple.com     # see the table below
```

Setting `APNS_KEY_ID` is what opts out of the relay. Setting it **and** `CANOPY_URL` is refused at
startup: that is ambiguous about who signs, and a deployment that guessed would fail at the first
push rather than at boot.

All three of `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_TOPIC` are required together. A partial set
used to boot and then sign every JWT with an empty issuer, which APNs answers with
`403 InvalidProviderToken` forever — indistinguishable from Apple being down.

Leave `APNS_BUNDLE_ID` **out** unless your bundle id is not `APNS_TOPIC` minus the suffix: an empty
value defeats the derived default and sends an empty alert topic.

### 3c. Sandbox vs production — the classic silent failure

APNs has two gateways and **a token from one is invalid on the other**:

| build | `aps-environment` | `APNS_HOST` |
|---|---|---|
| Xcode / local install | `development` | `api.sandbox.push.apple.com` |
| TestFlight / App Store | `production` | `api.push.apple.com` |

Wrong pairing ⇒ every push gets `400 BadDeviceToken`. Flip it when you move to TestFlight.

(Canopy handles this for you in relay mode: it records the environment each token was claimed under
and retries the other gateway on `BadDeviceToken`, swapping host *and* signing key together.)

---

## Deploying Trellis

```bash
cp -r deploy/trellis <deploy-dir>/trellis && cd <deploy-dir>/trellis
cp .env.example .env            # BAMBUDDY_API_KEY is the only required value in relay mode
docker compose up -d --build
curl -s localhost:8911/health
```

Copy **every** `*.py` the Dockerfile COPYs. A module you forget fails at *import*, after the build
reports success, and the container restarts in a loop with `docker logs` the only place it says so.
Adding a module means editing the Dockerfile's COPY line too; that has bitten this service.

`docker-compose.yml` also mounts Bambuddy's data volume read-only, for MakerWorld **collections**.
It is declared `external`, so compose refuses to start if the name is wrong — loud, not silent:

```bash
docker inspect bambuddy --format '{{range .Mounts}}{{.Name}}{{end}}'
# set BAMBUDDY_VOLUME=<that name> in .env if yours differs
```

Expose 8911 to the phone the same way you exposed Bambuddy.

---

## What Trellis does

- **Live-Activity cards** — polls each registered printer's `/status` every ~5 s, pushes the
  ContentState on meaningful change (throttled), and **ends** the card on complete/error/idle. Dead
  tokens (400/410) are dropped.
- **Status banners** — need ≥1 registered device token; the poll then covers the whole fleet.
  Edge-triggered, so the first observation after a restart is silent:
  - `live → complete` ⇒ "✅ *printer* — print finished"
  - `→ error` ⇒ "⚠️ *printer* — needs attention"
  - AMS `dry_time` running out (≤15 min → 0) ⇒ "💨 *printer* — drying finished". A manual stop
    (large remaining → 0) stays deliberately silent.
- **Reconciliation** — the app reports every card it can still see (`POST /sync`). A card that
  vanished without a dismissal is a *death*: Trellis drops the registration and grants that device
  **one** replacement, so a card lost mid-print is push-to-started again. A card the user
  deliberately swiped away arrives as `/unregister` instead and is **not** replaced. Only clients
  that report those two separately get the replacement grant.
- **Restart-safe** — registrations, tokens and edge state persist in `data/registrations.json`, so
  a redeploy mid-print does not swallow the finish banner.

---

## Verifying

```bash
curl -s localhost:8911/health          # devices ≥1, registrations ≥1 while printing
docker logs bambu-trellis | grep -E "\[update\]|\[p2s\]|bound="
```

`[update] printer 2 prio 5 -> 200` is a delivered push. **`-> 0` is not delivered** — it means the
relay refused or could not be reached, and the card is frozen at whatever it last showed.

---

## Troubleshooting

| symptom | cause |
|---|---|
| `[update] … -> 0` on every tick | the token is not bound. Look for `bound=False` at registration; open the app so it re-claims |
| `[register] … bound=False` | the device's App Attest claim did not build. Usually transient; the app retries on its 30 s backoff **while in the foreground** |
| enrolment logs 403 | the relay gates enrolment — set `CANOPY_INVITE_CODE`, or point `CANOPY_URL` at your own |
| `kind_mismatch` from the relay | this token is already bound under a different kind. Reset pairing (`DELETE /v1/bindings`) or ask the operator to unbind |
| `reattest_required` | the relay holds no key for this install — usually a Canopy restore predating it. The app resolves this itself on the next claim |
| Live Activity vanished after an app update | installing a build **terminates** running Live Activities. `/sync` reports the death and a replacement is pushed within ~45 s |
| app asks for the server URL again, mid-session | fixed. The config keychain item was `WhenUnlocked`, so a background wake with the phone locked read `nil` and fell back to onboarding. Credentials were never deleted |
| `403 InvalidProviderToken` (direct mode) | wrong Key ID / Team ID, a mangled `.p8`, or a blank `APNS_TEAM_ID` |
| `400 BadDeviceToken` on real tokens (direct mode) | sandbox/production mismatch — see the table above |
| `400 TopicDisallowed` (direct mode) | `APNS_TOPIC` does not match the bundle id (+ `.push-type.liveactivity` for cards) |
| cards start but freeze when the app closes | the app never registered the token — check reachability from the phone and `/health` `registrations` |
| banners never fire | no device token (`devices: 0`) — permission denied, or `/register-device` unreachable |
