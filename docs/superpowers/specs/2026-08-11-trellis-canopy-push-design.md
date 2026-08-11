# Trellis + Canopy: multi-tenant push for App Store distribution

**Status:** approved design, not yet implemented
**Date:** 2026-08-11
**Revision:** 3 — revised after two adversarial review rounds. Revision 1's lease-expiry
rebind rule was a real cross-user push path. Revision 2 replaced it with App Attest plus a
dormancy rule, but shipped an incomplete attestation procedure, a garbage collector that
deleted the evidence the dormancy rule depends on, and a claim protocol that could not be
retried. §5 and §6 are the sections that changed most.

## 1. Context and goals

Today the app is single-user: la-push runs next to the owner's Bambuddy, holds the owner's
APNs `.p8` auth key, and pushes Live Activities and alert banners directly to APNs. A key
authorises push for **every install of every app it covers**, which is why the current
design cannot be shared: `docs/guides/push-notifications.md` tells other people to
self-host with their *own* key, and that only works for their own TestFlight builds, never
for an App Store install signed by the owner's team.

(Apple's key model has moved on from what `push-notifications.md` records. There are now
team-scoped keys — two per environment, covering every app on the team — and topic-specific
keys tied to named bundle ids, with a much higher cap. Canopy should use a **topic-specific
key scoped to `com.mvks5.bambu`**, so a Canopy compromise cannot reach any other app on the
team, and so rotation is cheap. Because modern keys are environment-scoped, Canopy holds
**one key per APNs environment**; see §6.)

The goal: ship the native app (Sprout) on the App Store so strangers can install it, while
**each user self-hosts their own Bambuddy + companion service**, and:

- the owner (operator of the shared infrastructure) sees the minimum data required to
  operate — never printer libraries, cameras, credentials, or Bambuddy access;
- no user can push notifications to another user's devices, even holding a stolen push
  token;
- a user whose server dies and is rebuilt from scratch recovers push with zero manual
  unbinding, support tickets, or waiting;
- users who opt out of push entirely keep everything else working (the existing
  `laPushUrl` vs `resolvePushUrl` split is preserved).

## 2. Naming

The companion service outgrew its name — it serves MakerWorld collections as well as push,
and this design adds pairing forwarding. Renames:

- **la-push → Trellis** — the user-side companion (`deploy/la-push/` → `deploy/trellis/`,
  container `bambu-trellis`, port 8911 unchanged). A trellis is the structure in your own
  garden that supports a growing plant (the app is Sprout).
- **Canopy** — the new, owner-hosted APNs relay (top-level `canopy/` in the monorepo; it
  does not run on the home server). The shared cover above everyone's gardens.

The metaphor encodes the trust boundary: yours-in-your-garden vs. shared-above-all.

## 3. Architecture overview

```
 user's garden (self-hosted)                        owner-hosted           Apple
┌────────────────────────────────────────────┐    ┌─────────────┐
│ printer ── Bambuddy ◄── Trellis (Python)   │    │ Canopy (Go) │
│                          polls status,     ├───►│ · .p8 keys  ├──► APNs ──► phone
│                          classifies,       │    │ · bindings  │
│                          builds payloads,  │    │ · attest    │
│                          MakerWorld colls  │    │ · limits    │
└──────────────────▲─────────────────────────┘    └─────────────┘
                   │ /register* (+ pairing secret + App Attest assertion)
                 phone (Sprout, App Store build)
```

Invariants:

1. **Canopy never learns what a Live Activity is.** All ActivityKit intelligence —
   `classify()`, `meaningful_change()`, `MIN_UPDATE_S` spacing, priority 5-vs-10 choice,
   push-to-start arming, dismissal reconcile, the expo-vs-native envelope split — stays in
   Trellis. Canopy is a signing gate that validates *who may push to which token* and
   forwards opaque payloads.
2. **The phone never talks to Canopy.** Its only servers are its own Trellis and Bambuddy.
   Attestation challenges and claims are relayed through Trellis, which cannot forge or
   alter them (§5).
3. **The owner's infrastructure never talks to any user's Bambuddy.** Canopy accepts
   inbound requests only.
4. **A tenant can never choose an APNs topic.** Canopy derives the topic from `push_type`
   against a hardcoded two-entry table; those are the only strings it will ever sign for.
5. **Nothing Apple-specific reaches Trellis in relay mode.** Key ids, team id, topics, and
   APNs hosts live only in Canopy — so the owner can rotate keys at any time with zero
   action from any user or tenant.
6. **Ownership of a push token is anchored to the device, not to a server.** Servers are
   the disposable party in a self-hosting setup; the phone is the durable one.
7. **Two questions never share one field or one predicate.** This design has four pairs
   that read as synonyms and are not: APNs environment vs App Attest environment; `not_bound`
   vs `not_owner`; a Canopy HTTP status vs an APNs status; authentication at Trellis vs
   binding authority at Canopy. Each is kept separate deliberately, per the repo's
   recurring-bug rule.

## 4. Threat model

Assets: the APNs keys (each signs pushes for every install of the app), users' push tokens,
users' print metadata (printer names, filenames — they transit push payloads), Canopy's
tenant credentials.

| Adversary / scenario | Outcome under this design |
|---|---|
| Attacker steals a push token (victim's logs, LAN sniffing, a stale `registrations.json` backup) | Cannot bind it. Every claim requires an App Attest assertion from a genuine Sprout install, signed over the exact claim contents and verified against a stored public key (§6). A `curl`-wielding attacker holding a tenant credential cannot produce one. **Residual:** a jailbroken device running a hooked copy of the genuine app can still assert over an arbitrary token; re-signing under another team fails the App ID check. Bounded by the per-key tenant cap and operator alerting (§6), and by Apple's fraud-assessment metric once enabled (§14). |
| Attacker waits out a lease and re-claims a live token | Closed. Leases renew on **successful push delivery** as well as on claims, so a token anyone is actively delivering to never becomes claimable. The rebind paths require either the tenant that already holds the binding (which already has full push authority, so it grants nothing new) or 90 days with no delivery *and* no claim. Both preserve the prior anchors as elder for 90 days, and binding rows outlive the dormancy threshold by design (§6) so that eviction path is actually reachable. |
| Attacker enrolls tenants and probes tokens | Tokens are 32-byte APNs-generated values; guessing is infeasible. Cheap checks run before expensive ones (§6), so a failed claim costs no X.509 work. Per-IP and per-tenant limits, per-token-hash failed-claim backoff, a bounded tenant count, and an auto-arming invite code cap the probe rate. Attestation verification has its own work budget so claim floods cannot starve `/v1/push`. |
| A user's Trellis box is fully compromised | The attacker gets that user's tokens, tenant credential, and observes pairing secrets and assertions in transit. They can push junk **to that user's own devices only**, and can replay a captured claim verbatim — but cannot forge a different one, because the assertion is signed over the claim contents by a Secure Enclave key. If they use a hooked genuine app to rotate the victim out, the outgoing anchors are retained as elder (§5), so the victim's next claim evicts them within the elder window. Beyond that window, the operator unbind (§14, in scope) is the recourse. |
| A tenant floods pushes (hostile or broken) | Per-token, per-tenant, and per-IP limits. Shedding is **tenant-scoped first**: tenants with high 4xx/410 ratios are throttled individually; the global breaker is a last resort, so one abuser cannot deny push to everyone. |
| Canopy itself is compromised | The attacker holds the APNs keys → can push arbitrary content to all installs until the keys are revoked and rotated. Scoping the keys to `com.mvks5.bambu` (§1) keeps the blast radius inside this one app. Mitigations: minimal surface (static Go binary, three dependencies), no payloads or raw tokens at rest, TLS via reverse proxy, monitoring, WAL plus daily off-box backups, and rotation that needs no tenant action (invariant 5). |
| Someone who knows a public Trellis URL registers their own token | Rejected by Trellis's existing `X-API-Key` gate, delegated to that user's Bambuddy (`app.py:753-777`) and **unchanged** by this design. The pairing secret is binding authority at Canopy, *not* authentication at Trellis (§9). Trellis's `/health` gains the same gate for anything beyond liveness (§9). |
| The owner snoops on users | Sees per-push: raw token and payload, in memory, for one HTTPS forward. Stores only hashes, public keys, and counters (§8). Cannot reach any user's Bambuddy. A documented trust statement, not cryptography — see §7 for what is and is not encryptable, and §14 for the deferred option. |

## 5. Device identity, pairing, and binding

Ownership rests on **two anchors held by the phone**, each covering the other's loss case:

- **An App Attest key** (`DCAppAttestService`), generated once, private half sealed in the
  Secure Enclave and non-exportable. Proves "a genuine Sprout install on a real Apple
  device made this exact request." Apple documents that these keys do not survive app
  reinstallation, device migration, or restore from backup.
- **A pairing secret**, 32 random bytes in the phone's Keychain. Survives app reinstall in
  current iOS behaviour (an undocumented artefact, not an API contract — the design must not
  depend on it alone) and survives direct device-to-device migration, but not restore from
  backup, since the item is `ThisDeviceOnly`.

Neither anchor is held durably by any server. Trellis relays claims and **cannot alter
them**: the assertion signs the claim's contents, so a compromised Trellis can replay a
claim but never forge a different one.

### Claim protocol

A claim attempt is an **indivisible unit**: obtain a challenge, produce an assertion over it,
POST. It is not replayable — the nonce is consumed and the Secure Enclave counter advances —
so **every retry acquires a fresh challenge and generates a fresh assertion**. Claims are not
idempotent in the HTTP sense; what is true is that repeated attempts converge on the same
binding state.

1. The app asks its Trellis for a challenge; Trellis calls Canopy `POST /v1/challenges`
   (tenant-authed) and returns the opaque nonce. A challenge is consumed **on success**, not
   on presentation, so Apple's documented `DCError.serverUnavailable` retry — same key, same
   client-data hash — still validates. TTL is 15 minutes for attestations (Apple asks that
   attestation retries reuse identical inputs, to preserve the device's risk metric) and
   120 seconds for assertions.
2. The app builds `client_data`, a JSON object over
   `{challenge, token, pairing_secret, previous_secret?, kind, apns_environment}`, and
   produces either an **attestation** (first use of a new attest key) or an **assertion**
   (every later claim) over `SHA-256(client_data)`.
3. The app POSTs its normal registration to Trellis (`/register`, `/register-start`,
   `/register-device`) with the new fields; Trellis forwards them to Canopy `/v1/claims`.
4. Canopy verifies the attestation or assertion (§6) against **the exact `client_data` bytes
   the app sent** — transmitted base64 in the claim, never re-serialised server-side — and
   then checks that the fields parsed out of those bytes equal the corresponding top-level
   claim fields. Re-serialising would make the security check depend on `JSONEncoder` and
   `encoding/json` agreeing byte-for-byte forever; WebAuthn transmits `clientDataJSON`
   verbatim for the same reason. `client_data` is UTF-8 JSON, snake_case keys sorted
   lexicographically, no whitespace, absent optionals omitted rather than null, no HTML
   escaping — pinned by a golden fixture shared between the Go and XCTest suites (§12), with
   unknown extra fields tolerated on parse.

### Binding state machine

Binding row: `{token_hash, kind, apns_environment, tenant, attest_key_id, pairing_hash,
elder_attest_key_id, elder_pairing_hash, elder_until, lease_expiry, last_delivery_at,
released_at, created_at}`. Attest keys live in their **own table** with a lifetime
independent of any binding (§6) — they must outlive the bindings they were used to claim.

Every row below additionally requires a verified attestation or assertion; a claim without
one is `403 attestation_required` and never reaches the state machine. "Elder" anchors count
as matching only while `now < elder_until`.

| State + event | Rule |
|---|---|
| UNBOUND + claim | Bind: store both anchors, tenant, kind, `apns_environment`; `lease_expiry = now + lease(kind)`. |
| BOUND + claim, **attest key matches** (current or elder) | Accept (primary path). Re-point to the claiming tenant, refresh the pairing hash from the claim, renew lease, clear elder. |
| BOUND + claim, attest key differs but **pairing secret matches** (current or elder) | Accept — the app-reinstall case, where the attest key is legitimately lost. Store the new attest key, re-point tenant, renew lease, clear elder. |
| BOUND + claim carrying `previous_secret` matching the stored pairing hash | Rotation. Copy the outgoing anchors to `elder_*` with `elder_until = now + 90d`, then replace the pairing hash, re-point tenant, renew lease. |
| BOUND + claim, neither anchor matches, but the claim carries a **fresh attestation** and comes **from the tenant that currently holds the binding** | Rebind, retaining outgoing anchors as elder. Safe by construction: that tenant already holds full push authority over this token and can release it outright, so this grants nothing new. This is what rescues a phone that lost *both* anchors (reinstall where the Keychain did not survive) without weakening anything. |
| BOUND + claim, neither anchor matches, token **dormant** (no successful delivery *and* no claim for 90 d) | Rebind, retaining outgoing anchors as elder for 90 d. Reachable because rows outlive dormancy (§6). |
| BOUND + claim, none of the above | `403 pairing_mismatch`, counted per token-hash for backoff and operator alerting (§6). |
| BOUND + push from the bound tenant | Allowed. **A successful APNs delivery renews the lease** (`last_delivery_at`), so an actively-used token never drifts toward dormancy. |
| BOUND + push from another tenant | `403 not_owner` — authority was taken; this is the suspension condition (§9). |
| UNBOUND + push | `403 not_bound` — routine housekeeping (a released or expired row), **not** a suspension condition; it means "re-claim", not "you were evicted". |
| APNs answers 410 / 400 `BadDeviceToken` after the §6 gateway retry | Delete the row — the token is genuinely dead. |
| `POST /v1/bindings/{token_hash}/release` from the bound tenant | Set `released_at`, `lease_expiry = now` — the row stops counting against the cap but retains its anchors through the grace window, so a released token is not reopened to first-claim binding. |

A single attest key legitimately covers many tokens for one device across a household
rebuild, but **the same key holding live bindings across more than three tenants** is the
signature of the hooked-device attack: Canopy caps it and alerts the operator.

What each anchor buys, walked through the real lifecycle events:

| Event | Attest key | Pairing secret | APNs tokens | Outcome |
|---|---|---|---|---|
| Trellis rebuilt or migrated | kept | kept | kept | Claim matches; binding re-points to the new tenant. **No user action.** |
| App deleted and reinstalled | lost | usually kept | usually new | Pairing-secret path accepts; if the Keychain did *not* survive, the same-tenant rebind row does. |
| Phone restored from backup onto new hardware | lost | lost | **new** | New tokens bind fresh; old tokens 410 and free themselves. |
| Direct device-to-device migration | lost | kept | new | Pairing-secret path accepts on the new device. |
| Trellis compromised, attacker replays claims | intact on phone | observed by attacker | kept | Attacker cannot forge a different claim; the real phone's next claim wins. |
| Trellis compromised, attacker rotates via a hooked app | intact on phone | observed | kept | Outgoing anchors retained as elder; the victim's next claim evicts the attacker inside the 90 d elder window. Past it, operator unbind. |

Per-activity Live Activity tokens need no special casing for *ownership* — they are born and
die with each print card. They need it for *lifetime*; see §6.

## 6. Canopy specification

**Language: Go.** Canopy is the one internet-facing service holding the keys, and it is new
code (~900 lines with attestation verification). Go gives a static binary with a stdlib HTTP
server, transparent HTTP/2 to APNs via `net/http`, ES256 over `crypto/ecdsa` (no JWT
library), X.509 chain verification in `crypto/x509`, and table-driven tests that fit the
binding state machine exactly. Third-party surface: `modernc.org/sqlite` (pure Go),
`golang.org/x/time/rate`, and `github.com/fxamacker/cbor/v2` for attestation objects.
Deployment: `GOOS=linux go build`, scp, systemd, Caddy for TLS, SQLite in WAL mode with a
daily off-box backup. (Trellis stays Python: its logic is proven and measured, and the
Docker container is the distribution unit, so the language is invisible to self-hosters.)

**Two APNs keys.** Modern APNs keys are environment-scoped, so Canopy is configured with
`CANOPY_APNS_KEY_SANDBOX` and `CANOPY_APNS_KEY_PRODUCTION` (plus their key ids); a legacy
universal key may be pointed at both. Both must be present at startup or Canopy refuses to
run. The gateway retry below swaps **host and signing key together** — signing a production
JWT against the sandbox host returns `403 InvalidProviderToken`, not `BadDeviceToken`, and
would never converge.

Endpoints (JSON over HTTPS; tenant auth is `Authorization: Bearer <tenant_id>.<tenant_secret>`):

- `POST /v1/enroll` `{invite_code?}` → `201 {tenant_id, tenant_secret}`. Rate-limited per IP
  (20/day, burst 5 — a first-time self-hoster running `docker compose down -v` a few times
  must not lock themselves out) and globally capped by tenant count. `invite_code` is
  required when `CANOPY_INVITE_CODE` is set, and **auto-arms** when the enrollment rate or
  the failed-claim ratio crosses configured thresholds, so the abuse valve is not purely
  manual. Secrets are 32 random bytes stored as SHA-256.
- `POST /v1/challenges` `{purpose: "attestation"|"assertion"}` → `201 {challenge,
  expires_at}`. Tenant-authed, rate-limited per tenant and per IP. Single-use **on success**;
  TTL 15 min for attestation, 120 s for assertion.
- `POST /v1/claims` `{token, client_data, pairing_secret, previous_secret?, kind,
  apns_environment, attest_key_id, attestation? | assertion?}` → `204`, or `403
  attestation_required | attestation_invalid | reattest_required | pairing_mismatch`, or
  `429 binding_limit`. Implements §5. **Not idempotent** — see the claim protocol.
  `reattest_required` is a distinct code meaning "Canopy does not know this key; generate a
  new App Attest key and send an attestation, not an assertion", which is what makes a
  Canopy restore-from-backup gap recoverable rather than indistinguishable from an attack.

  *Attestation verification* follows Apple's published procedure in full, in order:
  (1) `fmt` is `apple-appattest` and the CBOR has the expected `attStmt {x5c, receipt}` and
  `authData` shape; (2) `x5c` = [credCert, intermediate] chains to the **pinned Apple App
  Attest Root CA**, with every certificate inside its validity window against an injectable
  clock; (3) `clientDataHash = SHA-256(client_data)`; (4) `nonce = SHA-256(authData ||
  clientDataHash)`; (5) **decode the credCert extension with OID `1.2.840.113635.100.8.2` as
  a DER ASN.1 SEQUENCE, extract its single OCTET STRING, and require it to equal `nonce`** —
  this comparison is the only thing tying Apple's signed certificate to our challenge, and
  omitting it (as revision 2 did) makes the whole check bypassable by replaying any
  well-formed attestation; (6) `SHA-256` of the credCert public key in uncompressed EC point
  form equals the base64url-decoded `attest_key_id`; (7) `authData[0..32] == SHA-256("<APP
  ID>")` where APP ID is `<TEAM_ID>.com.mvks5.bambu`; (8) counter is 0; (9) `aaguid` compared
  as **exact 16 bytes** — `appattestdevelop`, or `appattest` followed by seven `0x00` bytes
  (a prefix comparison would also match hostile values); (10) `authData` `credentialId`
  equals the key identifier. Then store the public key, the counter, the observed
  **attest environment** (from the aaguid), and **the receipt** — receipts can only be
  captured at attestation time and are the input to Apple's fraud-assessment metric (§14).

  *Assertion verification*: (1) `clientDataHash = SHA-256(client_data)`;
  (2) `nonce = SHA-256(authenticatorData || clientDataHash)`; (3) **verify the assertion
  signature over `nonce` with the stored P-256 public key** — revision 2 omitted this, which
  left every other check running on attacker-supplied plaintext; (4) `authenticatorData[0..32]
  == SHA-256(APP ID)` (an assertion's `authenticatorData` is 37 bytes and carries no aaguid
  or credentialId, so the aaguid rule is attestation-only); (5) counter strictly greater than
  the stored value, then persist it; (6) the challenge inside `client_data` is issued and
  unconsumed.

  **The App Attest environment is not the APNs environment.** They are different Apple
  concepts — the first comes from the `com.apple.developer.devicecheck.appattest-environment`
  entitlement (and is ignored after distribution), the second from `aps-environment`. Apple
  explicitly sanctions a development build attesting against production servers. Canopy
  therefore records `attest_environment` **per attest key, immutably, from the observed
  aaguid**, requires every later attestation for that key to match it, and never derives it
  from `apns_environment`. A production deployment may refuse `appattestdevelop` outright by
  config. Sandbox receipts redeem at `data-development.appattest.apple.com`, production ones
  at the production host.

- `POST /v1/push` `{token, push_type: "liveactivity"|"alert", priority: 5|10, payload,
  idempotency_key?}` → `200 {apns_status, apns_reason?}`, or `403 not_bound|not_owner`, or
  `429`. Canopy verifies the caller is the bound tenant; clamps priority; derives
  `apns-topic` and `apns-push-type` from `push_type` (`liveactivity` →
  `com.mvks5.bambu.push-type.liveactivity`, `alert` → `com.mvks5.bambu`; hardcoded,
  invariant 4); caps payload at 4096 bytes; signs with the key for the binding's
  `apns_environment`; renews the lease on success; and returns the APNs status and reason
  **verbatim**. Payload contents (`event`, `content-state`, `dismissal-date`, `stale-date`,
  the `alert` block) are opaque passthrough.
- `POST /v1/bindings/{token_hash}/release` → `204`. Bound tenant only. Release, not delete
  (§5), so a still-live token is never reopened to first-claim binding.
- `GET /v1/health` → `{ok, version}`. Deliberately bare — it must reveal nothing about
  tenants.

**Canopy statuses are not APNs statuses.** The relay backend's return type is explicitly two
fields, `(transport_outcome, apns_status | None)`, and Trellis's token hygiene consumes only
the second. Mapping: Canopy `200` → use `apns_status`; `403` → the suspension/re-claim paths
in §9, never token hygiene; `429`, `5xx`, timeout → retry, touch no registration; any other
`4xx` → log and drop this push, keep the registration. Without this, a Canopy-side `400`
(malformed body, oversized payload) reads as APNs `400 BadDeviceToken` and Trellis deletes a
healthy registration. Note also that `_apns_send` passes priority as a string today
(`app.py:299`) while the wire schema is an int — the adapter converts.

**Environment self-correction.** On `400 BadDeviceToken`, Canopy retries once on the other
gateway with that gateway's key. If the retry succeeds it corrects the stored
`apns_environment` and logs it. `apns_environment` is **never overwritten by a later claim**
— otherwise the phone, still deriving the same wrong value, would silently revert the
correction and restore the death-loop.

**Idempotency and retries.** Live Activity *updates* are never retried — the next poll
supersedes them. Push-to-start and alert banners retry at most once on transport timeout,
carrying a client-generated `idempotency_key` that Canopy dedupes for 5 minutes, so a
timeout that actually delivered cannot double-alert. Claim *attempts* retry with exponential
backoff (1 s doubling to a 5 min cap), each with a fresh challenge and assertion.

**Rate limits and work ordering** (env-tunable; a backstop, not shaping — Trellis already
shapes at `MIN_UPDATE_S = 30`):

- per token: sustained 1 push/10 s, burst 5;
- per tenant: 120 pushes/min, 60 claims/min, 60 challenges/min, and the binding cap below;
- per source IP: claims and pushes per minute, not only enrollments per day;
- per token-hash: failed-claim counter with exponential backoff, plus an operator alert when
  one token accumulates repeated `pairing_mismatch` — the signature of a targeted takeover;
- **cheap checks first**: challenge validity, per-token backoff, and rate limits are all
  evaluated *before* any X.509 or signature work, and attestation verification runs on its
  own bounded worker pool so a claim flood cannot starve `/v1/push`;
- tenant-scoped shedding first; the global breaker is a last resort.

**Binding lifetime, release, and garbage collection.** Leases differ by `kind`, which is
exactly why the field exists on claims. Crucially, **the retention horizon must exceed the
dormancy threshold**, or the dormancy and elder-eviction rules in §5 can never run — the bug
revision 2 shipped:

| kind | lease | hard delete | notes |
|---|---|---|---|
| `activity` | 72 h, renewed on delivery | `lease_expiry + 7 d` | A card lives hours. |
| `start`, `device` | 30 d, renewed on delivery or claim | `lease_expiry + 90 d` | Total inactivity before deletion is 120 d, comfortably past the 90 d dormancy threshold, so a returning device still finds its elder anchors. |

Trellis calls `release` when it drops a registration — after an end push, on a 400/410 drop,
and on a `/sync` or dismissal disown — which is what keeps completed cards from lingering
(Trellis stops pushing while the activity is still alive, so APNs answers 200 and a 410 never
arrives; `app.py:353-354`, `582-585`). **"Live binding" means a row whose lease has not
expired**, and only those count against the per-tenant cap of 500 (two phones × (start +
device) plus several prints and concurrent drying cards per day, each held 72 h, leaves an
order of magnitude of headroom). An over-cap claim returns `429 binding_limit`, which Trellis
surfaces in `/health`.

**Storage:** SQLite (WAL). `tenants` (id, secret_hash, created_at, last_seen); `bindings` (as
in §5); **`attest_keys` (key_id, public_key, counter, attest_environment, receipt, first_seen,
last_seen)** — never garbage-collected with bindings, because assertions must verify long
after any particular card is gone; `challenges` (nonce_hash, tenant, purpose, expires_at);
plus in-memory rate buckets. Raw tokens arrive per-request and die with it.

**Bindings and attest keys are durable state, not a cache.** WAL plus a daily off-box backup,
and restore-from-backup is the recovery path (§11). The design does **not** assume clients
can reconstruct them: a passive user's phone may not register for weeks.

**Logs:** tenant id, token-hash prefix, status, latency. Never payloads, never raw tokens,
never per-request IPs.

## 7. Live Activity flow, end to end (relay mode)

1. **App launch** — `pushToStartTokenUpdates` fires → the app obtains a challenge, builds an
   assertion, and POSTs `/register-start` to its own Trellis; Trellis forwards the claim to
   Canopy. Likewise `/register-device` for the alert-banner token. Both go through the
   persisted pending-claim queue in §10, so a failure is retried rather than lost.
2. **Print starts** — Trellis's poll loop sees a live state with no card and builds the
   push-to-start payload itself (`event: start`, attributes, and the mandatory `alert`
   block — the "APNs 200s then silently discards without it" lesson stays encoded in
   Trellis). `POST canopy /v1/push {push_type: liveactivity, priority: 10, payload}`.
3. **Card appears** — ActivityKit mints the per-activity update token; the app's
   `pushTokenUpdates` fires → `/register` with a fresh assertion → claim → bound.
4. **Updates** — on meaningful change Trellis builds the ContentState envelope (the `expo`
   versus `native` shape stays its concern) and pushes via Canopy at the priority it already
   chooses. End pushes carry `dismissal-date`, passthrough, followed by `release`.
5. **Feedback** — APNs status verbatim through the two-field result (§6); on 400/410 Trellis
   drops its registration exactly as today.
6. **Dismissal reconcile** — phone ↔ Trellis only; Canopy uninvolved. This is a **native-app
   gap that must be closed before relay ships**: the RN app posts `/sync`, but the native app
   only records a swipe locally (`cardVanished` → `dismissed.insert`), so Trellis would keep
   a registration for a card the user swiped away, refuse to start a replacement
   (`_remote_start` gates on `key in _regs`, `app.py:441`), and push into the void at APNs
   200 for the rest of the print — the exact deadlock `app.py:848-860` documents as "how the
   lock screen ended up empty mid-print". Sprout must call the token-scoped `/unregister`
   (§9) on `cardVanished`, and Trellis must `release` that binding.

**Encryption, stated accurately.** The APNs *envelope* cannot be encrypted: `event`,
`dismissal-date`, `stale-date`, the push-to-start `attributes`, and the mandatory start
`alert` title and body are interpreted by iOS itself, and Apple provides no NSE-style
mutation hook for `apns-push-type: liveactivity`. The *content state* is different —
ActivityKit only decodes it; the widget renders it with code, so a ciphertext blob decrypted
at render time with a key shared via the existing App Group is technically possible. We do
**not** do this in v1 (key distribution, payload inflation, pre-first-unlock render edges),
which makes it a deliberate deferral (§14), not a physical impossibility. Printer and file
names therefore transit Canopy in plaintext under the no-persistence rules of §6 and §8.

Trellis also sets `stale-date` on card pushes (`07-realtime.md:898`) so a dead feed visibly
stales the card instead of lying.

## 8. Privacy posture (what the owner can and cannot see)

| Data | Canopy at rest | Canopy in transit | Notes |
|---|---|---|---|
| Push tokens | SHA-256 only | raw, per-request | needed to call APNs |
| Pairing secrets | SHA-256 only | raw, per-claim | durable home is the phone's Keychain only |
| App Attest public keys, counters, receipts | stored in `attest_keys` | — | private half never leaves the Secure Enclave; the receipt enables Apple's fraud metric (§14) |
| Push payloads (names, progress, temps) | **never** | plaintext, one forward | envelope is Apple's design; content-state encryption deferred (§7) |
| Tenant credentials | SHA-256 only | bearer over TLS | |
| User Bambuddy URLs / API keys / cameras / libraries | **never** | **never** | Canopy accepts inbound only |
| IP addresses | never (in-memory rate buckets only) | inherent to HTTP | not logged per-request |

Trellis-side: pairing secrets, `client_data`, and assertions transit but are never persisted.

## 9. Trellis changes

- **Rename** per §2. `docs/guides/push-notifications.md`, `deploy/README.md`, repo-root
  `CLAUDE.md`, and `docs/native-rewrite/` references updated. Collections, cooldown, p2s, and
  classify logic: untouched.
- **Two-backend APNs interface**: `DIRECT` (today's `.p8` env set — preserved for the owner
  and for self-signers on their own Apple team) and `RELAY` (`CANOPY_URL`). Exactly one must
  be configured; both or neither fails at startup. The backend returns the two-field result
  of §6, and the DIRECT and RELAY backends must be observably equivalent to the existing
  token-hygiene code.
- **Enrollment**: in relay mode, on first boot with no stored credential, Trellis calls
  `/v1/enroll` and stores the tenant credential at `DATA_DIR / "tenant.json"` (not a relative
  path — `DATA_DIR` defaults to `/data`, `app.py:54`). Failure is **not** fatal: retry with
  the §6 backoff, serve everything except push, and report `enrolled: false` in the
  authenticated `/health`.
- **Phone-facing authentication is unchanged.** Every phone-facing endpoint — the
  registrations, `/sync`, `/unregister`, collections — remains gated by `_require_key`, the
  existing `X-API-Key` check delegated to that user's Bambuddy (`app.py:753-777`). **The
  pairing secret is binding authority at Canopy; it is not authentication at Trellis.**
- **`/health` is split.** The unauthenticated route keeps `{ok: true}` for container health
  checks; counts, `push_suspended`, `enrolled`, and anything token-derived move behind
  `_require_key`. Today's unauthenticated count-leaking page was tolerable on a single-user
  box; under public URLs it is an oracle for whether a household is printing.
- **Claim forwarding**: every registration forwards a claim synchronously. "Forward and
  forget" means Trellis never *persists* the pairing secret — it must still act on the
  response. A registration succeeds to the phone only when the claim returned a definitive
  answer; a transport failure returns `502` so the app retries.
- **Relay-mode gate uses two named predicates**, not field presence: `claimVerified` (Canopy
  returned `204` — only Canopy can answer this) and `isNativeClient` (`client == "native"`).
  Relay mode **forces** `NATIVE` rather than letting `norm_client`'s deliberate leniency
  (`clients.py:54-62`) default a mangled discriminator to `EXPO`, which would silently send
  the wrong envelope shape. Rejections distinguish `attestation_missing` from
  `attestation_unsupported` (§10) so `/health` can report which.
- **Push-suspension, defined and split by question.** `not_owner` means authority was taken:
  suspend that **token**, persist the flag in `registrations.json` so a restart cannot resume
  retry-spam, surface it in the authenticated `/health` and in the app, and clear it only on
  a `204` claim for that token. `not_bound` means nobody holds it — routine after a release
  or lease expiry, and the whole-fleet condition after a Canopy restore gap. It does **not**
  suspend; it flags the token as needing a claim, which the app picks up via the
  `needs_claim` list on `/health` (§10). Conflating the two would make ordinary housekeeping
  look like an attack and would suspend every token on a Trellis at once.
- **Multiple phones per printer.** `_regs[key]` becomes a **list** of registrations. This is
  larger than one call site and the plan must enumerate all of them (`grep _regs
  deploy/la-push/app.py`, ~20 sites). Specifically: `lastState`, `lastPush`, `client`,
  `iconUri`, and `printerName` are **per registration**, so gating (`meaningful_change`,
  `MIN_UPDATE_S`) and envelope construction happen per entry — otherwise a phone joining
  mid-print shares a gate it never saw content through and sits frozen, and one expo plus one
  native phone on one key needs two differently-shaped payloads. `/sync` must drop only
  tokens the *reporting* device previously registered, never another phone's (`app.py:864-866`
  currently drops any token absent from one device's list). `/unregister` becomes
  **token-scoped** (`app.py:928` currently pops the whole key) — which is also what §7 item 6
  needs for native dismissal. The 400/410 drop removes one entry, not the list.
  `_p2s_pending` holds one claim per `(key, p2s token)` rather than one globally
  (`app.py:204`), or the second phone's remotely-started card is orphaned and then killed by
  the very mechanism meant to fix it. `_load()` migrates existing `registrations.json` dict
  values to single-element lists (`app.py:248`).
- **Relay mode is native-app only.** The RN app cannot produce an App Attest assertion, so in
  relay mode Trellis rejects its registrations with a stated reason and the docs say the RN
  app requires DIRECT mode. This removes revision 1's server-minted fallback secrets — both
  the weakest link in the model and the cause of a data-volume-loss lockout. The RN app
  remains personal/TestFlight, never App Store, so nothing ships worse off. `/sync` therefore
  serves DIRECT mode only; relay-mode reconcile is the native path in §7 item 6. Note the
  owner's own two-phone dogfooding happens in DIRECT mode, so the `/sync` and `/unregister`
  fixes above matter there too.

## 10. Sprout changes

- **App Attest**: generate the key once via `DCAppAttestService.shared.generateKey()`,
  persist `keyId`, attest on first claim, assert on every later one. Follow Apple's error
  guidance: `DCError.serverUnavailable` → retry with the *same* key and client-data hash
  (which is why §6 challenges are single-*success*); any other error → discard the key id and
  generate a new one. Handle `403 reattest_required` from Canopy by generating a new key and
  sending a fresh attestation.
- **When attestation is unavailable, say so.** `isSupported` is false in the Simulator, on
  Apple silicon Macs running iOS apps (opt the App Store listing out of Mac availability, or
  state Mac installs are LOCAL-mode only), in app extensions, and on a small fraction of
  genuine devices. Those installs must show the explicit push-health row — "Push isn't
  available on this device" — rather than silently 403ing into nothing. No secretless
  fallback: the correct answer is a stated limitation, not a hole.
- **Pairing secret**: 32 bytes, Keychain item `bambu.pairing`, separate from `AppConfig` so
  sign-out or re-onboarding never destroys it.
- **Keychain accessibility**: the whole registration credential set must be background-
  readable, not just the pairing secret. The POST also needs the API key and the Trellis URL,
  which live in `AppConfig` under `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  (`SecureConfig.swift:92`). The canonical background wake is a push-to-start arriving while
  the phone is locked in a pocket — Apple grants background runtime there — and a
  `WhenUnlocked` read fails at exactly that moment, so the claim never leaves the phone and
  the remotely-started card freezes at its start content. Move the pairing item, the attest
  key id, and a minimal `{pushUrl, apiKey}` item to
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, still `ThisDeviceOnly`.
- **A persisted pending-claim queue covering all three registrations.** Today only
  `/register` retries: `flushRegistrations()` runs every 4 s against a `registered` set
  (`LiveActivityController.swift:455-471`). `/register-start` is a fire-and-forget POST inside
  the `pushToStartTokenUpdates` loop whose result is discarded and which only iterates again
  on token rotation (`:346-355`), and `/register-device` does not exist yet at all (a known
  gap, `13-code-review.md`, `00-overview.md:116`). So a brand-new install whose first claim
  meets a down Canopy never registers a start token for the whole process lifetime — the
  worst state the controller's own header comment describes. All three must go onto one
  persisted queue with the same retry discipline, re-attempted on foreground, on every token-
  stream emission, and on the `needs_claim` list from Trellis's `/health`.
- **APNs environment from the entitlement, not the build configuration.** Revision 1 derived
  it from `#if DEBUG`, a proxy for the real question: a `-configuration Release` build
  installed via Xcode/devicectl — the repo's everyday device recipe — is development-signed,
  so its tokens are sandbox while `#if DEBUG` is false. Read `aps-environment` from the
  running task's entitlements (with the embedded provisioning profile as the fallback source
  where that is unavailable): `development` → `sandbox`; absent or `production` →
  `production`. There is no `#if DEBUG` fallback — "absent → production" already gives the
  right answer for App Store builds, and keeping the proxy around would only let the original
  bug back in. Canopy's gateway retry (§6) is the safety net.
- **Dismissal reconcile**: call the token-scoped `/unregister` on `cardVanished` (§7 item 6).
  Without it every App Store user inherits the empty-lock-screen deadlock.
- **Push health in the UI**: read Trellis's authenticated `/health` and show an actionable row
  ("Push needs re-pairing — tap to fix") rather than letting the user discover a limitation by
  silence.
- **Background refresh is a supplement, not a guarantee.** A `BGAppRefreshTask` refreshes the
  start and device claims, but iOS schedules it opportunistically and weights it by how often
  the user foregrounds the app — so it is least likely to run for the passive user it would
  most help, and never after a force-quit. It must not be the only path: the deterministic
  ones are re-claim on foreground, on every token-stream emission, and in response to
  Trellis's `needs_claim`; and Canopy treats its own database as durable state rather than
  something clients rebuild (§6).
- **Registration bodies** gain `client_data`, `pairing_secret`, `apns_environment`,
  `attest_key_id`, and `attestation`/`assertion` — snake_case, tested like the existing
  fields.
- **URL sourcing**: challenges, claims, and the push-health read use `resolvePushUrl` (they
  are push); collections keep `laPushUrl` (they are not). The distinction is the repo's
  flagship recurring bug and must not blur here.
- `ConfigRules` derivation becomes `bambuddy.` → `trellis.`; explicit `pushUrl` still wins;
  the RN app's `lapush.` derivation is untouched (the owner keeps a `lapush.` CNAME during the
  transition). The push on/off toggle and the `laPushUrl` vs `resolvePushUrl` split are
  already correct and unchanged.

## 11. Failure modes

| Failure | Behavior |
|---|---|
| Canopy down | Pushes and claims fail; Trellis retries with the §6 backoff; registrations return 502 and enter the app's pending-claim queue (§10); cards go visibly stale; LOCAL-mode users unaffected. |
| Trellis has never enrolled | Serves everything except push, retries enrollment, reports `enrolled: false` in the authenticated `/health` (§9). |
| Canopy database lost | Restore from the daily backup — this is the recovery path, because attest keys cannot be reconstructed by clients. Without a restore, every assertion fails; Canopy answers `reattest_required`, and each install re-attests on its next claim, which for a passive user may be weeks away. |
| Push rejected `403 not_owner` | Token suspended, surfaced in `/health` and the app, cleared by a successful re-claim. |
| Push rejected `403 not_bound` | Not a suspension — the token is flagged `needs_claim`, which the app acts on (§9, §10). |
| Trellis down / user's server dead | No pushes for that user; rebuild plus the phone's next registration restores everything, because both ownership anchors live on the phone (§5). |
| Attacker holds a binding (compromised Trellis, replayed or rotated claim) | Junk pushes to that user's own devices only. The real phone's next claim re-points the binding, using the elder anchors if the attacker rotated — within the 90 d elder window. Past it, operator unbind. Never cross-user. |
| Phone loses both anchors (reinstall with no Keychain survival) | The same-tenant rebind row (§5) accepts a fresh attestation from the tenant that already holds the binding, so it self-heals silently. |
| Token genuinely abandoned (no delivery or claim for 90 d) | Rebindable, with the prior anchors retained as elder for 90 d — reachable because rows survive to 120 d (§6). |
| Wrong APNs environment on a claim | The first `BadDeviceToken` triggers the other-gateway retry with that gateway's key, correcting the stored `apns_environment` permanently (§6). |
| APNs key compromised | Owner revokes and uploads a new key; zero tenant or user action (invariant 5). Topic-scoped keys keep the blast radius inside this app. |

## 12. Testing

- **Canopy (Go)**: table-driven tests over the binding state machine — one row per §5 case,
  with **asserted day counts** for dormancy (90 d), elder window (90 d), and hard delete
  (120 d) so the two clocks cannot drift back out of order; attestation and assertion
  verification against captured real-device fixtures plus negatives (missing or altered
  credCert nonce extension, resigned assertion, swapped `authenticatorData`, wrong
  `rpIdHash`, wrong aaguid bytes, replayed challenge, non-increasing counter, expired
  certificate against an injectable clock); the shared `client_data` golden fixture; handler
  tests via `httptest`; a fake APNs server for passthrough, 410 unbind, and the
  `BadDeviceToken` retry that swaps host *and* key; topic-forcing and priority clamping;
  release, cap accounting, and GC; rate limiting, failed-claim backoff, and a load case
  asserting that saturated claim traffic does not trip the global push breaker;
  idempotency-key dedupe.
- **Trellis (Python, stdlib unittest as today)**: the two backends observably equivalent to
  the existing token-hygiene code, including **"a Canopy 400 does not delete a
  registration"**; claim forwarding and the 502 contract, including a claim retried after a
  timeout Canopy actually processed; `not_owner` suspends and `not_bound` does not;
  suspension persistence across restart; multi-registration fan-out for two phones on one
  printer, per-registration gating state, token-scoped `/unregister`, `/sync` dropping only
  the reporting device's tokens, and the `registrations.json` dict→list migration; release on
  card end; unauthenticated `/health` revealing no token prefixes; startup fail-hard on
  ambiguous backend config; rejection of unattested registrations in relay mode.
- **Sprout (XCTest)**: registration body encoding and the `client_data` golden fixture;
  Keychain pairing and attest-key lifecycle, including survival of a config wipe and
  readability after first unlock; environment derivation from entitlement fixtures
  (development, production, absent); pending-claim queue retry for all three registration
  types, including "start-token registration fails and is retried without a token rotation";
  `isSupported == false` surfaces the push-health row. App Attest itself is exercised on a
  real device during rollout.

## 13. Rollout

Four implementation plans, each its own spec-to-plan cycle. Note the fixture dependency:
Canopy's attestation tests need real-device artefacts, so a small capture harness comes
first.

0. **Attest-capture harness** — a debug-only affordance (or throwaway build) that, given a
   challenge string on a real device, dumps an attestation and a *sequence* of follow-on
   assertions to files. Sequences matter because Canopy asserts a strictly increasing
   counter, and sandbox and production fixtures differ by aaguid, so both are captured.
1. **Canopy service** — build and deploy behind Caddy. Unit-verify against the step-0
   fixtures with an injectable clock and injected challenges; live-verify the parts needing
   no attestation (topic forcing, priority clamp, rate limits, APNs passthrough against a
   fake server).
2. **Trellis relay mode** — the two-backend interface with the two-field result, enrollment
   and its failure path, claim forwarding, the suspension/needs-claim split, release, the
   `/health` gating, and the multi-registration registry change with its full call-site sweep.
3. **Sprout pairing** — App Attest, the Keychain moves, entitlement-derived environment, the
   pending-claim queue, dismissal reconcile, push-health UI, and the new body fields. The
   first true end-to-end sandbox test happens here, on a real device.
4. **Rename, dogfood, distribute** — la-push → Trellis across dirs, container, and docs;
   owner DNS gains `trellis.<domain>` and keeps `lapush.<domain>` as a CNAME; the owner flips
   his own Trellis to relay mode (DIRECT stays supported and tested); write the self-hoster
   guide with a one-file compose bringing up Bambuddy + Trellis with `CANOPY_URL` preset;
   then App Store submission, which needs a reachable demo Bambuddy + Trellis with demo
   credentials.

## 14. Out of scope / future hardening

- **Apple's fraud-assessment metric** — the receipt is stored at attestation time (§6)
  precisely so this can be enabled later without re-attesting every install. It is the
  mechanism that bounds §4's stated residual risk (a hooked app on a jailbroken device).
- **Encrypted content-state** for the native client (ciphertext decrypted in the widget with
  an App-Group-shared key), which would remove printer and file names from Canopy's view
  entirely. The envelope still cannot be encrypted (§7).
- Alert banners end-to-end encrypted via a notification service extension.
- A user-facing "Reset push pairing" control. Rotation exists in the protocol and preserves
  elder anchors; v1 exposes no button for it, and the operator unbind is the recourse.
- Android/FCM — a `platform` field on `/register-device` and a second sender in Trellis
  (`docs/guides/android.md`); Canopy would gain an FCM credential and a topic-table entry,
  with Play Integrity replacing App Attest as the device anchor.
- A payload-scrubbing knob (user opts filenames out of push payloads at the Trellis level).
- Operator tooling beyond manual unbind by token hash, which **is** in scope as the support
  backstop for a stuck binding.
