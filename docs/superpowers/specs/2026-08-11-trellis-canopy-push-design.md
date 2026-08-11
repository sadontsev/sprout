# Trellis + Canopy: multi-tenant push for App Store distribution

**Status:** approved design, not yet implemented
**Date:** 2026-08-11
**Revision:** 2 — revised after a five-lens adversarial review (security, APNs facts, codebase
consistency, self-host operations, spec quality). Revision 1's lease-expiry rebind rule was a
real cross-user push path; §5 is substantially rewritten and App Attest moved into v1.

## 1. Context and goals

Today the app is single-user: la-push runs next to the owner's Bambuddy, holds the owner's
APNs `.p8` auth key, and pushes Live Activities and alert banners directly to APNs. That
key is team-wide and effectively unrevocable-in-practice (Apple caps a team at 2 APNs keys;
one leak from any deployment would compromise push for every install), so the current
design cannot be shared: `docs/guides/push-notifications.md` explicitly tells other people
to self-host with their *own* key — which only works for their own TestFlight builds, never
for an App Store install signed by the owner's team.

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
│                          polls status,     ├───►│ · .p8 key   ├──► APNs ──► phone
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
   Trellis, unchanged. Canopy is a signing gate that validates *who may push to which
   token* and forwards opaque payloads.
2. **The phone never talks to Canopy.** Its only servers are its own Trellis and Bambuddy.
   Attestation challenges and claims are relayed through Trellis, which cannot forge or
   alter them (§5).
3. **The owner's infrastructure never talks to any user's Bambuddy.** Canopy accepts
   inbound requests only.
4. **A tenant can never choose an APNs topic.** Canopy derives the topic from `push_type`
   against a hardcoded two-entry table; those are the only strings it will ever sign for.
5. **Nothing Apple-specific reaches Trellis in relay mode.** Key id, team id, topic, APNs
   host all live in Canopy — so the owner can rotate the `.p8` at any time with zero action
   from any user or tenant.
6. **Ownership of a push token is anchored to the device, not to a server.** Servers are
   the disposable party in a self-hosting setup; the phone is the durable one.

## 4. Threat model

Assets: the `.p8` (signs pushes for every install of the app), users' push tokens, users'
print metadata (printer names, filenames — they transit push payloads), Canopy's tenant
credentials.

| Adversary / scenario | Outcome under this design |
|---|---|
| Attacker steals a push token (victim's logs, LAN sniffing, a stale `registrations.json` backup) | Cannot bind it. Every claim requires an App Attest assertion from a genuine Sprout install, signed over the exact claim contents (§5). A `curl`-wielding attacker with a valid tenant credential cannot produce one. Residual: a **jailbroken device running a hooked copy of the genuine app** can still assert over an arbitrary token; re-signing the app under another team fails the App ID check. Stated as residual risk, not as "impossible". |
| Attacker waits out a lease and re-claims a live token | Closed. Leases renew on **successful push delivery** as well as on claims, so a token anyone is actively delivering to never becomes claimable. The only rebind path requires 90 days with no delivery *and* no claim (a genuinely abandoned token) *and* a valid attestation, and it preserves the prior anchors as elder for 90 days so the original device evicts a squatter on next launch (§5). |
| Attacker enrolls tenants and probes random tokens | Tokens are 32-byte APNs-generated values; guessing is infeasible. Unbound-token pushes are rejected. Per-tenant and per-IP limits, per-token-hash failed-claim backoff, and operator alerting on repeated `pairing_mismatch` for one token cap the probe rate (§6). |
| A user's Trellis box is fully compromised | Attacker gets that user's tokens, tenant credential, and observes pairing secrets and assertions in transit. They can push junk **to that user's own devices only**, and can replay a captured claim verbatim — but cannot forge a different one, because the assertion is signed over the claim contents by a key in the phone's Secure Enclave. So the attacker **cannot lock the user out**: the real phone's next claim always wins and re-points the binding to a clean Trellis. Recovery is a rebuild, not a support ticket. |
| A tenant floods pushes (hostile or broken) | Per-token, per-tenant, and global limits. Shedding is **tenant-scoped first**: tenants with high 4xx/410 ratios are throttled individually; the global breaker is a last resort so one abuser cannot deny push to everyone. Enrollment can be gated by invite code if abuse appears (§6). |
| Canopy itself is compromised | Attacker holds the `.p8` → can push arbitrary content to all installs until the key is revoked and rotated. Same class of risk the owner's own server carries today, now concentrated on one hardened box. Mitigations: minimal surface (static Go binary, three dependencies), no payloads or raw tokens at rest, TLS via reverse proxy, monitoring, backups, and key rotation that needs no tenant action (invariant 5). |
| Someone who knows a public Trellis URL registers their own token | Rejected by Trellis's existing `X-API-Key` gate, which is delegated to that user's Bambuddy (`app.py:753-777`) and is **unchanged** by this design. Without it a stranger could receive another household's print banners. See §9: the pairing secret is binding authority at Canopy, *not* authentication at Trellis. |
| The owner snoops on users | Sees per-push: raw token + payload, in memory, for one HTTPS forward. Stores only hashes and counters (§8). Cannot reach any user's Bambuddy. This is a documented trust statement, not cryptography — see §7 for what is and is not encryptable, and §14 for the deferred option. |

## 5. Device identity, pairing, and binding

Ownership rests on **two anchors held by the phone**, each covering the other's loss case:

- **An App Attest key** (`DCAppAttestService`), generated once, private half sealed in the
  Secure Enclave and non-exportable. Proves "a genuine Sprout install on a real Apple
  device made this exact request." Lost when the app is deleted and reinstalled.
- **A pairing secret**, 32 random bytes in the phone's Keychain. Survives app reinstall
  (Keychain items outlive app deletion on iOS) but not a device wipe.

Neither anchor is held durably by any server. Trellis relays claims and **cannot alter
them**: the assertion is signed over the claim's contents, so a compromised Trellis can
replay a claim but never forge a different one.

### Claim protocol

1. The app asks its Trellis for a challenge; Trellis calls Canopy `POST /v1/challenges`
   (tenant-authed) and returns the opaque nonce (120 s TTL, single use).
2. The app computes `clientData` = canonical JSON of
   `{challenge, token, pairing_secret, previous_secret?, kind, environment}` and produces
   either an **attestation** (first use of a new attest key) or an **assertion** (every
   later claim) over `SHA-256(clientData)`.
3. The app POSTs its normal registration to Trellis (`/register`, `/register-start`,
   `/register-device`) with the new fields; Trellis forwards them to Canopy `/v1/claims`.
4. Canopy verifies the attestation/assertion (§6), reconstructs `clientData` from the claim
   body it received, and checks the hash — binding the proof to the exact claim.

### Binding state machine

Binding record: `{token_hash, attest_key_id, pairing_hash, elder_attest_key_id,
elder_pairing_hash, elder_until, tenant, kind, environment, lease_expiry, last_delivery_at}`.

Every row below additionally requires a valid attestation or assertion; a claim without one
is `403 attestation_required` and never reaches the state machine.

| State + event | Rule |
|---|---|
| UNBOUND + claim | Bind: store both anchors, tenant, kind, environment; `lease_expiry = now + 30d`. |
| BOUND + claim, **attest key matches** | Accept (primary path). Re-point to the claiming tenant, refresh the pairing hash from the claim, renew lease. |
| BOUND + claim, attest key differs but **pairing secret matches** (current, or elder within `elder_until`) | Accept — this is the app-reinstall case, where the attest key is legitimately lost. Store the new attest key, re-point tenant, renew lease. A matching **elder** anchor also clears the elder fields, evicting whoever rebound in the interim. |
| BOUND + claim carrying `previous_secret` matching the stored pairing hash | Rotation: replace the pairing hash, re-point tenant, renew lease. |
| BOUND + claim, neither anchor matches, token **not dormant** | `403 pairing_mismatch`. Counted per token-hash for backoff and operator alerting (§6). |
| BOUND + claim, neither anchor matches, token **dormant** (no successful delivery *and* no claim for 90 d) | Rebind, and copy the outgoing anchors into `elder_*` with `elder_until = now + 90d` so the original device can still evict the new holder on its next launch. |
| BOUND + push from the bound tenant | Allowed. **A successful APNs delivery renews the lease** (`last_delivery_at`), so an actively-used token never drifts toward dormancy. |
| BOUND + push from any other tenant | `403 not_owner`. |
| APNs answers 410 / 400 `BadDeviceToken` | Delete the binding after the environment retry in §6 fails — this frees a genuinely dead token. |
| Binding is `kind: activity` and its lease expires | **Delete the row** (§6 garbage collection). |

What each anchor buys, walked through the real lifecycle events:

| Event | Attest key | Pairing secret | APNs tokens | Outcome |
|---|---|---|---|---|
| Trellis rebuilt / migrated | kept | kept | kept | Claim matches; binding re-points to the new tenant. **No user action.** |
| App deleted and reinstalled | lost | kept | new (usually) | Pairing secret path accepts; new tokens bind fresh regardless. |
| Phone restored onto new hardware | lost | lost | **new** | New tokens bind fresh; old tokens 410 and free themselves. |
| Trellis compromised, attacker replays claims | intact on phone | observed by attacker | kept | Attacker cannot forge a different claim; the real phone's next claim wins. |

Per-activity Live Activity tokens need no special casing for *ownership* — they are born and
die with each print card, so they self-heal on the next card either way. They do need
special casing for *lifetime*; see garbage collection in §6.

## 6. Canopy specification

**Language: Go.** Canopy is the one internet-facing service holding the key, and it is new
code (~700 lines with attestation verification). Go gives a static binary with a stdlib
HTTP server, transparent HTTP/2 to APNs via `net/http`, ES256 over `crypto/ecdsa` (no JWT
library), X.509 chain verification for App Attest in `crypto/x509`, and table-driven tests
that fit the binding state machine exactly. Third-party surface: `modernc.org/sqlite`
(pure Go), `golang.org/x/time/rate`, and a CBOR decoder (`github.com/fxamacker/cbor/v2`)
for attestation objects. Deployment: `GOOS=linux go build`, scp, systemd, Caddy for TLS.
(Trellis stays Python: its logic is proven and measured, and the Docker container is the
distribution unit, so the language is invisible to self-hosters.)

Endpoints (JSON over HTTPS; tenant auth is `Authorization: Bearer <tenant_id>.<tenant_secret>`):

- `POST /v1/enroll` `{invite_code?}` → `201 {tenant_id, tenant_secret}`. Open enrollment,
  IP-rate-limited (default 5/day/IP); `invite_code` is validated only when
  `CANOPY_INVITE_CODE` is set (dormant abuse valve, off by default). Secrets are 32 random
  bytes stored as SHA-256 (high-entropy secrets need no password hashing).
- `POST /v1/challenges` → `201 {challenge, expires_at}`. Tenant-authed, rate-limited. The
  nonce is single-use with a 120 s TTL, stored until consumed or expired.
- `POST /v1/claims` `{token, pairing_secret, previous_secret?, environment, kind,
  attest_key_id, attestation? , assertion?, challenge}` → `204`, or `403
  attestation_required | attestation_invalid | pairing_mismatch`, or `429 binding_limit`.
  Implements §5. Idempotent. Attestation verification follows Apple's published procedure:
  chain to the App Attest root CA (pinned), nonce equals `SHA-256(authenticatorData ||
  clientDataHash)`, `keyIdentifier` equals `SHA-256(public key)`, `rpIdHash` equals
  `SHA-256("<TEAM_ID>.com.mvks5.bambu")`, counter zero on attestation and strictly
  increasing on assertions. The `aaguid` must be `appattestdevelop` only when the claim's
  `environment` is `sandbox`, and `appattest` only when it is `production` — the two
  environments never cross.
- `POST /v1/push` `{token, push_type: "liveactivity"|"alert", priority: 5|10, payload,
  idempotency_key?}` → `200 {apns_status, apns_reason?}`, or `403 not_bound|not_owner`, or
  `429`. Canopy verifies the caller is the bound tenant; clamps priority to {5, 10};
  derives `apns-topic` and `apns-push-type` from `push_type`
  (`liveactivity` → `com.mvks5.bambu.push-type.liveactivity`, `alert` → `com.mvks5.bambu`;
  hardcoded, invariant 4); caps payload at APNs' 4096 bytes; signs the JWT (cached ~40 min);
  POSTs APNs on the binding's environment host; renews the lease on success; and returns
  the APNs status and reason **verbatim** so Trellis's existing token hygiene works
  unchanged. Payload contents (`event`, `content-state`, `dismissal-date`, `stale-date`,
  the `alert` block) are opaque passthrough — push-to-start versus update is not Canopy's
  concern.
- `GET /v1/health` → `{ok, version}`. Deliberately bare — unlike la-push's count-reporting
  health page, Canopy's must reveal nothing about tenants.

**Environment self-correction.** On `400 BadDeviceToken`, Canopy retries once on the other
APNs gateway before deleting the binding. If the retry succeeds it corrects the stored
`environment` and logs the correction. This turns a mislabelled environment (§10) from a
silent permanent death-loop into a self-healing one-time event.

**Idempotency and retries.** Live Activity *updates* are never retried — the next poll
supersedes them. Push-to-start and alert banners are retried at most once on transport
timeout, carrying a client-generated `idempotency_key` that Canopy dedupes for 5 minutes,
so a timeout that actually delivered cannot double-alert the user. Claims retry with
exponential backoff (1 s doubling to a 5 min cap); they are idempotent.

**Rate limits** (env-tunable; a backstop, not shaping — Trellis already shapes at
`MIN_UPDATE_S = 30`):

- per token: sustained 1 push/10 s, burst 5;
- per tenant: 120 pushes/min, 60 claims/min, and a binding cap (below);
- per token-hash: failed-claim counter with exponential backoff, and an operator alert when
  one token accumulates repeated `pairing_mismatch` responses — the signature of a targeted
  takeover attempt;
- tenant-scoped shedding first: throttle tenants whose APNs 4xx/410 ratio spikes; the
  global circuit breaker is a last resort, so one abuser cannot 429 everyone.

**Binding lifetime and garbage collection.** Leases differ by `kind`, which is exactly why
the field exists on claims:

| kind | lease | notes |
|---|---|---|
| `activity` | 72 h, renewed on delivery | A card lives hours. On expiry the row is **deleted**, not merely reopened. |
| `start`, `device` | 30 d, renewed on delivery or claim | Long-lived by nature. |

Trellis additionally sends `DELETE /v1/bindings/{token_hash}` (tenant-authed, bound tenant
only) when it drops a registration after an end push — safe, because that tenant already
holds full push authority over the token. Without this, a completed card's token would
never earn a 410 (Trellis stops pushing to it while the activity is still alive, so APNs
answers 200 — `app.py:353-354`, `582-585`) and its binding would linger. **"Live binding"
means a row whose lease has not expired**, and only those count against the per-tenant cap,
which is 500 (arithmetic: two phones × (1 start + 1 device) + several prints/day and
concurrent drying cards, each held 72 h, leaves an order of magnitude of headroom). Rows
are hard-deleted 30 days past `lease_expiry` so the table stays bounded. An over-cap claim
returns `429 binding_limit`, which Trellis surfaces in its `/health`.

**Storage:** SQLite. `tenants` (id, secret_hash, created_at, last_seen); `bindings` (as in
§5); `challenges` (nonce_hash, tenant, expires_at); plus in-memory rate buckets. Raw tokens
arrive per-request and die with it. Daily backup. If the bindings DB is lost anyway, tokens
read as UNBOUND and re-bind as each phone next registers — §10's background refresh task is
what makes that true for phones whose owners never open the app.

**Logs:** tenant id, token-hash prefix, status, latency. Never payloads, never raw tokens,
never per-request IPs.

## 7. Live Activity flow, end to end (relay mode)

1. **App launch** — `pushToStartTokenUpdates` fires → the app obtains a challenge, builds an
   assertion, and POSTs `/register-start` to its own Trellis; Trellis forwards the claim to
   Canopy. Likewise `/register-device` for the alert-banner token.
2. **Print starts** — Trellis's poll loop sees a live state with no card and builds the
   push-to-start payload itself (`event: start`, attributes, and the mandatory `alert`
   block — the "APNs 200s then silently discards without it" lesson stays encoded in
   Trellis). `POST canopy /v1/push {push_type: liveactivity, priority: 10, payload}`.
3. **Card appears** — ActivityKit mints the per-activity update token; the app's
   `pushTokenUpdates` fires → `/register` with a fresh assertion → claim → bound.
4. **Updates** — on meaningful change Trellis builds the ContentState envelope (the `expo`
   versus `native` shape stays entirely its concern) and pushes via Canopy at the priority
   it already chooses today. End pushes carry `dismissal-date` in the payload, passthrough,
   and are followed by `DELETE /v1/bindings/{token_hash}`.
5. **Feedback** — APNs status verbatim; on 400/410 Trellis drops its registration exactly as
   today, and Canopy has dropped the binding.
6. **`/sync` dismissal reconcile** — phone ↔ Trellis only; Canopy uninvolved. `/sync` is an
   RN-app path, and the RN app is DIRECT-mode only (§9), so its binding branch is inert in
   relay mode.

**Encryption, stated accurately.** The APNs *envelope* cannot be encrypted: `event`,
`dismissal-date`, `stale-date`, the push-to-start `attributes`, and the mandatory start
`alert` title/body are interpreted by iOS itself, and Apple provides no NSE-style mutation
hook for `apns-push-type: liveactivity`. The *content state* is a different matter —
ActivityKit only decodes it; the widget extension renders it with code, so a ciphertext
blob decrypted at render time with a key shared via the existing App Group is technically
possible. We do **not** do this in v1 (key distribution, payload inflation, and pre-first-
unlock render edges), which makes it a deliberate deferral (§14), not a physical
impossibility. Printer names and filenames therefore transit Canopy in plaintext under the
no-persistence rules of §6 and §8.

Trellis also sets `stale-date` on card pushes (the standing suggestion at
`07-realtime.md:898`) so a dead feed visibly stales the card instead of lying.

## 8. Privacy posture (what the owner can and cannot see)

| Data | Canopy at rest | Canopy in transit | Notes |
|---|---|---|---|
| Push tokens | SHA-256 only | raw, per-request | needed to call APNs |
| Pairing secrets | SHA-256 only | raw, per-claim | durable home is the phone's Keychain only |
| App Attest public keys | stored (public halves + counter) | — | private half never leaves the Secure Enclave |
| Push payloads (names, progress, temps) | **never** | plaintext, one forward | Apple's design for the envelope; content-state encryption deferred (§7) |
| Tenant credentials | SHA-256 only | bearer over TLS | |
| User Bambuddy URLs / API keys / cameras / libraries | **never** | **never** | Canopy accepts inbound only |
| IP addresses | never (in-memory rate buckets only) | inherent to HTTP | not logged per-request |

Trellis-side: pairing secrets and assertions transit but are never persisted.

## 9. Trellis changes

- **Rename** per §2. `docs/guides/push-notifications.md`, `deploy/README.md`, repo-root
  `CLAUDE.md`, and `docs/native-rewrite/` references updated. Collections, cooldown, p2s,
  and classify logic: untouched.
- **Two-backend APNs interface**: `DIRECT` (today's `.p8` env set — preserved for the owner
  and for self-signers on their own Apple team) and `RELAY` (`CANOPY_URL`). Exactly one
  must be configured; both or neither fails at startup, honoring the lesson from the
  hardcoded-`APNS_*` era (`${VAR:?}` fail-hard style).
- **Auto-enrollment**: in relay mode, on first boot with no stored credential, Trellis calls
  `/v1/enroll` and stores the tenant credential at `data/tenant.json`.
- **Phone-facing authentication is unchanged.** Every phone-facing endpoint — the
  registrations, `/sync`, and collections — remains gated by `_require_key`, the existing
  `X-API-Key` check delegated to that user's Bambuddy (`app.py:753-777`). **The pairing
  secret is binding authority at Canopy; it is not authentication at Trellis.** Two
  questions, two predicates, per the repo's recurring-bug rule; neither substitutes for the
  other.
- **Claim forwarding**: every registration forwards a claim synchronously. "Forward and
  forget" means Trellis never *persists* the pairing secret — it must still act on the
  response. A registration succeeds (`2xx` to the phone) only when the claim returned a
  definitive answer (`204`, or a `403` that the app must see); a transport failure to Canopy
  returns `502` so the app's existing 30 s retry (`LiveActivityController.swift:455-460`)
  drives convergence instead of the app believing a lost claim succeeded.
- **Push-suspension, defined**: suspension is **per token**, persisted in
  `registrations.json` so a restart cannot silently resume retry-spam. It is set on a push
  `403` (`not_bound` or `not_owner`) and cleared **only** by a `204` claim response for that
  same token; a `pairing_mismatch` leaves it suspended. It applies identically to all three
  token stores (`_regs`, `_device_tokens`, `_p2s_tokens`). `/health` reports
  `{push_suspended: [{token_prefix, reason, since}]}`.
- **Multiple phones per printer**: the card registry becomes a **list of registrations per
  key** instead of one (`_regs[key]` is currently overwritten at `app.py:913`). Updates and
  end pushes fan out to each. Without this, a second phone in the household receives the
  push-to-start, registers its own token, clobbers the first, and its card freezes at
  creation content for the whole print — a silent failure in the first real multi-user
  deployment.
- **Relay mode is native-app only.** The RN app cannot produce an App Attest assertion, so
  in relay mode Trellis rejects secretless/unattested registrations with a stated reason and
  the docs say the RN app requires DIRECT mode. This deliberately removes the entire
  server-minted fallback-secret mechanism from revision 1 — which was both the weakest link
  in the model and the source of a data-volume-loss lockout. The RN app remains
  personal/TestFlight, never App Store, so nothing ships worse off.

## 10. Sprout changes

- **App Attest**: generate the key once via `DCAppAttestService.shared.generateKey()`,
  persist `keyId` in the Keychain, attest on first claim and assert on every later one,
  regenerating the key if Apple reports it invalid. `isSupported` is false in the Simulator,
  so **relay-mode push requires a real device** — the Simulator falls back to LOCAL mode,
  which is stated in the UI rather than discovered.
- **Pairing secret**: 32 bytes, Keychain item `bambu.pairing`, deliberately separate from
  `AppConfig` so sign-out or re-onboarding never destroys it.
- **Keychain accessibility**: the whole registration credential set must be background-
  readable, not just the pairing secret. The registration POST also needs the API key and
  the Trellis URL, which live in `AppConfig` under
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (`SecureConfig.swift:92`). The canonical
  background wake is a push-to-start arriving while the phone is locked in a pocket, and at
  that moment a `WhenUnlocked` read fails — so the claim never leaves the phone and the
  remotely-started card freezes at its start content. Move the pairing item, the attest key
  id, and a minimal `{pushUrl, apiKey}` item (or `AppConfig` itself) to
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, still `ThisDeviceOnly`.
- **APNs environment from the entitlement, not the build configuration.** Revision 1 derived
  it from `#if DEBUG`, which is a proxy for the real question and exactly the shape
  `CLAUDE.md` warns about: a `-configuration Release` build installed via Xcode/devicectl —
  the repo's own everyday device recipe — is development-signed, so its tokens are sandbox
  while `#if DEBUG` is false. Read `aps-environment` from the embedded provisioning profile
  at runtime: `development` → `sandbox`; absent or `production` → `production`, with
  `#if DEBUG` only as a last-resort fallback. Canopy's gateway retry (§6) is the safety net.
- **Background refresh**: a `BGAppRefreshTask` re-registers the push-to-start and device
  tokens every few days. This is what makes the "re-binds when the phone next registers"
  recovery true for a passive user who receives cards and banners but rarely opens the app —
  otherwise a Canopy DB loss leaves that phone silently dark forever. It also refreshes
  leases.
- **Push health in the UI**: read Trellis's `/health` push-suspension state and show an
  actionable row ("Push needs re-pairing — tap to fix") instead of letting the user discover
  a limitation by silence. This is the §4 "affordance must state its own absence" rule.
- **Registration bodies** gain `pairing_secret`, `environment`, `attest_key_id`,
  `challenge`, and `attestation`/`assertion` — snake_case, tested like the existing fields.
  Note the native app does not yet POST `/register-device` at all (a known gap,
  `13-code-review.md`, `00-overview.md:116`); that registration must be built before it can
  carry the new fields, and this design is the reason to finally do it.
- `ConfigRules` derivation becomes `bambuddy.` → `trellis.`; explicit `pushUrl` still wins;
  the RN app's `lapush.` derivation is untouched (the owner keeps a `lapush.` CNAME during
  the transition). The push on/off toggle and the `laPushUrl` versus `resolvePushUrl` split
  are already correct and unchanged.

## 11. Failure modes

| Failure | Behavior |
|---|---|
| Canopy down | Pushes and claims fail; Trellis retries with the §6 backoff; registrations return 502 so the app retries; cards go visibly stale (`stale-date`); LOCAL-mode users unaffected. |
| Canopy bindings DB lost | Tokens re-bind as each phone next registers — on app launch, or within days via the §10 background refresh. |
| Push rejected `403 not_bound`/`not_owner` | Token marked push-suspended (§9), cleared only by a successful re-claim; surfaced in Trellis `/health` and in the app. |
| Trellis down / user's server dead | No pushes for that user; rebuild plus the phone's next registration restores everything, because both ownership anchors live on the phone (§5). |
| Attacker holds a binding (compromised Trellis, replayed claim) | Junk pushes to that user's own devices until the real phone's next claim re-points the binding — which always wins, since the attacker cannot forge an assertion. Never cross-user. |
| Token genuinely abandoned (device gone, no delivery or claim for 90 d) | Rebindable by a new claimant, with the prior anchors retained as elder for 90 d so a returning original device still evicts the newcomer. |
| Wrong APNs environment on a claim | First `BadDeviceToken` triggers Canopy's other-gateway retry, which corrects the stored environment (§6) instead of death-looping. |
| APNs key compromised | Owner revokes, uploads a new `.p8` to Canopy; zero tenant or user action (invariant 5). |

## 12. Testing

- **Canopy (Go)**: table-driven tests over the binding state machine — one row per §5 case,
  including elder-eviction, dormancy, and both lease classes; attestation and assertion
  verification against captured real-device fixtures plus negative fixtures (wrong `rpIdHash`,
  wrong `aaguid` for the environment, replayed challenge, non-increasing counter, broken
  chain); handler tests via `httptest`; a fake APNs server for the forward path (status
  passthrough, 410 unbind, the `BadDeviceToken` gateway retry); topic-forcing and
  priority-clamp tests; garbage collection and cap accounting; rate limiter and
  failed-claim backoff with a fake clock; idempotency-key dedupe.
- **Trellis (Python, stdlib unittest as today)**: the two APNs backends behind one interface
  must be observably equivalent to the existing token-hygiene code; claim forwarding and the
  502-on-transport-failure contract; push-suspension set/clear semantics and persistence
  across restart; the multi-registration-per-key fan-out (two phones, one printer);
  binding-release on card end; startup fail-hard on ambiguous backend config; rejection of
  unattested registrations in relay mode.
- **Sprout (XCTest)**: registration body encoding with the new fields; Keychain pairing and
  attest-key-id lifecycle, including survival of a config wipe and readability after first
  unlock; environment derivation from a fixture provisioning profile (development, production,
  and absent); derivation swap tests. App Attest itself is exercised on a real device during
  rollout, not in unit tests.

## 13. Rollout

This is four implementation plans, not one; each is a separate spec-to-plan cycle.

1. **Canopy service** — build and deploy behind Caddy. Verify standalone with synthetic
   claims and pushes (`curl` a challenge, a claim carrying a captured real-device
   attestation, and a push to a sandbox token), asserting binding transitions and APNs
   passthrough. No Trellis or app dependency yet.
2. **Trellis relay mode** — the two-backend interface, auto-enrollment, claim forwarding,
   push-suspension, binding release, and the multi-registration registry change.
3. **Sprout pairing** — App Attest, the Keychain moves, environment derivation, the new
   body fields, background refresh, and the push-health row. First true end-to-end sandbox
   test happens here, on a real device.
4. **Rename, dogfood, distribute** — la-push → Trellis across dirs, container, and docs;
   owner DNS gains `trellis.<domain>` and keeps `lapush.<domain>` as a CNAME; the owner
   flips his own Trellis to relay mode (DIRECT stays supported and tested); write the
   self-hoster guide with a one-file compose bringing up Bambuddy + Trellis with
   `CANOPY_URL` preset; then App Store submission. Review will need a reachable demo
   Bambuddy + Trellis with demo credentials, since the app is a client of a self-hosted
   server.

## 14. Out of scope / future hardening

- **Encrypted content-state** for the native client (ciphertext blob decrypted in the widget
  with an App-Group-shared key), which would remove printer and file names from Canopy's
  view entirely. The envelope still cannot be encrypted (§7).
- Alert banners end-to-end encrypted via a notification service extension.
- Invite-code enrollment (the valve exists, off by default, §6).
- Android/FCM — would add a `platform` field to `/register-device` and a second sender in
  Trellis (`docs/guides/android.md`); Canopy would gain an FCM credential and a topic-table
  entry, and Play Integrity would replace App Attest as the device anchor.
- A payload-scrubbing knob (user opts filenames out of push payloads at the Trellis level).
- Operator tooling beyond manual unbind by token hash, which **is** in scope as the support
  backstop for a stuck binding.
