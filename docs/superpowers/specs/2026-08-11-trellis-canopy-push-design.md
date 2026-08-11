# Trellis + Canopy: multi-tenant push for App Store distribution

**Status:** approved design, not yet implemented
**Date:** 2026-08-11
**Revision:** 8 — vouching (§5), corrected. Revision 7 introduced it and got the scope wrong in
the way this document keeps getting things wrong: the vouch was recorded per *install* rather
than per *token*, which handed any attacker a permanent exemption after one round-trip on a
token they owned, and was therefore itself a cross-user takeover. Revision 8 keys it by token,
tenant and 10-minute nonce, and stops claiming coverage it does not have — push-to-start and
per-activity tokens cannot receive a silent push, so their leaked values remain first-come,
with the real bounds stated in §4. Revision 6 was a
simplification, after five adversarial review rounds in which *every round
found blockers inside the machinery the previous round had added*. Revisions 1–5 chased one
root cause without naming it: the pairing anchor was a **shared secret**, so it had to transit
Trellis on every claim, so a compromised Trellis could replay it — and elder anchors,
tombstones, monotonic rebind clocks, split refusal codes, and per-device fences all existed to
make that survivable. Revision 6 replaces the secret with a **keypair** and scopes out
defending a user against their own compromised server. The state machine goes from eight rules
to three, and every mechanism that existed only to contain the shared secret is deleted. The
process lesson is kept in §12: prose review found real bugs for three rounds, but only formal
enumeration of the state machine's input space found the rest, so the tests assert *which rule
fired* on a single input rather than testing rules in isolation.

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
- no user can push notifications to another user's devices. A stolen **device** token value is
  worthless: the token must prove it is reachable on the claiming device before it can be bound
  (§5). Push-to-start and per-activity tokens cannot be vouched that way — Apple offers no
  silent push for them — so their leaked values remain first-come, bounded and stated in §4
  rather than papered over. Both residuals are named, not dissolved;
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
                   │ /register* (+ pairing-key signature + App Attest proof)
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
7. **Two questions never share one field or one predicate.** Six pairs here read as synonyms
   and are not: APNs environment vs App Attest environment; `not_bound` vs `not_owner`; a
   Canopy HTTP status vs an APNs status; authentication at Trellis vs binding authority at
   Canopy; Canopy's `binding_kind` vs Trellis's `kind`; "no row exists" vs "the row's lease
   expired". Each was a real defect in an earlier revision of this document, caught by the
   repo's own recurring-bug rule. A seventh — "which device is this?" answered by a value
   stored beside the anchor whose loss defines the case — killed revision 5's recovery rule
   outright, and is why `device_id` is now a Trellis-side scoping key and never a Canopy gate.

## 4. Threat model

Assets: the APNs keys (each signs pushes for every install of the app), users' push tokens,
users' print metadata (printer names, filenames — they transit push payloads), Canopy's
tenant credentials.

| Adversary / scenario | Outcome under this design |
|---|---|
| Attacker steals a push token and tries to bind it with `curl` | Fails. Every claim carries two signatures over the exact claim contents — an App Attest proof from a genuine Sprout install and a P-256 signature by the pairing key — each verified against a value Canopy already holds. A tenant credential alone is not enough, and neither private key ever leaves the phone. |
| Hooked genuine app on a jailbroken device, holding a stolen **device** token value (logs, LAN sniff, stale `registrations.json`) | **Closed by vouching (§5).** Canopy silently pushes a nonce to that exact token and requires it echoed. The vouch is per token, per tenant, single-use and 10-minute — revision 7 made it a standing per-install exemption and that was itself a cross-user takeover. |
| The same attacker holding a stolen **push-to-start or per-activity** token value | **Open, and irreducible with Apple's primitives** — neither kind can receive a silent push, and Canopy cannot verify that two tokens belong to one install. Bounded by: the value must leak from the victim's own garden; an attacker who still controls that Trellis needs none of this; the legitimate app claims on token issuance and normally wins the race; `activity` tokens die with their card and `start` tokens rotate; the harm is spoofed lock-screen content, not data access; recovery is the operator unbind (§14). |
| The same attacker, running the hooked app **on the victim's own device** | **Succeeds — the design's remaining residual, stated plainly.** A token that has never been claimed is bound first-come (there is no prior anchor to check against), so an attacker who both obtains a live unseen token and runs a hooked build can take it, and the victim's later claim is refused. Bounds: re-signing under another team fails the App ID check, so it takes a jailbroken device; one attest key may hold live bindings across at most three tenants; repeated `pairing_mismatch` from a consistent claimant raises an operator alert *and* a user-visible "push pairing was taken over" row (§10); and Apple's fraud-assessment metric closes it further once enabled (§14). Recovery is operator unbind (§14, in scope). |
| Attacker tries to take over a token that **is** already anchored | Refused. A row's anchors are checked on every claim regardless of lease state — an expired or released row is *not* first-claimable, only a hard-deleted one is (§5). |
| Attacker waits out a lease | Closed. Leases renew on successful delivery as well as on claims, and neither expiry nor release opens a token to a new claimant — only an explicit delete by the bound tenant, 90 days of total inactivity, or APNs declaring the token dead does. There is no timed rebind path to wait for. |
| Attacker enrolls tenants and probes tokens | Tokens are 32-byte APNs-generated values; guessing is infeasible. Cheap checks run before expensive ones (§6), so a failed claim costs no X.509 work. Per-IP and per-tenant limits, per-token-hash failed-claim backoff, a bounded tenant count, and an auto-arming invite code cap the probe rate. Attestation verification has its own bounded worker pool so claim floods cannot starve `/v1/push`. |
| A user's Trellis box is fully compromised | **Explicitly out of scope, and stated in §5 rather than defended against.** The attacker can push junk to that user's own devices and can delete a binding and re-claim it, denying that user push. This is not a regression: a compromised companion service today already owns that user's printer, library, camera, Bambuddy credentials, and every push they receive. What it **cannot** do is reach another user — it observes no secret it can replay, since both proofs are signatures over single-use, tenant-bound challenges, and it can never obtain a claim for a token it does not already hold. Five revisions of machinery aimed at this row were the sole source of this design's complexity and its recurring defects. |
| A tenant floods pushes (hostile or broken) | Per-token, per-tenant, and per-IP limits. Shedding is tenant-scoped first; the global breaker is a last resort, so one abuser cannot deny push to everyone. |
| Canopy itself is compromised | The attacker holds the APNs keys → arbitrary push to all installs until revocation. Bundle-scoped keys keep the blast radius inside this app. Mitigations: minimal surface (static Go binary, three dependencies), no payloads or raw tokens at rest, TLS via reverse proxy, monitoring, WAL plus daily off-box backups, rotation needing no tenant action. |
| Someone who knows a public Trellis URL registers their own token | Rejected by Trellis's existing `X-API-Key` gate, delegated to that user's Bambuddy (`app.py:753-777`) and unchanged here. Trellis's `/health` gains the same gate for anything beyond liveness (§9). |
| The owner snoops on users | Sees per-push: raw token and payload, in memory, for one HTTPS forward. Stores only hashes, public keys, and counters (§8). Cannot reach any user's Bambuddy. A documented trust statement, not cryptography — §7 for what is encryptable, §14 for the deferred option. |

## 5. Device identity and binding

Ownership rests on **two keypairs held by the phone**. Neither is a shared secret, and that is
the load-bearing choice:

- **An App Attest key** (`DCAppAttestService`), private half sealed in the Secure Enclave and
  non-exportable. Proves "a genuine Sprout install on a real Apple device made this exact
  request." Apple documents that these keys do not survive app reinstallation, device
  migration, or restore from backup.
- **A pairing key**, a P-256 keypair generated by the app at first launch, private half in the
  Keychain (`ThisDeviceOnly`, `AfterFirstUnlock`), public half registered with Canopy on the
  first claim for a token. Survives app reinstall in current iOS behaviour and survives direct
  device-to-device migration; lost on restore-from-backup, which also changes the APNs tokens.

**Why a keypair rather than the shared pairing secret earlier revisions used.** A secret has to
transit Trellis on every claim, so a compromised Trellis — or a LAN observer on a plain-HTTP
deployment — could replay it and seize the binding. Revisions 3 through 5 accumulated elder
anchors, tombstones, monotonic rebind clocks, split refusal codes, and per-device fences trying
to make that survivable, and each mechanism bred defects of its own: five review rounds each
found blockers, every time inside the machinery the previous round had added. With a keypair
nothing secret ever leaves the phone. Trellis relays a signature over a single-use,
tenant-bound challenge; it can neither reuse nor alter it. The entire elder apparatus is
deleted along with the problem it existed for.

**Scope, stated plainly.** Canopy's job is to prevent **cross-user** harm. Inside one user's
own garden their Trellis is trusted, because it already is: a compromised companion service
today owns that user's printer, library, camera, Bambuddy credentials, and every push they
receive. A fully compromised Trellis can therefore still push junk to its own user and, by
deleting a binding and re-claiming, deny that user push. It cannot touch any other user. We do
not build machinery to survive a compromise of the user's own server — attempting to was the
sole source of this design's complexity, and it protected against an adversary already inside
the perimeter it was defending.

### Token states

- **UNSEEN** — no row. A claim binds it first-come.
- **BOUND** — a row exists. **Every claim runs the anchor test below**, regardless of lease
  state; lease expiry and release affect cap counting and push authority, never claimability.
- A row returns to UNSEEN only by explicit delete (below), by dormancy, or by APNs declaring
  the token dead.

Push authority is a separate question: a push is allowed only from the tenant on a row with a
live lease; otherwise `403 not_bound` (no row, released, or expired) or `403 not_owner`
(another tenant holds it).

### Claim protocol

A claim attempt is an **indivisible unit**: obtain a challenge, sign, POST. It is not
replayable — the nonce is consumed on success and the Secure Enclave counter advances — so
**every retry acquires a fresh challenge and generates fresh signatures**. Claims are not
idempotent in the HTTP sense; repeated attempts converge on the same binding state. What the
app queues (§10) is therefore an *intent* to claim, never a signed claim.

1. The app asks its Trellis for a challenge; Trellis calls Canopy `POST /v1/challenges`
   (tenant-authed) and returns the opaque nonce. A challenge is consumed **on success**, not on
   presentation, so Apple's documented `DCError.serverUnavailable` retry — same key, same
   client-data hash — still validates. TTL is 15 minutes for attestations (Apple asks that
   attestation retries reuse identical inputs, to preserve the device's risk metric) and 120
   seconds otherwise. Canopy records the issuing tenant and the purpose and **checks both when
   the challenge is presented** (§6).
2. The app builds `client_data`, a JSON object over `{challenge, token, pairing_public_key,
   device_id, binding_kind, apns_environment}`, and produces **both**: an App Attest proof
   (an attestation on first use of a new attest key, an assertion afterwards) and a **P-256
   signature by the pairing key**, each over `SHA-256(client_data)`.
3. The app POSTs its normal registration to Trellis (`/register`, `/register-start`,
   `/register-device`) with the new fields; Trellis forwards them to Canopy `/v1/claims`.
4. Canopy verifies both proofs (§6) against **the exact `client_data` bytes the app sent** —
   transmitted base64, never re-serialised server-side — then checks that the fields parsed out
   of those bytes equal the corresponding top-level claim fields. Re-serialising would make a
   security check depend on `JSONEncoder` and `encoding/json` agreeing byte-for-byte forever;
   WebAuthn transmits `clientDataJSON` verbatim for the same reason. `client_data` is UTF-8
   JSON, snake_case keys sorted lexicographically, no whitespace, absent optionals omitted
   rather than null, no HTML escaping — pinned by a golden fixture shared between the Go and
   XCTest suites (§12), with unknown extra fields tolerated on parse.

**`binding_kind` (`activity | start | device`) is not Trellis's `kind` (`print | dry`).** Both
travel in one POST body, and Trellis's drives the `dry:<pid>:<amsId>` registry key
(`app.py:787`). The app sends both explicitly; Trellis cannot supply `binding_kind` after the
fact, because it is inside the signed `client_data`. It is **immutable after the first bind**,
for the same reason `apns_environment` is — it is a property of the token, not of whoever
holds it, and it selects the lease and retention horizons. A claim disagreeing with the row is
`403 kind_mismatch`.

**The app claims only tokens it holds.** The pending-claim queue (§10) is populated exclusively
from the app's own ActivityKit and APNs token streams. Trellis's `needs_claim` list is a
*signal to re-claim tokens the app already has*, intersected against that set — never a list of
tokens to go and claim. Read the other way it would be an attestation oracle: a compromised
Trellis could name another user's stolen token and have an honest phone sign a valid claim for
it, which is precisely the cross-user harm this design exists to prevent, obtained without the
jailbroken device §4's residual assumes.

### Binding state machine

Binding row: `{token_hash, binding_kind, apns_environment, tenant, device_id,
pairing_public_key, attest_key_id, lease_expiry, last_delivery_at, last_successful_claim_at,
released_at, created_at}`. Attest keys live in their **own table** with a lifetime independent
of any binding (§6) — they must outlive the bindings they were used to claim.

Every rule requires **both** proofs to verify cryptographically first; a claim missing or
failing either is `403 attestation_required` / `403 attestation_invalid` and never reaches the
machine; so is a claim whose pairing signature fails (`403 pairing_signature_invalid`). **Rules are evaluated in order, first match wins.** Every accepting rule renews the
lease, clears `released_at`, stamps `last_successful_claim_at`, and re-points `tenant` and
`device_id` to the claimant — stated once here, because stating it per-rule is how revision 4
lost `released_at` and revision 5 lost R3's tenant re-point.

| # | Guard | Action |
|---|---|---|
| R0 | Token is UNSEEN, and — for `binding_kind: device` — this **exact token** has been vouched by the claiming tenant (below) | Bind: store `pairing_public_key`, `attest_key_id`, tenant, `device_id`, `binding_kind`, `apns_environment`. |
| R1 | The pairing signature verifies against the row's stored `pairing_public_key` | Accept — the primary path, and the durable one. Update `attest_key_id` from this claim, since the attest key legitimately changes on every reinstall while the pairing key does not. |
| R2 | The pairing key differs, but the App Attest proof verifies against the row's stored `attest_key_id` | Accept — the Keychain-lost-but-app-not-reinstalled case. Store the new `pairing_public_key`. |
| R3 | Otherwise | `403 pairing_mismatch`, counted per token-hash for backoff and operator alerting (§6). |

Three rules, and each is a signature check against a value the row already holds. There is no
rule any party can satisfy by presenting something they merely *observed* — which is what
collapsed the previous revisions' rule count from eight to three.

### Vouching: the token proves itself

R1 and R2 answer "is this the device that owned this token before?" R0 cannot — the token has
no history — and for six revisions this document called that an inherent floor, on the grounds
that only Apple knows which device an APNs token belongs to. That is true of *Canopy asking
Apple*. It is not true of **Canopy asking the token**.

Before an UNSEEN **device** token may be bound, Canopy sends a **silent push**
(`apns-push-type: background`, `content-available: 1`) carrying a random nonce **to that exact
token**, and requires the claim to echo the nonce inside the signed `client_data`. Only the
install that actually receives the push can answer, so a stolen device-token *value* — from a
victim's logs, a LAN sniff, a stale `registrations.json` backup — is worthless no matter how
genuine the attacker's App Attest proof.

**Vouching is per token, and it does not transfer.** Revision 7 recorded the vouch against the
install and treated a pairing key, once vouched by any round-trip, as exempt for every later
token. That was a cross-user takeover: an attacker vouches their *own* device token, receives a
standing exemption, and then binds a victim's token with no round-trip at all — faster than the
victim's own fresh install, which still has to complete one. It is the failure this document
keeps cataloguing: "is this install reachable on *some* token it holds?" is not "is this
claimant reachable on *this* token?", and one predicate was answering both. Vouch state is
therefore keyed by `token_hash`, scoped to the tenant that requested it, single-use, and
expires in 10 minutes. There is no standing exemption of any kind.

**What vouching does not cover, stated plainly.** A silent push can only be delivered to a
*device* token. Push-to-start and per-activity tokens cannot receive one — the only pushes
their kind accepts are a visible Live Activity start or update — so **their values cannot be
vouched, and an UNSEEN `start` or `activity` token remains first-come.** No amount of
indirection fixes this: Canopy cannot verify that two tokens belong to one install, because
only the device knows that, and in this threat model the device's app is the hooked party. The
honest bounds on the residual:

- the token value has to leak from the user's own garden in the first place (their Trellis,
  their logs, their backups, their LAN);
- an attacker who *currently* controls that Trellis is already the bound tenant and needs none
  of this — so the window is specifically a stale leak against a garden the attacker no longer
  controls;
- the legitimate app claims each token immediately on issuance from its own token streams, so
  it normally wins the race;
- `activity` tokens die with their card, and `start` tokens rotate;
- the blast radius is spoofed lock-screen content, not access to Bambuddy, cameras, library or
  printer control;
- recovery is the operator unbind (§14), and repeated `pairing_mismatch` from the legitimate
  device raises the alert.

Mechanics:

- Vouching happens on the `/register-device` claim, which does not exist on the client today
  (`00-overview.md:116`) and which §10 already lists as required work. It becomes the **first**
  registration a fresh install performs.
- Delivery is best-effort: iOS throttles background pushes and may delay them on a low-power
  device. A claim launched from the foreground — the normal case, since the app registers at
  launch — takes the foreground delivery path and is prompt. If the nonce does not arrive the
  claim simply fails and the §10 queue retries; nothing is ever bound provisionally, because
  "provisionally bound" is precisely the sort of extra state that produced this document's
  earlier defects.
- A hooked app on the *victim's own* device does receive the push, so vouching does not close
  §4's jailbroken-device row. It closes the far more reachable one: a stolen device-token value.

### Binding state machine

Binding row: `{token_hash, binding_kind, apns_environment, tenant, device_id,
pairing_public_key, attest_key_id, lease_expiry, last_delivery_at, last_successful_claim_at,
released_at, created_at}`. Attest keys live in their **own table** with a lifetime independent
of any binding (§6) — they must outlive the bindings they were used to claim.

Every rule requires **both** proofs to verify cryptographically first; a claim missing or
failing either is `403 attestation_required` / `403 attestation_invalid` and never reaches the
machine; so is a claim whose pairing signature fails (`403 pairing_signature_invalid`). **Rules are evaluated in order, first match wins.** Every accepting rule renews the
lease, clears `released_at`, stamps `last_successful_claim_at`, and re-points `tenant` and
`device_id` to the claimant — stated once here, because stating it per-rule is how revision 4
lost `released_at` and revision 5 lost R3's tenant re-point.

| # | Guard | Action |
|---|---|---|
| R0 | Token is UNSEEN, and — for `binding_kind: device` — this **exact token** has been vouched by the claiming tenant (below) | Bind: store `pairing_public_key`, `attest_key_id`, tenant, `device_id`, `binding_kind`, `apns_environment`. |
| R1 | The pairing signature verifies against the row's stored `pairing_public_key` | Accept — the primary path, and the durable one. Update `attest_key_id` from this claim, since the attest key legitimately changes on every reinstall while the pairing key does not. |
| R2 | The pairing key differs, but the App Attest proof verifies against the row's stored `attest_key_id` | Accept — the Keychain-lost-but-app-not-reinstalled case. Store the new `pairing_public_key`. |
| R3 | Otherwise | `403 pairing_mismatch`, counted per token-hash for backoff and operator alerting (§6). |

Three rules, and each is a signature check against a value the row already holds. There is no
rule any party can satisfy by presenting something they merely *observed* — which is what
collapsed the previous revisions' rule count from eight to three.

### Vouching: the token proves itself

R1 and R2 answer "is this the device that owned this token before?" R0 cannot — the token has
no history — and for five revisions this document called that an inherent floor, on the
grounds that only Apple knows which device an APNs token belongs to. That was wrong. **Canopy
can ask the token.**

Before a pairing key may bind anything, Canopy sends a **silent push** (`apns-push-type:
background`, `content-available: 1`) carrying a random nonce **to the device token being
claimed**, and requires the next claim to echo that nonce inside the signed `client_data`.
Only the install that actually receives the push can answer. An attacker holding a stolen
token *value* — from a victim's logs, a LAN sniff, a stale `registrations.json` backup —
receives nothing and cannot bind it, no matter how genuine their App Attest proof. This closes
the residual §4 previously conceded, and it costs one round-trip and no persistent state
beyond the pending nonce.

Mechanics, and why they work with the three token kinds:

- Silent pushes are deliverable only to a **device** token, so vouching happens on the
  `/register-device` claim. That registration does not exist on the client today
  (`00-overview.md:116`), and §10 already lists building it as required work; this makes it
  the *first* registration a fresh install performs rather than an afterthought.
- Once a pairing key has been vouched by a device-token round-trip, it is **vouched for that
  install**: subsequent `start` and `activity` claims signed by the same pairing key bind
  without a further round-trip. They come from the same app on the same device, and their
  tokens cannot be silently pushed to in any case.
- Delivery is best-effort: iOS throttles background pushes and may delay them on a
  low-power device. A claim launched from the foreground — the normal case, since the app
  registers at launch — takes the foreground delivery path and is prompt. If the nonce does not
  arrive, the claim simply fails and the §10 queue retries; nothing is bound provisionally,
  because "provisionally bound" is exactly the kind of extra state that generated this
  document's previous defects.
- A hooked app on the *victim's own* device does receive the push, so vouching does not close
  §4's jailbroken-device row. It closes the far more reachable one: a stolen token value.

Other transitions:

| Event | Rule |
|---|---|
| Push from the tenant on a row with a live lease | Allowed. **A successful APNs delivery renews the lease** and stamps `last_delivery_at`. |
| Push from another tenant | `403 not_owner` — the suspension condition (§9). |
| Push with no row, or a released or expired row | `403 not_bound` — routine housekeeping, **not** a suspension condition; it means "re-claim", not "you were evicted". |
| APNs answers 410 / 400 `BadDeviceToken` after the §6 gateway retry | Delete the row — the token is dead. |
| `POST /v1/bindings/release` (raw token, bound tenant) | Set `released_at = now`; `lease_expiry` untouched. Cap counting reads `released_at IS NULL AND now < lease_expiry`; retention reads `lease_expiry`; the next accepting claim clears it. |
| `DELETE /v1/bindings` (raw token, bound tenant) | Return the token to UNSEEN. **This is the recovery path when a phone has lost both keypairs** — the user resets pairing from the app, which asks their own Trellis, which is the bound tenant. It is deliberately an explicit, user-initiated action rather than an inferred rule: every automatic version of it in revisions 3 through 5 turned out to be reachable by an attacker and, in revision 5, unsatisfiable by the honest case it was written for. |
| Dormant: no delivery and no successful claim for 90 d | Treat as UNSEEN for claims; hard-delete the row at 120 d. Not applicable to `activity` rows, which die with their card. |

What each anchor buys:

| Event | Attest key | Pairing key | APNs tokens | Outcome |
|---|---|---|---|---|
| Trellis rebuilt or migrated | kept | kept | kept | R1. **No user action.** |
| App deleted and reinstalled | lost | kept | usually new | R1 on surviving tokens, R0 on new ones. |
| Keychain lost, app not reinstalled | kept | lost | kept | R2. |
| Phone restored from backup onto new hardware | lost | lost | **new** | R0 on the new tokens; the old ones 410 and free themselves. |
| Direct device-to-device migration | lost | kept | new | R1 or R0. |
| Both keypairs lost, tokens unchanged | lost | lost | kept | The user resets pairing in the app → `DELETE` → R0. One tap, no support ticket, no 90-day wait. |

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
- `POST /v1/vouch` `{token}` → `202`. Tenant-authed, and valid only for `binding_kind: device`.
  Canopy mints a nonce and silently pushes it to that token (`apns-push-type: background`),
  storing `{token_hash, nonce_hash, tenant, expires_at}` for 10 minutes. The stored nonce
  satisfies **only a claim from the same tenant for the same token**, single-use. This is the
  one endpoint that pushes to a token nobody has yet proven they own, so it carries a per-token
  **global** cap independent of tenant — a per-tenant limit alone is defeated by enrolling more
  tenants, and the abuse it would enable is waking a known victim's app at will. Its response is
  `202` regardless of what APNs says, so it cannot be used as a token-liveness oracle.
- `POST /v1/claims` `{token, client_data, challenge, vouch_nonce?, pairing_public_key,
  pairing_signature, device_id, binding_kind, apns_environment, attest_key_id,
  attestation? | assertion?}` →
  `204`, or `403 attestation_required | attestation_invalid | pairing_signature_invalid |
  reattest_required | challenge_unknown | challenge_expired | challenge_wrong_tenant |
  challenge_wrong_purpose | kind_mismatch | pairing_mismatch`, or `429 binding_limit`.
  Implements §5. Exactly one of `attestation`/`assertion` may be present. `vouch_nonce` is
  required — and is verified inside the signed `client_data` — whenever R0 would fire for a
  device token that this tenant has not vouched; its absence or mismatch is `403 vouch_required`
  / `403 vouch_invalid`. It is never required for `start` or `activity` kinds, which cannot be
  vouched (§5).
  **Not idempotent** — see the claim protocol. Each reason is emitted by exactly one named
  rule or check, so Trellis and §10's UI can say something true rather than reporting every
  refusal as a takeover. `reattest_required` means "Canopy does not know this key; generate a
  new App Attest key and send an attestation, not an assertion", which is what makes a Canopy
  restore-gap recoverable rather than indistinguishable from an attack.

  **Challenge binding.** Before anything else, the presented challenge must exist, be
  unconsumed, be unexpired, have been **issued to the authenticated tenant**, and match the
  **purpose** of the proof presented (`attestation` for attestations, `assertion` for
  assertions), each with its own reason code above. Revision 3 stored both columns and read
  neither, which left a claim replayable under a *different* tenant — materially worse than
  verbatim replay, since every accepting rule re-points the tenant — and let a 15-minute
  attestation challenge extend the assertion replay window 7.5×.

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

  **An `attest_key_id` is only ever persisted from a verified attestation**, so Canopy can
  never hold a key id with no corresponding public key. **The pairing signature** is a plain
  P-256/SHA-256 verification against `pairing_public_key` — the row's stored copy for R1, or
  the claim's own for R0 and R2, in which case the App Attest proof is what authorises storing
  it.

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
- `DELETE /v1/bindings` `{token}` → `204`. Bound tenant only. Returns the token to UNSEEN —
  the single most security-sensitive transition in the design, and the reason it is an
  explicit, authenticated, user-initiated action rather than an inferred rule (§5). A device
  token returned to UNSEEN must be **re-vouched** before it can be bound again; the tenant's
  prior vouch for it is consumed and does not carry over.
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
correction. R2 installs a new pairing key but likewise leaves it alone: a token's environment
is a property of the token, not of whoever holds it.

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
- **cheap checks first**: challenge existence, tenant, purpose, expiry, per-token backoff, and
  rate limits are all evaluated *before* any X.509 or signature work; the challenge is
  re-confirmed against `client_data` after verification, so it is deliberately checked twice.
  Attestation verification runs on a bounded worker pool so a claim flood cannot starve
  `/v1/push`;
- tenant-scoped shedding first; the global breaker is a last resort.

**Binding lifetime, release, and garbage collection.** Leases differ by `binding_kind`.
**The retention horizon must exceed the dormancy threshold** for any kind where dormancy
applies — the ordering bug revision 2 shipped, and which revision 3 fixed for two kinds while
leaving the third inconsistent:

| `binding_kind` | lease | hard delete | dormancy |
|---|---|---|---|
| `activity` | 72 h, renewed on delivery or claim | `lease_expiry + 7 d` (total 10 d) | **Not applicable** — the token dies with its card, so the row is deleted long before 90 d. This is safe precisely because the token is dead by then; it is stated rather than left to arithmetic. |
| `start`, `device` | 30 d, renewed on delivery or claim | `lease_expiry + 90 d` (total 120 d) | Reachable in the window [90 d, 120 d]. |

A token that reaches hard deletion has had no delivery and no successful claim for 120 days;
returning it to UNSEEN is correct, because any device still holding it would have renewed it.
Revision 5 tried to carry anchors past deletion in a tombstone and got it wrong twice over —
the tombstone copied the *elder* columns, which are empty on an ordinary row, so the mechanism
was a no-op for the case it was added for and a weapon on the one it was not.

Trellis calls release when it drops a registration — after an end push, on a 400/410 drop, and
on a dismissal disown — which is what keeps completed cards from lingering (Trellis stops
pushing while the activity is still alive, so APNs answers 200 and a 410 never arrives;
`app.py:353-354`, `582-585`). **A live binding is `released_at IS NULL AND now < lease_expiry`**,
and only those count against the per-tenant cap of 500. An over-cap claim returns `429
binding_limit`, surfaced in Trellis's `/health`.

**Storage:** SQLite (WAL). `tenants` (id, secret_hash, recovery_hash, created_at, last_seen);
`bindings` (as in §5); **`attest_keys` (key_id, public_key, counter, attest_environment,
receipt, first_seen, last_seen)** — never garbage-collected with bindings, because assertions
must verify long after any particular card is gone; `challenges` (nonce_hash, tenant, purpose, expires_at); `vouches` (token_hash,
nonce_hash, tenant, expires_at); plus in-memory rate buckets. Raw tokens arrive per-request and
die with it.

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
stale" needs building: **Trellis gains a `stale-date` on every card push**, and Sprout's
LOCAL-mode `ActivityContent(state:staleDate:)` stops passing `nil`.

The interval must **not** be derived from `MIN_UPDATE_S`. That constant answers "how often at
most may we push?" — it is a floor on the gap between pushes, gating a `meaningful_change`
gate (`app.py:586`), with no heartbeat anywhere in the poll loop. "How long may silence last
before the card is lying?" is a different question, and a paused print at 3 a.m. or a drying
cycle sitting at target produces no meaningful change for a long time while everything is
perfectly healthy. Deriving one from the other would mark healthy cards stale within a minute —
the same lying card, inverted. So: a named `STALE_AFTER_S` (default 900 s), plus a **heartbeat
re-push of the current content state at `STALE_AFTER_S / 2` when nothing meaningful has
changed**, at priority 5 per the existing `_urgent` split (`app.py:315-320`), so a healthy
pipeline continuously renews the stale date. The test is not "a stale-date is present" but "a
card with no meaningful change still receives a push before its stale date elapses".

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
  `DATA_DIR / "tenant.json"` (`DATA_DIR` defaults to `/data`, `app.py:54`). A rebuild that
  supplies the recovery code re-adopts the same tenant, which is what keeps §1's "zero manual
  unbinding" promise true when the server *and* the app's anchors are lost together —
  otherwise that combination (new tenant, no anchors, token still live) has no path but an
  operator unbind. The code is printed **once, on the startup log line**, and `/health` reports
  only `recovery_code_saved: true|false` so the app can nag. It is deliberately **not** served
  on `_require_key`: that gate accepts any key Bambuddy answers 200 to (`app.py:753-777`),
  including the read-scoped app key, and the recovery code confers tenant identity — which is
  tenant authority itself. Re-reading it requires the admin key by equality (the
  `x_api_key == BAMBUDDY_API_KEY` fast path, `app.py:764`). Enrollment failure is **not** fatal:
  retry with the §6 backoff, serve everything except push, report `enrolled: false` on the
  authenticated `/health`.
- **`stale-date` plus the `STALE_AFTER_S` heartbeat push** (§7) — new behaviour, not a rename.
- **Phone-facing authentication is unchanged.** Every phone-facing endpoint — registrations,
  `/sync`, `/unregister`, collections — remains gated by `_require_key`, the existing
  `X-API-Key` check delegated to that user's Bambuddy (`app.py:753-777`). **The pairing secret
  is binding authority at Canopy; it is not authentication at Trellis.**
- **`/health` is split.** The unauthenticated route keeps `{ok: true}` for container health
  checks; counts, `push_suspended`, `needs_claim`, `enrolled`, the recovery code, and anything
  token-derived move behind `_require_key`.
- **A device identity, minted on the phone.** Both phones in a household present the same
  Bambuddy API key, so Trellis cannot tell them apart — yet three behaviours need per-device
  scoping. The `device_id` is 16 random bytes generated by the app and stored beside the
  pairing secret (§10), **not** minted by Trellis at `/register-start`: that endpoint never
  fires for a user who has Live Activities switched off, and such a user can still want alert
  banners, so the one registration that would have no identity is `/register-device`. Minting
  on the phone also means the value can travel inside the signed `client_data`, where Trellis
  cannot alter it. `/sync` then drops only the reporting device's own tokens, `needs_claim`
  returns only the requesting device's tokens, and the p2s pending claim is keyed per device.
  Trellis rejects a relay-mode registration that omits it, with a stated reason. Without this,
  phone A's `needs_claim` lists phone B's tokens, phone A claims over them, and both phones
  land on repeated `pairing_mismatch` — raising the operator takeover alert and §10's "push
  pairing was taken over" row for an ordinary two-phone household.
- **Vouch forwarding**: a registration whose claim returns `403 vouch_required` triggers
  `POST /v1/vouch` for that token; the silent push then reaches the app, which re-registers
  with the nonce. Trellis never sees the nonce (it travels APNs → app → signed `client_data`),
  so it cannot mint a vouch for a token it does not control.
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
- **Pairing key and device id**: a P-256 keypair generated at first launch via `SecKeyCreate
  RandomKey`, plus 16 random bytes of `device_id`, stored in one Keychain item `bambu.pairing`
  alongside the attest key id, separate from `AppConfig` so sign-out or re-onboarding never
  destroys them. The private half never leaves the device and is never transmitted; only
  signatures over per-claim challenges are. The `device_id` exists before any registration of
  any kind, which is why Trellis does not mint it (§9) — but note it is a **Trellis-side
  scoping key only**, never a Canopy gate: it shares a Keychain item with the pairing key, so
  it cannot answer "is this the same phone?" in any case where the pairing key was lost.
  Revision 5 gated a recovery rule on it and made that rule unsatisfiable by the only clients
  that needed it.
- **Keychain accessibility, including a migration for existing installs.** The whole
  registration credential set must be background-readable: the POST also needs the API key and
  the Trellis URL, which live in `AppConfig` under `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  (`SecureConfig.swift:92`). The canonical background wake is a push-to-start arriving while the
  phone is locked in a pocket — Apple grants background runtime there — and a `WhenUnlocked`
  read fails at exactly that moment, so the claim never leaves the phone and the
  remotely-started card freezes at its start content. Move **the `bambu.pairing` item and
  `AppConfig` itself** to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, still
  `ThisDeviceOnly` — moving the whole config blob rather than duplicating `{pushUrl, apiKey}`
  into a second item avoids inventing a sync rule between two copies of the same credentials.
  **Changing that line alone fixes nothing for anyone already
  onboarded**: `kSecAttrAccessible` is set only on the add branch (`SecureConfig.swift:80-94`),
  and the update branch never re-states it, so every existing install would keep `WhenUnlocked`
  forever. Add a one-shot launch migration that re-states the attribute via `SecItemUpdate`'s
  attributes dictionary (no delete needed, so the device is never briefly credential-less).
- **A persisted pending-claim queue covering all three registrations.** Today only `/register`
  retries: `flushRegistrations()` (`LiveActivityController.swift:455-460`) is driven by the 4 s
  `sync` (`:239-242`) against a `registered` set, with a 30 s per-pair backoff.
  `/register-start` is a fire-and-forget POST inside
  the `pushToStartTokenUpdates` loop whose result is discarded and which only iterates again on
  token rotation (`:346-355`), and `/register-device` does not exist on the client at all
  (`00-overview.md:116`). So a brand-new install whose first claim meets a down Canopy never
  registers a start token for the whole process lifetime — the worst state the controller's own
  header comment describes. All three go onto one persisted queue holding *intents* (token,
  `binding_kind`) with the same retry discipline, re-attempted on foreground, on every
  token-stream emission, and on the `needs_claim` list from Trellis's `/health` — **intersected against the app's own
  live token set, never treated as a list of tokens to claim** (§5).
- **Vouch handling**: register for remote notifications at launch (which `/register-device`
  needs anyway), and on a silent push carrying a vouch nonce, stash it and re-run the pending
  claim for that token with the nonce inside `client_data`. This is what makes a stolen token
  value unusable (§5), and it puts `/register-device` first in the registration order rather
  than last.
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
  "Push needs re-pairing" (with the "Reset push pairing" action that drives §5's `DELETE`),
  "Push isn't available on this device", and, when a token accumulates repeated
  `pairing_mismatch`, "This token is bound to another device". A limitation the user discovers by silence is the failure mode
  this codebase keeps rediscovering.
- **Background refresh is a supplement, not a guarantee.** A `BGAppRefreshTask` refreshes the
  start and device claims, but iOS schedules it opportunistically and weights it by how often
  the user foregrounds the app — so it is least likely to run for the passive user it would most
  help, and never after a force-quit. The deterministic paths are re-claim on foreground, on
  every token-stream emission, and in response to `needs_claim`; and Canopy treats its own
  database as durable state rather than something clients rebuild (§6).
- **Registration bodies** gain `client_data`, `challenge`, `pairing_public_key`,
  `pairing_signature`, `device_id`, `binding_kind`, `apns_environment`, `attest_key_id`, and
  `attestation`/`assertion` — snake_case, tested like the existing fields. `binding_kind`
  (`activity | start | device`) is distinct from the existing `kind` (`print | dry`) in the
  same body, and the app must send both.
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
| Server rebuilt **and** the app lost both keypairs | The user taps "Reset push pairing"; the app asks its Trellis, which as bound tenant issues `DELETE /v1/bindings`; the next registration binds fresh via R0. One tap, no waiting. If the tenant credential was also lost, the recovery code (§9) restores tenant identity first. |
| Server rebuilt **and** the app lost both anchors **and** no recovery code | The one combination with no automatic path: new tenant, no anchors, and a token still live enough never to go dormant. Operator unbind (§14). The self-hoster guide must say to save the recovery code; §9 logs it and exposes it on `/health` for that reason. |
| A user's own Trellis is compromised | Out of scope by design (§4, §5): it can push junk to that user and can delete-and-reclaim to deny them push. It cannot reach another user, and it observes nothing replayable. |
| Someone else first-claimed a token Canopy had never seen | The residual in §4. The victim's claims get `pairing_mismatch`; the consistent-claimant alert fires for the operator and surfaces in the app; recovery is operator unbind. |
| Keychain lost but the app was not reinstalled | R2: the surviving App Attest key authorises storing the new pairing key. |
| Token genuinely abandoned (no delivery or *successful* claim for 90 d) | Treated as UNSEEN for claims and hard-deleted at 120 d. Only *successful* claims hold the clock — a phone retrying a failing claim every 5 minutes must not keep its own row alive forever, which is what made revision 4's equivalent rule unreachable. |
| Wrong APNs environment on a claim | The first `BadDeviceToken` triggers the other-gateway retry with that gateway's key, correcting the stored `apns_environment` for the row's lifetime (§6). |
| APNs key compromised | Owner revokes and uploads a new key; zero tenant or user action (invariant 5). Bundle-scoped keys keep the blast radius inside this app. |

## 12. Testing

- **Canopy (Go)**: table-driven tests over the binding state machine that **feed one claim and
  assert which rule fired**, not one test per rule — a per-rule suite is structurally incapable
  of catching two rules matching one input, which is how revision 3's overlaps survived. Cases
  must include every rule R0–R3 and specifically: **an R0 claim without a vouch nonce refused
  with `vouch_required`, with a nonce for a different token refused, with an expired nonce
  refused, and accepted with the right one; **a second device token from a pairing key that has
  already vouched once still requiring its own fresh round-trip** — the standing-exemption hole
  revision 7 shipped, and the one test that would have caught it; a `start` or `activity` claim
  proceeding without a vouch, since those kinds cannot be vouched (§5);** R1 accepted for a claim whose App Attest key
  has changed (the reinstall path) and the row's `attest_key_id` updated; R1 refused when the
  pairing signature is over different `client_data` than the one presented; R2 accepted only
  when the App Attest proof verifies against the row's stored `attest_key_id`, and refused for
  a stranger's attest key; a claim carrying a valid pairing signature for a *different* token
  refused; a stranger-tenant claim against a lease-expired row and against a released row both
  refused; **release then re-claim then push returns 200**, and the row counts against the cap
  again; `DELETE` returning the token to UNSEEN and the next claim binding fresh; an
  `activity`-labelled claim against a `device` row refused with `kind_mismatch` and leaving the
  horizons unchanged; dormancy reachable at 91 d, refused at 89 d, and *not* held off by a
  phone retrying a failing claim every 5 minutes. Per-kind arithmetic is asserted as
  `lease(kind) + retention_after_lease(kind) > dormancy` for every kind where dormancy applies
  — both terms measured from the same last-activity epoch, giving 120 > 90 with a 30 d margin;
  revision 4's formula subtracted the lease term, double-counting it, and would have failed on
  its own constants. Crypto: real
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
  starts for one device binding correctly or not at all (never arbitrarily), `/register-device`
  correctly device-scoped with no prior `/register-start`, and the `registrations.json`
  dict→list migration; release on card end; **a card with no meaningful change for
  `STALE_AFTER_S / 2` still receiving a heartbeat push, so its stale date never elapses while
  the poll loop runs** — a presence assertion on the field cannot catch the interval being
  wrong; `/health` with a Bambuddy-valid but non-admin key returning neither token prefixes nor
  the recovery code; enrollment failure non-fatal and recovery-code re-adoption; startup
  fail-hard on ambiguous backend config; rejection of unattested or `device_id`-less
  registrations in relay mode.
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
3. **Sprout pairing** — App Attest, the pairing keypair, `/register-device` and silent-push
   vouch handling (which must land before the other two registrations, since they depend on the
   vouch), the Keychain moves and migration, entitlement-derived
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
- **Rotating a pairing key without deleting the binding.** v1's reset path is
  `DELETE /v1/bindings` from the bound tenant, which is simple and user-initiated. A future
  in-place rotation would be a claim signed by *both* the old and the new pairing key; it needs
  no elder machinery, which is the point of the keypair design.
- **Encrypted content-state** for the native client (ciphertext decrypted in the widget with an
  App-Group-shared key), removing printer and file names from Canopy's view entirely. The
  envelope still cannot be encrypted (§7).
- Alert banners end-to-end encrypted via a notification service extension.
- Android/FCM — a `platform` field on `/register-device` and a second sender in Trellis
  (`docs/guides/android.md`); Canopy would gain an FCM credential and a topic-table entry, with
  Play Integrity replacing App Attest as the device anchor.
- A payload-scrubbing knob (user opts filenames out of push payloads at the Trellis level).
- Operator tooling beyond manual unbind, which **is** in scope as the support backstop for a
  stuck or seized binding. It takes the **raw token**, like every other endpoint — a
  `token_hash` argument would reintroduce the unpinned cross-language hash contract that the
  release endpoint was changed to eliminate.
