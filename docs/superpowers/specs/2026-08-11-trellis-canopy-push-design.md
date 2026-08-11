# Trellis + Canopy: multi-tenant push for App Store distribution

**Status:** approved design, not yet implemented
**Date:** 2026-08-11
**Revision:** 4 — after three adversarial review rounds. Revision 1 shipped a cross-user push
path (lease-expiry rebind). Revision 2 replaced it with App Attest but omitted two of Apple's
verification steps, ordered its own clocks wrong, and made claims unretryable. Revision 3
fixed those and introduced a new crop in the replacement machinery: an expired row read as
first-claimable, a single overwritable elder slot, an unchecked challenge binding, and a
`stale-date` capability the code does not have. §5 and §6 carry most of the change.

## 1. Context and goals

Today the app is single-user: la-push runs next to the owner's Bambuddy, holds the owner's
APNs `.p8` auth key, and pushes Live Activities and alert banners directly to APNs. A key
authorises push for **every install of every app it covers**, which is why the current design
cannot be shared: `docs/guides/push-notifications.md` tells other people to self-host with
their *own* key, and that only works for their own TestFlight builds, never for an App Store
install signed by the owner's team.

(Apple's key model has moved on from what `push-notifications.md` records. There are now
team-scoped keys — two per environment, covering every app on the team — and topic-specific
keys tied to named bundle ids, with a much higher cap. Canopy uses a **topic-specific key
scoped to `com.mvks5.bambu`**, so a Canopy compromise cannot reach any other app on the team
and rotation is cheap. A bundle-scoped key covers that bundle's Live Activity sub-topic
`com.mvks5.bambu.push-type.liveactivity` as well; confirm this when provisioning, since both
topics are signed. Because modern keys are environment-scoped, Canopy holds **one key per
APNs environment**; see §6.)

The goal: ship the native app (Sprout) on the App Store so strangers can install it, while
**each user self-hosts their own Bambuddy + companion service**, and:

- the owner (operator of the shared infrastructure) sees the minimum data required to
  operate — never printer libraries, cameras, credentials, or Bambuddy access;
- no user can push notifications to another user's devices, even holding a stolen push token
  — with one residual, stated in §4 rather than papered over;
- a user whose server dies and is rebuilt from scratch recovers push with zero manual
  unbinding, support tickets, or waiting, **provided the tenant credential is restored**
  (§9's recovery code makes that a saved string, not a backup requirement);
- users who opt out of push entirely keep everything else working (the existing `laPushUrl`
  vs `resolvePushUrl` split is preserved).

## 2. Naming

The companion service outgrew its name — it serves MakerWorld collections as well as push,
and this design adds pairing forwarding. Renames:

- **la-push → Trellis** — the user-side companion (`deploy/la-push/` → `deploy/trellis/`,
  container `bambu-trellis`, port 8911 unchanged). A trellis is the structure in your own
  garden that supports a growing plant (the app is Sprout).
- **Canopy** — the new, owner-hosted APNs relay (top-level `canopy/` in the monorepo; it does
  not run on the home server). The shared cover above everyone's gardens.

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
   Attestation challenges and claims are relayed through Trellis, which cannot forge or alter
   them (§5).
3. **The owner's infrastructure never talks to any user's Bambuddy.** Canopy accepts inbound
   requests only.
4. **A tenant can never choose an APNs topic.** Canopy derives the topic from `push_type`
   against a hardcoded two-entry table; those are the only strings it will ever sign for.
5. **Nothing Apple-specific reaches Trellis in relay mode.** Key ids, team id, topics, and
   APNs hosts live only in Canopy — so the owner can rotate keys at any time with zero action
   from any user or tenant.
6. **Ownership of a push token is anchored to the device, not to a server.** Servers are the
   disposable party in a self-hosting setup; the phone is the durable one.
7. **Two questions never share one field or one predicate.** This design has seven pairs that
   read as synonyms and are not: APNs environment vs App Attest environment; `not_bound` vs
   `not_owner`; a Canopy HTTP status vs an APNs status; authentication at Trellis vs binding
   authority at Canopy; Canopy's `binding_kind` vs Trellis's `kind`; "matched the current
   anchor" vs "matched an elder anchor"; "no row exists" vs "the row's lease expired". Each
   is kept separate deliberately, per the repo's recurring-bug rule — every one of them was a
   real defect in an earlier revision of this document.

## 4. Threat model

Assets: the APNs keys (each signs pushes for every install of the app), users' push tokens,
users' print metadata (printer names, filenames — they transit push payloads), Canopy's
tenant credentials.

| Adversary / scenario | Outcome under this design |
|---|---|
| Attacker steals a push token and tries to bind it with `curl` | Fails. Every claim requires an App Attest assertion from a genuine Sprout install, signed over the exact claim contents and verified against a stored public key (§6). A tenant credential alone is not enough. |
| Attacker with a **hooked genuine app on a jailbroken device** claims a token Canopy has never seen | **Succeeds — this is the design's residual risk, stated plainly.** A token that has never been claimed is bound first-come (there is no prior anchor to check against), so an attacker who both obtains a live unseen token and runs a hooked build can take it, and the victim's later claim is refused. Bounds: re-signing under another team fails the App ID check, so it takes a jailbroken device; one attest key may hold live bindings across at most three tenants; repeated `pairing_mismatch` from a consistent claimant raises an operator alert *and* a user-visible "push pairing was taken over" row (§10); and Apple's fraud-assessment metric closes it further once enabled (§14). Recovery is operator unbind (§14, in scope). |
| Attacker tries to take over a token that **is** already anchored | Refused. A row's anchors are checked on every claim regardless of lease state — an expired or released row is *not* first-claimable, only a hard-deleted one is (§5). |
| Attacker waits out a lease | Closed. Leases renew on successful delivery as well as on claims, and lease expiry no longer opens a token to anyone. The rebind paths need either the tenant already on the row (with a previously-unseen attest key, once per elder window) or 90 days of total inactivity — and both retain the outgoing anchors as elder so the original device evicts them on its next claim. |
| Attacker enrolls tenants and probes tokens | Tokens are 32-byte APNs-generated values; guessing is infeasible. Cheap checks run before expensive ones (§6), so a failed claim costs no X.509 work. Per-IP and per-tenant limits, per-token-hash failed-claim backoff, a bounded tenant count, and an auto-arming invite code cap the probe rate. Attestation verification has its own bounded worker pool so claim floods cannot starve `/v1/push`. |
| A user's Trellis box is fully compromised | The attacker gets that user's tokens, tenant credential, and observes pairing secrets and assertions in transit. They can push junk **to that user's own devices only**. They can replay a captured claim, but only under the tenant it was issued to (§6 checks the challenge's tenant), and cannot forge a different one. If they use a hooked app to seize a binding via the same-tenant recovery row, the outgoing anchors are retained as elder and the victim's next claim evicts them; the row is rate-limited to once per token per elder window so it cannot be used to ping-pong the victim out. |
| A tenant floods pushes (hostile or broken) | Per-token, per-tenant, and per-IP limits. Shedding is tenant-scoped first; the global breaker is a last resort, so one abuser cannot deny push to everyone. |
| Canopy itself is compromised | The attacker holds the APNs keys → arbitrary push to all installs until revocation. Bundle-scoped keys keep the blast radius inside this app. Mitigations: minimal surface (static Go binary, three dependencies), no payloads or raw tokens at rest, TLS via reverse proxy, monitoring, WAL plus daily off-box backups, rotation needing no tenant action. |
| Someone who knows a public Trellis URL registers their own token | Rejected by Trellis's existing `X-API-Key` gate, delegated to that user's Bambuddy (`app.py:753-777`) and unchanged here. Trellis's `/health` gains the same gate for anything beyond liveness (§9). |
| The owner snoops on users | Sees per-push: raw token and payload, in memory, for one HTTPS forward. Stores only hashes, public keys, and counters (§8). Cannot reach any user's Bambuddy. A documented trust statement, not cryptography — §7 for what is encryptable, §14 for the deferred option. |

## 5. Device identity, pairing, and binding

Ownership rests on **two anchors held by the phone**, each covering the other's loss case:

- **An App Attest key** (`DCAppAttestService`), generated once, private half sealed in the
  Secure Enclave and non-exportable. Proves "a genuine Sprout install on a real Apple device
  made this exact request." Apple documents that these keys do not survive app reinstallation,
  device migration, or restore from backup.
- **A pairing secret**, 32 random bytes in the phone's Keychain. Survives app reinstall in
  current iOS behaviour (an undocumented artefact, not an API contract — the design must not
  depend on it alone) and survives direct device-to-device migration, but not restore from
  backup, since the item is `ThisDeviceOnly`.

Neither anchor is held durably by any server. Trellis relays claims and **cannot alter them**:
the assertion signs the claim's contents, so a compromised Trellis can replay a claim but
never forge a different one.

### Token states

Three states, never conflated (invariant 7 — revision 3's bug was treating the middle one as
the first):

- **UNSEEN** — Canopy has no row for this token hash. A claim binds it first-come.
- **ANCHORED** — a row exists. This includes rows whose lease has expired and rows that have
  been released. **Every claim against an ANCHORED token runs the full anchor test below**;
  lease state affects only cap counting and push authority, never claimability.
- Hard deletion (§6) is the only transition back to UNSEEN, and it happens long after any
  device could still be using the token.

Push authority is a separate question: a push is allowed only from the tenant on a row with a
live lease; otherwise `403 not_bound` (no row / released / expired) or `403 not_owner`
(another tenant holds it).

### Claim protocol

A claim attempt is an **indivisible unit**: obtain a challenge, produce an assertion over it,
POST. It is not replayable — the nonce is consumed on success and the Secure Enclave counter
advances — so **every retry acquires a fresh challenge and generates a fresh assertion**.
Claims are not idempotent in the HTTP sense; repeated attempts converge on the same binding
state. What the app queues (§10) is therefore an *intent* to claim, never a signed claim.

1. The app asks its Trellis for a challenge; Trellis calls Canopy `POST /v1/challenges`
   (tenant-authed) and returns the opaque nonce. A challenge is consumed **on success**, not
   on presentation, so Apple's documented `DCError.serverUnavailable` retry — same key, same
   client-data hash — still validates. TTL is 15 minutes for attestations (Apple asks that
   attestation retries reuse identical inputs, to preserve the device's risk metric) and 120
   seconds for assertions. Canopy records the issuing tenant and the purpose and **checks both
   when the challenge is presented** (§6).
2. The app builds `client_data`, a JSON object over
   `{challenge, token, pairing_secret, binding_kind, apns_environment}`, and produces either
   an **attestation** (first use of a new attest key) or an **assertion** (every later claim)
   over `SHA-256(client_data)`.
3. The app POSTs its normal registration to Trellis (`/register`, `/register-start`,
   `/register-device`) with the new fields; Trellis forwards them to Canopy `/v1/claims`.
4. Canopy verifies the attestation or assertion (§6) against **the exact `client_data` bytes
   the app sent** — transmitted base64, never re-serialised server-side — then checks that the
   fields parsed out of those bytes equal the corresponding top-level claim fields.
   Re-serialising would make a security check depend on `JSONEncoder` and `encoding/json`
   agreeing byte-for-byte forever; WebAuthn transmits `clientDataJSON` verbatim for the same
   reason. `client_data` is UTF-8 JSON, snake_case keys sorted lexicographically, no
   whitespace, absent optionals omitted rather than null, no HTML escaping — pinned by a
   golden fixture shared between the Go and XCTest suites (§12), with unknown extra fields
   tolerated on parse.

**`binding_kind` (`activity | start | device`) is not Trellis's `kind` (`print | dry`).** Both
now travel in one POST body, and Trellis's drives the `dry:<pid>:<amsId>` registry key
(`app.py:787`). The app sends both explicitly; Trellis cannot supply `binding_kind` after the
fact, because it is inside the signed `client_data`.

**v1 has no pairing-secret rotation.** Revision 3 carried a `previous_secret` field for a
feature with no UI, which made the rotation transition reachable only by an attacker — pure
attack surface. It is removed from v1 schemas; §14 records how to reintroduce it with the
elder rules intact.

### Binding state machine

Binding row: `{token_hash, binding_kind, apns_environment, tenant, attest_key_id,
pairing_hash, elder_attest_key_id, elder_pairing_hash, elder_until, elder_rebinds_used,
lease_expiry, last_delivery_at, last_claim_at, released_at, created_at}`. Attest keys live in
their **own table** with a lifetime independent of any binding (§6) — they must outlive the
bindings they were used to claim.

Every rule requires a verified attestation or assertion first; a claim without one is `403
attestation_required` and never reaches the machine. **Rules are evaluated in order and the
first match wins**; the guards make them mutually exclusive. Any claim that reaches the
machine stamps `last_claim_at`, including a rejected one — a token under active attack is not
abandoned.

| # | Guard | Action |
|---|---|---|
| R0 | Token is UNSEEN | Bind: store both anchors, tenant, `binding_kind`, `apns_environment`; `lease_expiry = now + lease(binding_kind)`. |
| R1 | Claim's attest key **equals the current** `attest_key_id` | Accept (primary path). Re-point tenant, refresh pairing hash, renew lease. **Elder is left untouched** — this claim did not need it, and clearing it here was revision 3's bug: it let an attacker who had just seized a row erase the victim's recovery anchor with one ordinary claim. |
| R2 | Claim's pairing secret **equals the current** `pairing_hash`, and the claim carries a **fresh attestation** (the attest key is new, so there is no stored public key to verify an assertion against) | Accept — the app-reinstall case. Store the new attest key, re-point tenant, renew lease. Elder untouched. |
| R3 | Claim matches **an elder anchor** (either kind) and `now < elder_until` | Accept and evict: install the claim's anchors as current, then **clear elder and reset `elder_rebinds_used`** — elder has done its job. This is the row that returns a token to its rightful device after any rebind. |
| R4 | No anchor matched; the claim carries a fresh attestation whose `attest_key_id` is **previously unseen by Canopy**; the claim comes from **the tenant currently on the row**; there is no live elder; and `elder_rebinds_used = 0` | Same-tenant recovery rebind, for a phone that lost *both* anchors. Retain the outgoing anchors as elder (`elder_until = now + 90d`), set `elder_rebinds_used = 1`. |
| R5 | No anchor matched and the token is **dormant**: `now - max(last_delivery_at, last_claim_at, created_at) > 90 d` | Dormancy rebind. Retain the outgoing anchors as elder for 90 d. |
| R6 | Otherwise | `403 pairing_mismatch`, counted per token-hash for backoff and operator alerting (§6). |

R4 needs its justification stated correctly, because revision 3's was wrong. It is **not**
"the tenant could release the token anyway, so this grants nothing new" — release deliberately
retains anchors and does not reopen a token, so release is a strictly weaker authority than
anchor replacement. The real argument is narrower: R4 exists only to rescue a genuine reinstall
that lost the Keychain, and it is fenced so a compromised Trellis cannot use it to durably
seize a binding — a previously-unseen attest key (so a hooked device cannot reuse one key
across victims), no live elder, at most once per elder window, and the outgoing anchors always
retained so the real device evicts on its next claim via R3.

A single attest key legitimately covers many tokens for one device across a household rebuild,
but **the same key holding live bindings across more than three tenants** is the signature of
the hooked-device attack: Canopy refuses with `403 key_tenant_limit` and alerts the operator.

Other transitions:

| Event | Rule |
|---|---|
| Push from the tenant on a row with a live lease | Allowed. **A successful APNs delivery renews the lease** and stamps `last_delivery_at`, so an actively-used token never drifts toward dormancy. |
| Push from another tenant | `403 not_owner` — authority was taken; the suspension condition (§9). |
| Push with no row, or a released/expired row | `403 not_bound` — routine housekeeping, **not** a suspension condition; it means "re-claim", not "you were evicted". |
| APNs answers 410 / 400 `BadDeviceToken` after the §6 gateway retry | Delete the row — the token is genuinely dead. |
| `POST /v1/bindings/release` (raw token in the body, bound tenant only) | Set `released_at = now`. **`lease_expiry` is not touched** — overloading it, as revision 3 did, silently collapsed the retention horizon and erased the margin that makes R5 reachable. Cap counting reads `released_at IS NULL AND now < lease_expiry`; retention reads `lease_expiry`. |

What each anchor buys, walked through the real lifecycle events:

| Event | Attest key | Pairing secret | APNs tokens | Outcome |
|---|---|---|---|---|
| Trellis rebuilt or migrated, credential restored | kept | kept | kept | R1. **No user action.** |
| Trellis rebuilt, credential lost, recovery code used (§9) | kept | kept | kept | R1 — the recovery code preserves tenant identity. |
| App deleted and reinstalled | lost | usually kept | usually new | R2, or R0 on new tokens. |
| App reinstalled *and* Keychain did not survive, same tenant | lost | lost | maybe same | R4. |
| Phone restored from backup onto new hardware | lost | lost | **new** | R0 on the new tokens; old ones 410 and free themselves. |
| Direct device-to-device migration | lost | kept | new | R2/R0. |
| Trellis compromised, attacker seizes a binding via R4 | intact on phone | observed | kept | R3 evicts the attacker on the phone's next claim, inside the 90 d elder window. |

Per-activity tokens need no ownership special-casing — they die with each card. They do need
lifetime special-casing; see §6.

## 6. Canopy specification

**Language: Go.** Canopy is the one internet-facing service holding the keys, and it is new
code (~900 lines with attestation verification). Go gives a static binary with a stdlib HTTP
server, transparent HTTP/2 to APNs via `net/http`, ES256 over `crypto/ecdsa` (no JWT
library), X.509 chain verification in `crypto/x509`, and table-driven tests that fit the
binding state machine exactly. Third-party surface: `modernc.org/sqlite` (pure Go),
`golang.org/x/time/rate`, and `github.com/fxamacker/cbor/v2` for attestation objects.
Deployment: `GOOS=linux go build`, scp, systemd, Caddy for TLS, SQLite in WAL mode with a
daily off-box backup. (Trellis stays Python: its logic is proven and measured, and the Docker
container is the distribution unit, so the language is invisible to self-hosters.)

**Two APNs keys.** Modern keys are environment-scoped, so Canopy is configured with
`CANOPY_APNS_KEY_SANDBOX` and `CANOPY_APNS_KEY_PRODUCTION` plus their key ids; a legacy
universal key may be pointed at both. Both must be present at startup or Canopy refuses to
run. The gateway retry swaps **host and signing key together** — signing a production JWT
against the sandbox host returns `403 InvalidProviderToken`, not `BadDeviceToken`, and would
never converge.

Endpoints (JSON over HTTPS; tenant auth is `Authorization: Bearer <tenant_id>.<tenant_secret>`):

- `POST /v1/enroll` `{invite_code?, recovery_code?}` → `201 {tenant_id, tenant_secret,
  recovery_code}`. With a valid `recovery_code`, Canopy **re-adopts the existing tenant
  identity** and issues a fresh secret instead of creating a new tenant — this is what makes a
  full rebuild recover without an operator unbind (§11). Rate-limited per IP (20/day, burst 5;
  a first-time self-hoster running `docker compose down -v` a few times must not lock
  themselves out) and globally capped at `CANOPY_MAX_TENANTS` (default 10 000). `invite_code`
  is required when `CANOPY_INVITE_CODE` is set, and auto-arms when enrollments exceed
  100/day or the verified-claim ratio falls below 0.5 over an hour.
- `POST /v1/challenges` `{purpose: "attestation"|"assertion"}` → `201 {challenge,
  expires_at}`. Tenant-authed, rate-limited per tenant and per IP. Single-use **on success**;
  TTL 15 min for attestation, 120 s for assertion.
- `POST /v1/claims` `{token, client_data, pairing_secret, binding_kind, apns_environment,
  attest_key_id, attestation? | assertion?}` → `204`, or `403 attestation_required |
  attestation_invalid | reattest_required | pairing_mismatch | wrong_tenant |
  key_tenant_limit`, or `429 binding_limit`. Implements §5. **Not idempotent** — see the claim
  protocol. `reattest_required` means "Canopy does not know this key; generate a new App
  Attest key and send an attestation, not an assertion", which is what makes a Canopy
  restore-gap recoverable rather than indistinguishable from an attack. `wrong_tenant` is
  distinct from `pairing_mismatch` so Trellis can tell "R4 refused you" from "your anchors are
  wrong".

  **Challenge binding.** Before anything else, the presented challenge must exist, be
  unconsumed, be unexpired, have been **issued to the authenticated tenant**, and match the
  **purpose** of the proof presented (`attestation` for attestations, `assertion` for
  assertions). Revision 3 stored both columns and read neither, which left a claim replayable
  under a *different* tenant — materially worse than verbatim replay, since every accepting
  rule re-points the tenant — and let a 15-minute attestation challenge extend the assertion
  replay window 7.5×.

  *Attestation verification* follows Apple's published procedure in full, in order:
  (1) `fmt` is `apple-appattest` and the CBOR has the expected `attStmt {x5c, receipt}` and
  `authData` shape; (2) `x5c` = [credCert, intermediate] chains to the **pinned Apple App
  Attest Root CA**, with every certificate inside its validity window against an injectable
  clock; (3) `clientDataHash = SHA-256(client_data)`; (4) `nonce = SHA-256(authData ||
  clientDataHash)`; (5) **decode the credCert extension with OID `1.2.840.113635.100.8.2` as
  a DER ASN.1 SEQUENCE, extract its single OCTET STRING, and require it to equal `nonce`** —
  this comparison is the only thing tying Apple's signed certificate to our challenge, and
  omitting it (revision 2) makes the whole check bypassable by replaying any well-formed
  attestation; (6) `SHA-256` of the credCert public key in uncompressed EC point form equals
  the base64url-decoded `attest_key_id`; (7) `authData[0..32] == SHA-256("<APP ID>")` where
  APP ID is `<TEAM_ID>.com.mvks5.bambu`; (8) counter is 0; (9) `aaguid` compared as **exact 16
  bytes** — `appattestdevelop`, or `appattest` followed by seven `0x00` bytes (a prefix
  comparison would also match a hostile value beginning `appattest`); (10) `authData`
  `credentialId` equals the key identifier. Then store the public key, the counter, the
  observed **attest environment** (from the aaguid), and **the receipt** — receipts can only
  be captured at attestation time and are the input to Apple's fraud-assessment metric (§14).

  *Assertion verification*: (1) `clientDataHash = SHA-256(client_data)`; (2) `nonce =
  SHA-256(authenticatorData || clientDataHash)`; (3) **verify the assertion signature over
  `nonce` with the stored P-256 public key** — revision 2 omitted this, leaving every other
  check running on attacker-supplied plaintext; (4) `authenticatorData[0..32] ==
  SHA-256(APP ID)` (an assertion's `authenticatorData` is 37 bytes and carries no aaguid or
  credentialId, so step 9's rule is attestation-only); (5) counter strictly greater than the
  stored value, then persist it. The challenge checks above run first as a cheap gate and are
  re-confirmed here against the value inside `client_data`.

  **An `attest_key_id` is only ever persisted from a verified attestation.** R2 and R4 both
  require one for exactly this reason: otherwise Canopy could store a key id with no
  corresponding public key, and R1 would later "match" a key it never attested.

  **The App Attest environment is not the APNs environment.** They are different Apple
  concepts — the first from the `com.apple.developer.devicecheck.appattest-environment`
  entitlement (ignored after distribution), the second from `aps-environment`. Apple
  explicitly sanctions a development build attesting against production servers. Canopy
  records `attest_environment` **per attest key, immutably, from the observed aaguid**,
  requires every later attestation for that key to match, and never derives it from
  `apns_environment`. A production deployment may refuse `appattestdevelop` by config.
  Sandbox receipts redeem at `data-development.appattest.apple.com`.

- `POST /v1/push` `{token, push_type: "liveactivity"|"alert", priority: 5|10, payload,
  idempotency_key?}` → `200 {apns_status, apns_reason?}`, or `403 not_bound|not_owner`, or
  `429`. Canopy verifies the caller is the tenant on a live-leased row; clamps priority;
  derives `apns-topic` and `apns-push-type` from `push_type` (hardcoded, invariant 4); caps
  payload at 4096 bytes; signs with the key for the row's `apns_environment`; renews the lease
  on success; returns the APNs status and reason **verbatim**. Payload contents are opaque
  passthrough.
- `POST /v1/bindings/release` `{token}` → `204`. Bound tenant only. **Takes the raw token, not
  a hash** — a `token_hash` in a path would be a cross-language hash contract (Python producer,
  Go verifier) whose input encoding the spec never pinned, and whose mismatch fails silently:
  release becomes a no-op, released rows keep counting against the cap, and completed cards
  linger with nothing 4xx-ing. Every other endpoint already takes the raw token; this one now
  matches.
- `GET /v1/health` → `{ok, version}`. Deliberately bare — it must reveal nothing about tenants.

**Canopy statuses are not APNs statuses.** The relay backend's return type is explicitly two
fields, `(transport_outcome, apns_status | None)`, and Trellis's token hygiene consumes only
the second. Mapping: Canopy `200` → use `apns_status`; `403` → the suspension/re-claim paths
in §9, never token hygiene; `429`, `5xx`, timeout → retry, touch no registration; any other
`4xx` → log and drop this push, keep the registration. Without this a Canopy-side `400`
(malformed body, oversized payload) reads as APNs `400 BadDeviceToken` and Trellis deletes a
healthy registration. Note `_apns_send` passes priority as a string today (`app.py:299`) while
the wire schema is an int — the adapter converts.

**Environment self-correction.** On `400 BadDeviceToken`, Canopy retries once on the other
gateway with that gateway's key. If the retry succeeds it corrects the stored
`apns_environment` and logs it. `apns_environment` is **never overwritten by a later claim** —
otherwise the phone, still deriving the same wrong value, would silently revert the
correction. Rebinds (R4, R5) install new anchors but likewise leave it alone: a token's
environment is a property of the token, not of whoever holds it.

**Idempotency and retries.** Live Activity *updates* are never retried — the next poll
supersedes them. Push-to-start and alert banners retry at most once on transport timeout,
carrying a client-generated `idempotency_key` that Canopy dedupes for 5 minutes. Claim
*attempts* retry with exponential backoff (1 s doubling to a 5 min cap), each with a fresh
challenge and assertion.

**Rate limits and work ordering** (env-tunable; a backstop, not shaping — Trellis already
shapes at `MIN_UPDATE_S = 30`):

- per token: sustained 1 push/10 s, burst 5;
- per tenant: 120 pushes/min, 60 claims/min, 60 challenges/min, plus the binding cap below;
- per source IP: 60 claims/min and 120 pushes/min, not only enrollments per day;
- per token-hash: failed-claim counter with exponential backoff, plus an operator alert when
  one token accumulates repeated `pairing_mismatch` — the signature of a targeted takeover,
  and the signal §10 surfaces to the user;
- per attest key: at most 3 tenants holding live bindings (`403 key_tenant_limit`);
- **cheap checks first**: challenge existence, tenant, purpose, expiry, per-token backoff, and
  rate limits are all evaluated *before* any X.509 or signature work; the challenge is
  re-confirmed against `client_data` after verification, so it is deliberately checked twice.
  Attestation verification runs on a bounded worker pool so a claim flood cannot starve
  `/v1/push`;
- tenant-scoped shedding first; the global breaker is a last resort.

**Binding lifetime, release, and garbage collection.** Leases differ by `binding_kind`.
**The retention horizon must exceed the dormancy threshold** for any kind where R5 must be
reachable — the ordering bug revision 2 shipped, and which revision 3 fixed for two kinds
while leaving the third inconsistent:

| `binding_kind` | lease | hard delete | dormancy (R5) |
|---|---|---|---|
| `activity` | 72 h, renewed on delivery | `lease_expiry + 7 d` (total 10 d) | **Not applicable** — the token dies with its card, so the row is deleted long before 90 d and returns to UNSEEN. This is safe precisely because the token is dead by then; it is stated rather than left to arithmetic. |
| `start`, `device` | 30 d, renewed on delivery or claim | `lease_expiry + 90 d` (total 120 d) | Reachable in the window [90 d, 120 d], so a returning device still finds its elder anchors. |

Trellis calls release when it drops a registration — after an end push, on a 400/410 drop, and
on a dismissal disown — which is what keeps completed cards from lingering (Trellis stops
pushing while the activity is still alive, so APNs answers 200 and a 410 never arrives;
`app.py:353-354`, `582-585`). **A live binding is `released_at IS NULL AND now < lease_expiry`**,
and only those count against the per-tenant cap of 500. An over-cap claim returns `429
binding_limit`, surfaced in Trellis's `/health`.

**Storage:** SQLite (WAL). `tenants` (id, secret_hash, recovery_hash, created_at, last_seen);
`bindings` (as in §5); **`attest_keys` (key_id, public_key, counter, attest_environment,
receipt, first_seen, last_seen)** — never garbage-collected with bindings, because assertions
must verify long after any particular card is gone; `challenges` (nonce_hash, tenant, purpose,
expires_at); plus in-memory rate buckets. Raw tokens arrive per-request and die with it.

**Bindings and attest keys are durable state, not a cache.** WAL plus a daily off-box backup,
and restore-from-backup is the recovery path (§11). The design does not assume clients can
rebuild them: a passive user's phone may not register for weeks.

**Logs:** tenant id, token-hash prefix, status, latency. Never payloads, never raw tokens,
never per-request IPs.

## 7. Live Activity flow, end to end (relay mode)

1. **App launch** — `pushToStartTokenUpdates` fires → the app obtains a challenge, builds an
   assertion, and POSTs `/register-start` to its own Trellis; Trellis forwards the claim to
   Canopy. Likewise `/register-device` for the alert-banner token. Both go through the
   persisted pending-claim queue in §10, so a failure is retried rather than lost.
2. **Print starts** — Trellis's poll loop sees a live state with no card and builds the
   push-to-start payload itself (`event: start`, attributes, and the mandatory `alert` block —
   the "APNs 200s then silently discards without it" lesson stays encoded in Trellis).
   `POST canopy /v1/push {push_type: liveactivity, priority: 10, payload}`.
3. **Card appears** — ActivityKit mints the per-activity update token; the app's
   `pushTokenUpdates` fires → `/register` with a fresh assertion → claim → bound.
4. **Updates** — on meaningful change Trellis builds the ContentState envelope (the `expo` vs
   `native` shape stays its concern) and pushes via Canopy at the priority it already chooses.
   End pushes carry `dismissal-date`, passthrough, followed by release.
5. **Feedback** — APNs status verbatim through the two-field result (§6); on 400/410 Trellis
   drops its registration exactly as today.
6. **Dismissal reconcile** — phone ↔ Trellis only; Canopy uninvolved. This is a **native-app
   gap that must be closed before relay ships**: the RN app posts `/sync`, but the native app
   only records a swipe locally (`cardVanished` → `dismissed.insert`,
   `LiveActivityController.swift:396-406`), so Trellis would keep a registration for a card the
   user swiped away, refuse to start a replacement (`_remote_start` gates on `key in _regs`,
   `app.py:441`), and push into the void at APNs 200 for the rest of the print — the exact
   deadlock `app.py:848-860` documents as "how the lock screen ended up empty mid-print".
   Sprout must call the token-scoped `/unregister` (§9) on `cardVanished`, and Trellis must
   release that binding.

**Stale dates are a change this design makes, not a capability it inherits.** Nothing sets one
today: la-push emits `timestamp`, `event`, `content-state`, `attributes`, `alert`, and
`dismissal-date` but no `stale-date` (`app.py:328-354`), `07-realtime.md:898` is a
*recommendation to the app* rather than a record of server behaviour, and the native app passes
`staleDate: nil` (`LiveActivityController.swift:291`, `:310`). So §11's "cards go visibly
stale" needs building: **Trellis gains a `stale-date` on every card push**, a small multiple of
`MIN_UPDATE_S` ahead of now, and Sprout's LOCAL-mode `ActivityContent(state:staleDate:)` stops
passing `nil`. Without this, a Canopy outage looks exactly like a slow print — a card showing
stale content with an ETA counting past zero, which is the lying card this is supposed to
prevent. Claiming it was already true was itself an instance of the repo's recurring bug,
inside the document that names it.

**Encryption, stated accurately.** The APNs *envelope* cannot be encrypted: `event`,
`dismissal-date`, `stale-date`, the push-to-start `attributes`, and the mandatory start `alert`
title and body are interpreted by iOS itself, and Apple provides no NSE-style mutation hook for
`apns-push-type: liveactivity`. The *content state* is different — ActivityKit only decodes it;
the widget renders it with code, so a ciphertext blob decrypted at render time with a key
shared via the existing App Group is technically possible. We do **not** do this in v1 (key
distribution, payload inflation, pre-first-unlock render edges), which makes it a deliberate
deferral (§14), not a physical impossibility. Printer and file names therefore transit Canopy
in plaintext under the no-persistence rules of §6 and §8.

## 8. Privacy posture (what the owner can and cannot see)

| Data | Canopy at rest | Canopy in transit | Notes |
|---|---|---|---|
| Push tokens | SHA-256 only | raw, per-request | needed to call APNs |
| Pairing secrets | SHA-256 only | raw, per-claim | durable home is the phone's Keychain only |
| App Attest public keys, counters, receipts | stored in `attest_keys` | — | private half never leaves the Secure Enclave; the receipt enables Apple's fraud metric (§14) |
| Push payloads (names, progress, temps) | **never** | plaintext, one forward | envelope is Apple's design; content-state encryption deferred (§7) |
| Tenant credentials and recovery codes | SHA-256 only | bearer over TLS | |
| User Bambuddy URLs / API keys / cameras / libraries | **never** | **never** | Canopy accepts inbound only |
| IP addresses | never (in-memory rate buckets only) | inherent to HTTP | not logged per-request |

Trellis-side: pairing secrets, `client_data`, and assertions transit but are never persisted.
The app's pending-claim queue holds intents (token, `binding_kind`), never signed claims or the
pairing secret.

## 9. Trellis changes

- **Rename** per §2. `docs/guides/push-notifications.md`, `deploy/README.md`, repo-root
  `CLAUDE.md`, and `docs/native-rewrite/` references updated. Collections, cooldown, p2s, and
  classify logic: untouched.
- **Two-backend APNs interface**: `DIRECT` (today's `.p8` env set — preserved for the owner and
  for self-signers on their own Apple team) and `RELAY` (`CANOPY_URL`). Exactly one must be
  configured; both or neither fails at startup. The backend returns the two-field result of §6,
  and both backends must be observably equivalent to the existing token-hygiene code.
- **Enrollment and recovery**: in relay mode, on first boot with no stored credential, Trellis
  calls `/v1/enroll` and stores the tenant credential **and the recovery code** at
  `DATA_DIR / "tenant.json"` (`DATA_DIR` defaults to `/data`, `app.py:54`). It also logs the
  recovery code once at startup and exposes it on the authenticated `/health`, so the
  self-hoster can save it somewhere that survives the data volume. A rebuild that supplies the
  recovery code re-adopts the same tenant, which is what keeps §1's "zero manual unbinding"
  promise true when the server *and* the app's anchors are lost together — otherwise that
  combination (new tenant, no anchors, token still live) has no path but an operator unbind.
  Enrollment failure is **not** fatal: retry with the §6 backoff, serve everything except push,
  report `enrolled: false` on the authenticated `/health`.
- **`stale-date` on every card push** (§7) — new behaviour, not a rename.
- **Phone-facing authentication is unchanged.** Every phone-facing endpoint — registrations,
  `/sync`, `/unregister`, collections — remains gated by `_require_key`, the existing
  `X-API-Key` check delegated to that user's Bambuddy (`app.py:753-777`). **The pairing secret
  is binding authority at Canopy; it is not authentication at Trellis.**
- **`/health` is split.** The unauthenticated route keeps `{ok: true}` for container health
  checks; counts, `push_suspended`, `needs_claim`, `enrolled`, the recovery code, and anything
  token-derived move behind `_require_key`.
- **A device identity, because three new behaviours need one.** Both phones in a household
  present the same Bambuddy API key, so Trellis currently cannot tell them apart — yet §9
  requires per-device scoping in three places. Trellis mints a `device_id` at `/register-start`
  and the app echoes it on every subsequent call. `/sync` then drops only the reporting
  device's own tokens, `needs_claim` returns only the requesting device's tokens, and the p2s
  pending claim is keyed per device. Without it, phone A's `needs_claim` would list phone B's
  tokens, phone A would assert over them, R4 would accept (same tenant), and the two phones
  would ping-pong each other's bindings until the elder budget ran out.
- **Claim forwarding**: every registration forwards a claim synchronously. "Forward and forget"
  means Trellis never *persists* the pairing secret — it must still act on the response. A
  registration succeeds to the phone only when the claim returned a definitive answer; a
  transport failure returns `502` so the app retries.
- **Relay-mode gate uses two named predicates**, not field presence: `claimVerified` (Canopy
  returned `204` — only Canopy can answer this) and `isNativeClient` (`client == "native"`).
  Relay mode **forces** `NATIVE` rather than letting `norm_client`'s deliberate leniency
  (`clients.py:54-62`) default a mangled discriminator to `EXPO` and silently send the wrong
  envelope shape. Rejection reasons distinguish `attestation_unsupported` (the device cannot
  attest, §10) from `attestation_missing` (it can but did not).
- **Push-suspension, split by question.** `not_owner` means authority was taken: suspend that
  **token**, persist the flag in `registrations.json` so a restart cannot resume retry-spam,
  surface it on the authenticated `/health` and in the app, and clear it only on a `204` claim
  for that token. `not_bound` means nobody holds it — routine after a release or expiry, and
  the fleet-wide condition after a Canopy restore gap. It does **not** suspend; it adds the
  token to `needs_claim`, which the app acts on. Conflating them would make ordinary
  housekeeping look like an attack and suspend every token on a Trellis at once.
- **Multiple phones per printer.** `_regs[key]` becomes a **list** of registrations. This is
  larger than one call site — `grep -c _regs deploy/la-push/app.py` is 27 — and the plan must
  sweep all of them. Specifically: `lastState`, `lastPush`, `client`, `iconUri`, and
  `printerName` are **per registration**, so gating (`meaningful_change`, `MIN_UPDATE_S`) and
  envelope construction happen per entry — otherwise a phone joining mid-print shares a gate it
  never saw content through and sits frozen, and one expo plus one native phone on one key
  needs two differently-shaped payloads. `/sync` drops only the reporting device's tokens
  (`app.py:864-866` currently drops any token absent from one device's list). `/unregister`
  becomes **token-scoped** (`app.py:928` currently pops the whole key), which is also what §7
  item 6 needs. The 400/410 drop removes one entry, not the list. `_load()` migrates existing
  `registrations.json` dict values to single-element lists (`app.py:248`).
- **Push-to-start pending claims: serialise per device, not globally.** `_p2s_pending` is
  global today for a stated reason (`app.py:196-204`): a card is identifiable only by its push
  token, so two simultaneously-pending starts could not be told apart and would bind
  arbitrarily. Keying by `(key, token)` alone would reinstate exactly that ambiguity, because
  one phone can have a print card and up to three drying cards pending at once. The rule is
  therefore: **at most one unresolved start per device**, with the device identity above — which
  preserves the original disambiguation while letting two phones each adopt their own card.
- **Relay mode is native-app only.** The RN app cannot produce an App Attest assertion, so in
  relay mode Trellis rejects its registrations with a stated reason and the docs say the RN app
  requires DIRECT mode. This removes revision 1's server-minted fallback secrets — both the
  weakest link in the model and the cause of a data-volume-loss lockout. The RN app remains
  personal/TestFlight, never App Store. `/sync` therefore serves DIRECT mode only; relay-mode
  reconcile is the native path in §7 item 6. The owner's own two-phone dogfooding happens in
  DIRECT mode, so the `/sync`, `/unregister`, and p2s fixes above matter there too.

## 10. Sprout changes

- **App Attest**: generate the key once via `DCAppAttestService.shared.generateKey()`, persist
  `keyId`, attest on first claim, assert on every later one. Follow Apple's error guidance:
  `DCError.serverUnavailable` → retry with the *same* key and client-data hash (which is why §6
  challenges are single-*success*); any other error → discard the key id and generate a new
  one. Handle `403 reattest_required` by generating a new key and sending a fresh attestation.
- **When attestation is unavailable, say so.** `isSupported` is false in the Simulator, on
  Apple silicon Macs running iOS apps (opt the App Store listing out of Mac availability, or
  state Mac installs are LOCAL-mode only), in app extensions, and on a small fraction of genuine
  devices. Those installs show the explicit push-health row — "Push isn't available on this
  device" — rather than silently 403ing into nothing. No secretless fallback: the correct answer
  is a stated limitation, not a hole.
- **Pairing secret**: 32 bytes, Keychain item `bambu.pairing`, separate from `AppConfig` so
  sign-out or re-onboarding never destroys it.
- **Keychain accessibility, including a migration for existing installs.** The whole
  registration credential set must be background-readable: the POST also needs the API key and
  the Trellis URL, which live in `AppConfig` under `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  (`SecureConfig.swift:92`). The canonical background wake is a push-to-start arriving while the
  phone is locked in a pocket — Apple grants background runtime there — and a `WhenUnlocked`
  read fails at exactly that moment, so the claim never leaves the phone and the
  remotely-started card freezes at its start content. Move the pairing item, the attest key id,
  and a minimal `{pushUrl, apiKey}` item to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  still `ThisDeviceOnly`. **Changing that line alone fixes nothing for anyone already
  onboarded**: `kSecAttrAccessible` is set only on the add branch (`SecureConfig.swift:80-94`),
  and the update branch never re-states it, so every existing install would keep `WhenUnlocked`
  forever. Add a one-shot launch migration that re-states the attribute via `SecItemUpdate`'s
  attributes dictionary (no delete needed, so the device is never briefly credential-less).
- **A persisted pending-claim queue covering all three registrations.** Today only `/register`
  retries: `flushRegistrations()` runs every 4 s against a `registered` set
  (`LiveActivityController.swift:455-471`). `/register-start` is a fire-and-forget POST inside
  the `pushToStartTokenUpdates` loop whose result is discarded and which only iterates again on
  token rotation (`:346-355`), and `/register-device` does not exist on the client at all
  (`00-overview.md:116`). So a brand-new install whose first claim meets a down Canopy never
  registers a start token for the whole process lifetime — the worst state the controller's own
  header comment describes. All three go onto one persisted queue holding *intents* (token,
  `binding_kind`) with the same retry discipline, re-attempted on foreground, on every
  token-stream emission, and on the `needs_claim` list from Trellis's `/health`.
- **APNs environment from the entitlement, not the build configuration.** Revision 1 derived it
  from `#if DEBUG`, a proxy for the real question: a `-configuration Release` build installed
  via Xcode/devicectl — the repo's everyday device recipe — is development-signed, so its tokens
  are sandbox while `#if DEBUG` is false. Read `aps-environment` from the running task's
  entitlements (falling back to the embedded provisioning profile where unavailable):
  `development` → `sandbox`; absent or `production` → `production`. There is no `#if DEBUG`
  fallback — "absent → production" already gives the right answer for App Store builds, and
  keeping the proxy would only let the original bug back in. Canopy's gateway retry (§6) is the
  safety net.
- **Dismissal reconcile**: call the token-scoped `/unregister` on `cardVanished` (§7 item 6),
  and stop passing `staleDate: nil` in LOCAL mode (§7).
- **Push health in the UI**: read Trellis's authenticated `/health` and show actionable rows —
  "Push needs re-pairing", "Push isn't available on this device", and, when a token accumulates
  repeated `pairing_mismatch` from a consistent claimant, "Push pairing was taken over" with a
  path to the operator unbind. A limitation the user discovers by silence is the failure mode
  this codebase keeps rediscovering.
- **Background refresh is a supplement, not a guarantee.** A `BGAppRefreshTask` refreshes the
  start and device claims, but iOS schedules it opportunistically and weights it by how often
  the user foregrounds the app — so it is least likely to run for the passive user it would most
  help, and never after a force-quit. The deterministic paths are re-claim on foreground, on
  every token-stream emission, and in response to `needs_claim`; and Canopy treats its own
  database as durable state rather than something clients rebuild (§6).
- **Registration bodies** gain `client_data`, `pairing_secret`, `binding_kind`,
  `apns_environment`, `attest_key_id`, `attestation`/`assertion`, and the `device_id` echo —
  snake_case, tested like the existing fields. `binding_kind` is distinct from the existing
  `kind` (`print | dry`) in the same body.
- **URL sourcing**: challenges, claims, and the push-health read use `resolvePushUrl` (they are
  push); collections keep `laPushUrl` (they are not).
- `ConfigRules` derivation becomes `bambuddy.` → `trellis.`; explicit `pushUrl` still wins; the
  RN app's `lapush.` derivation is untouched (the owner keeps a `lapush.` CNAME during the
  transition). The push on/off toggle and the `laPushUrl` vs `resolvePushUrl` split are already
  correct and unchanged.

## 11. Failure modes

| Failure | Behavior |
|---|---|
| Canopy down | Pushes and claims fail; Trellis retries with the §6 backoff; registrations return 502 and enter the app's pending-claim queue (§10); cards visibly stale once §7's `stale-date` ships; LOCAL-mode users unaffected. |
| Trellis has never enrolled | Serves everything except push, retries enrollment, reports `enrolled: false` on the authenticated `/health` (§9). |
| Canopy database lost | Restore from the daily backup — the recovery path, because attest keys cannot be reconstructed by clients. Without a restore, assertions fail, Canopy answers `reattest_required`, and each install re-attests on its next claim, which for a passive user may be weeks away. |
| Push rejected `403 not_owner` | Token suspended, surfaced in `/health` and the app, cleared by a successful re-claim. |
| Push rejected `403 not_bound` | Not a suspension — the token joins `needs_claim`, which the app acts on (§9, §10). |
| Trellis down / server rebuilt, credential restored or recovery code used | No pushes meanwhile; the phone's next registration restores everything (R1). |
| Server rebuilt **and** the app lost both anchors, recovery code available | Recovery code preserves tenant identity → R4 accepts a fresh attestation → self-heals. |
| Server rebuilt **and** the app lost both anchors **and** no recovery code | The one combination with no automatic path: new tenant, no anchors, and a token still live enough never to go dormant. Operator unbind (§14). The self-hoster guide must say to save the recovery code; §9 logs it and exposes it on `/health` for that reason. |
| Attacker seizes a binding (compromised Trellis, hooked app via R4) | Junk pushes to that user's own devices only. R3 evicts on the phone's next claim inside the 90 d elder window; R4 is capped at once per window so it cannot be replayed to lock the victim out. |
| Someone else first-claimed a token Canopy had never seen | The residual in §4. The victim's claims get `pairing_mismatch`; the consistent-claimant alert fires for the operator and surfaces in the app; recovery is operator unbind. |
| Phone loses both anchors, same tenant | R4 accepts a fresh, previously-unseen attest key and self-heals silently. |
| Token genuinely abandoned (no delivery or claim for 90 d) | R5 rebinds, prior anchors retained as elder for 90 d — reachable because `start`/`device` rows survive to 120 d (§6). |
| Wrong APNs environment on a claim | The first `BadDeviceToken` triggers the other-gateway retry with that gateway's key, correcting the stored `apns_environment` for the row's lifetime (§6). |
| APNs key compromised | Owner revokes and uploads a new key; zero tenant or user action (invariant 5). Bundle-scoped keys keep the blast radius inside this app. |

## 12. Testing

- **Canopy (Go)**: table-driven tests over the binding state machine that **feed one claim and
  assert which rule fired**, not one test per rule — a per-rule suite is structurally incapable
  of catching two rules matching one input, which is how revision 3's overlaps survived. Cases
  must include: R1 does not clear elder; R3 clears elder and evicts; R4 refused for a
  previously-seen attest key, refused for a different tenant (`wrong_tenant`, distinct from
  `pairing_mismatch`), refused twice in one elder window, and retaining elder when accepted; R5
  reachable at 91 d and refused at 89 d; a stranger-tenant claim against a lease-expired row
  refused, and against a released row refused; per-kind arithmetic asserted as
  `hard_delete(kind) - lease(kind) > dormancy` for every kind where R5 applies. Crypto: real
  captured fixtures plus negatives for a missing or altered credCert nonce extension, a resigned
  assertion, swapped `authenticatorData`, wrong `rpIdHash`, an aaguid with a valid `appattest`
  prefix and **non-zero** suffix bytes (the only input that distinguishes exact from prefix
  comparison), a re-attestation of a known key carrying the opposite environment's aaguid, a
  replayed challenge, a challenge issued to tenant A presented by tenant B, an
  attestation-purpose challenge presented with an assertion, a non-increasing counter, and an
  expired certificate against an injectable clock — plus the **positive** case that a challenge
  survives an `attestation_invalid` and validates on the next attempt with identical inputs
  (the assertion that would have caught revision 2's unretryable claims). Also: the shared
  `client_data` golden fixture; a fake APNs server for passthrough, 410 unbind, and the
  `BadDeviceToken` retry swapping host *and* key; topic forcing and priority clamping; release,
  cap accounting via `released_at`, and GC; rate limiting, failed-claim backoff, the per-key
  tenant cap, and a load case asserting saturated claim traffic does not trip the global push
  breaker.
- **Trellis (Python, stdlib unittest as today)**: both backends observably equivalent to the
  existing token-hygiene code, including **"a Canopy 400 does not delete a registration"**;
  claim forwarding and the 502 contract, including a claim retried after a timeout Canopy
  actually processed; `not_owner` suspends and `not_bound` does not; suspension persistence
  across restart; multi-registration fan-out for two phones on one printer, per-registration
  gating state, token-scoped `/unregister`, phone A's `/sync` not dropping phone B's
  registrations, phone A's `/health` not listing phone B's `needs_claim` tokens, two pending
  starts for one device binding correctly or not at all (never arbitrarily), and the
  `registrations.json` dict→list migration; release on card end; every card push carrying a
  future `stale-date`; unauthenticated `/health` revealing no token prefixes or recovery code;
  enrollment failure non-fatal and recovery-code re-adoption; startup fail-hard on ambiguous
  backend config; rejection of unattested registrations in relay mode.
- **Sprout (XCTest)**: registration body encoding and the `client_data` golden fixture, asserting
  `binding_kind: "activity"` on a `/register` post whose `kind` is `"dry"`; Keychain pairing and
  attest-key lifecycle, survival of a config wipe, readability after first unlock, and **the
  migration of an item previously written as `WhenUnlockedThisDeviceOnly`**, asserted via
  `SecItemCopyMatching` with `kSecReturnAttributes`; environment derivation from entitlement
  fixtures (development, production, absent); pending-claim queue retry for all three
  registration types, including "start-token registration fails and is retried without a token
  rotation"; `isSupported == false` surfaces the push-health row. App Attest itself is exercised
  on a real device during rollout.

## 13. Rollout

Four implementation plans plus a fixture harness, each its own spec-to-plan cycle. Canopy's
attestation tests need real-device artefacts, so the harness comes first.

0. **Attest-capture harness** — a debug-only affordance (or throwaway build) that, given a
   challenge string on a real device, dumps an attestation and a *sequence* of follow-on
   assertions to files. Sequences matter because Canopy asserts a strictly increasing counter,
   and sandbox and production fixtures differ by aaguid, so both are captured.
1. **Canopy service** — build and deploy behind Caddy. Unit-verify against the step-0 fixtures
   with an injectable clock and injected challenges; live-verify the parts needing no
   attestation (topic forcing, priority clamp, rate limits, APNs passthrough against a fake
   server).
2. **Trellis relay mode** — the two-backend interface with the two-field result, enrollment,
   recovery codes and failure paths, claim forwarding, the suspension/needs-claim split,
   release, `stale-date`, `/health` gating, device identity, and the multi-registration registry
   change with its full 27-site sweep.
3. **Sprout pairing** — App Attest, the Keychain moves and migration, entitlement-derived
   environment, the pending-claim queue, dismissal reconcile, push-health UI, and the new body
   fields. The first true end-to-end sandbox test happens here, on a real device.
4. **Rename, dogfood, distribute** — la-push → Trellis across dirs, container, and docs; owner
   DNS gains `trellis.<domain>` and keeps `lapush.<domain>` as a CNAME; the owner flips his own
   Trellis to relay mode (DIRECT stays supported and tested); write the self-hoster guide with a
   one-file compose bringing up Bambuddy + Trellis with `CANOPY_URL` preset **and instructions
   to save the recovery code**; then App Store submission, which needs a reachable demo Bambuddy
   + Trellis with demo credentials.

## 14. Out of scope / future hardening

- **Apple's fraud-assessment metric** — the receipt is stored at attestation time (§6) precisely
  so this can be enabled later without re-attesting every install. It is the mechanism that
  bounds §4's stated residual risk (a hooked app on a jailbroken device).
- **Pairing-secret rotation.** Removed from v1 because shipping the protocol field without a UI
  left a transition only an attacker could reach. To reintroduce with a "Reset push pairing"
  control: a rotation claim that also matches the current attest key may overwrite elder freely
  (the device is proven); one that matches only the old pairing secret must be refused while a
  live elder exists, and must retain the outgoing anchors as elder.
- **Encrypted content-state** for the native client (ciphertext decrypted in the widget with an
  App-Group-shared key), removing printer and file names from Canopy's view entirely. The
  envelope still cannot be encrypted (§7).
- Alert banners end-to-end encrypted via a notification service extension.
- Android/FCM — a `platform` field on `/register-device` and a second sender in Trellis
  (`docs/guides/android.md`); Canopy would gain an FCM credential and a topic-table entry, with
  Play Integrity replacing App Attest as the device anchor.
- A payload-scrubbing knob (user opts filenames out of push payloads at the Trellis level).
- Operator tooling beyond manual unbind by token hash, which **is** in scope as the support
  backstop for a stuck or seized binding.
