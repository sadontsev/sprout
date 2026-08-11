# Trellis + Canopy: multi-tenant push for App Store distribution

**Status:** approved design, not yet implemented
**Date:** 2026-08-11

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
- no user can push notifications to another user's devices, even with a stolen push token;
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
│                          builds payloads,  │    │ · limits    │
│                          MakerWorld colls  │    └─────────────┘
└──────────────────▲─────────────────────────┘
                   │ /register* (+ pairing secret)
                 phone (Sprout, App Store build)
```

Invariants:

1. **Canopy never learns what a Live Activity is.** All ActivityKit intelligence —
   `classify()`, `meaningful_change()`, `MIN_UPDATE_S` spacing, priority 5-vs-10 choice,
   push-to-start arming, dismissal reconcile, the expo-vs-native envelope split — stays in
   Trellis, unchanged. Canopy is a signing gate that validates *who may push to which
   token* and forwards opaque payloads.
2. **The phone never talks to Canopy.** Its only server is its own Trellis (and Bambuddy).
3. **The owner's infrastructure never talks to any user's Bambuddy.** Canopy accepts
   inbound requests only.
4. **A tenant can never choose an APNs topic.** Canopy derives the topic from `push_type`
   against a hardcoded two-entry table; those are the only strings it will ever sign for.
5. **Nothing Apple-specific reaches Trellis in relay mode.** Key id, team id, topic, APNs
   host all live in Canopy — so the owner can rotate the `.p8` at any time with zero action
   from any user or tenant.

## 4. Threat model

Assets: the `.p8` (signs pushes for every install of the app), users' push tokens, users'
print metadata (printer names, filenames — they transit push payloads), Canopy's tenant
credentials.

| Adversary / scenario | Outcome under this design |
|---|---|
| Attacker steals a push token (victim's logs, LAN sniffing) | Useless. Binding a token requires the pairing secret, which never appears in push traffic — only in registrations phone → own Trellis → Canopy. Pushes are only accepted from the bound tenant. |
| Attacker enrolls a tenant and probes random tokens | Tokens are 32-byte APNs-generated values; guessing is infeasible. Unbound-token pushes are rejected. Per-tenant and per-IP rate limits cap the probe rate. |
| A user's Trellis box is fully compromised | Attacker gets that user's tokens, tenant credential, and observes pairing secrets in transit. Blast radius: junk pushes to that user's own devices only. Recovery: the phone re-registers through a clean Trellis, which re-points bindings away from the attacker; pairing-secret rotation (`previous_secret`) evicts definitively. Worst case (attacker rotates first): push DOS for that one user until lease expiry (30 days). Never cross-user. |
| A tenant floods pushes (hostile or broken) | Per-token, per-tenant, and global rate limits; circuit breaker returns 429 and alerts the owner. Protects the Apple developer relationship. |
| Canopy itself is compromised | Attacker holds the `.p8` → can push arbitrary content to all installs until the key is revoked and rotated. Same class of risk the owner's own server carries today, now concentrated on one hardened box. Mitigations: minimal surface (static Go binary, ~1 dependency), no payloads or raw tokens at rest, TLS via reverse proxy, monitoring, backups, key rotation requires no tenant action. |
| The owner snoops on users | Sees per-push: raw token + payload, in memory, for one HTTPS forward. Stores only hashes and counters (§8). Cannot reach any user's Bambuddy. This is a documented trust statement, not cryptography — Live Activity payloads cannot be end-to-end encrypted (§7). |

## 5. Pairing and binding

The core insight: in a self-hosting setup the **server is the disposable party** and the
**phone is the durable one**. Binding tokens to a server credential (pure possession /
first-writer-wins) produces the worst failure mode — a rebuilt server is locked out of its
own user's tokens. So ownership follows a **phone-minted pairing secret** instead.

- The app mints a 32-byte random pairing secret once, stores it in its own Keychain item
  (separate from `AppConfig`, so sign-out/re-onboarding never destroys it).
- Every token registration the app already sends (`/register`, `/register-start`,
  `/register-device`) carries the pairing secret. Trellis forwards a claim to Canopy,
  authenticated with its tenant credential. **Trellis never persists pairing secrets** —
  they transit only. A stolen `registrations.json` backup contains no binding authority.

Canopy's binding state machine, keyed by `SHA-256(token)`:

| State + event | Rule |
|---|---|
| UNBOUND + claim | Bind: store `{hash(pairing_secret), tenant, kind, environment, lease_expiry = now + 30d}`. |
| BOUND + claim, pairing secret matches | Accept; **re-point the binding to the claiming tenant**; renew lease. The pairing secret decides ownership; the tenant is just the current delivery agent. |
| BOUND + claim with `previous_secret` matching the stored hash | Rotation: replace the stored hash with `hash(pairing_secret)`, re-point tenant, renew lease. Definitive eviction of anyone who knew the old secret. |
| BOUND + claim, mismatch, lease alive | 403. |
| BOUND + claim, mismatch, lease expired | Treat as fresh claim (rebind). Recovers the phone-wiped / Keychain-lost edge within ≤30 days. |
| BOUND + push from bound tenant | Allowed. **Lease expiry never blocks pushes** — it only opens the token to new claims. A user who doesn't open the app for months loses nothing. |
| BOUND + push from any other tenant | 403 `not_owner`. |
| APNs answers 410 (or 400 `BadDeviceToken`) | Delete the binding — this is what frees a token for future re-claim. |

Lifecycle scenarios this resolves by construction:

- **Server dies, rebuilt from nothing**: new tenant enrolls; the phone's next app launch
  re-registers tokens through it with the same pairing secret; Canopy re-points instantly.
- **Migration to a new box/domain**: identical — re-registration *is* the migration; no
  unbind step exists because none is needed.
- **Per-activity Live Activity tokens** need no special casing: they are born and die with
  each print card, so even a botched binding self-heals on the next card. The pairing
  secret makes them uniform with the long-lived push-to-start and device tokens.

## 6. Canopy specification

**Language: Go.** Rationale: Canopy is the one internet-facing service holding the key, and
it is new code (~400 lines; the only ported logic is a ~50-line ES256-JWT + HTTP/2 client).
Go gives a static binary with stdlib HTTP server, transparent HTTP/2 to APNs via
`net/http`, ES256 over `crypto/ecdsa` (no JWT library), and table-driven tests that fit the
binding state machine exactly. Third-party surface: `modernc.org/sqlite` (pure Go) plus
`golang.org/x/time/rate`. Deployment: `GOOS=linux go build`, scp, systemd, Caddy for TLS.
(Trellis stays Python: its logic is proven and measured, and the Docker container is the
distribution unit, so the language is invisible to self-hosters.)

Endpoints (JSON over HTTPS; tenant auth is `Authorization: Bearer <tenant_id>.<tenant_secret>`):

- `POST /v1/enroll` `{invite_code?}` → `201 {tenant_id, tenant_secret}`. Open enrollment,
  IP-rate-limited (default 5/day/IP); `invite_code` is validated only when the
  `CANOPY_INVITE_CODE` env is set (dormant abuse valve, off by default). Secrets are 32
  random bytes; stored as SHA-256 (high-entropy secrets need no password hashing).
- `POST /v1/claims` `{token, pairing_secret, previous_secret?, environment:
  "production"|"sandbox", kind: "activity"|"start"|"device"}` → `204`, or `403
  pairing_mismatch`. Implements §5. Idempotent; Trellis fires it on every registration.
- `POST /v1/push` `{token, push_type: "liveactivity"|"alert", priority: 5|10, payload}` →
  `200 {apns_status, apns_reason?}`, or `403 not_bound|not_owner`, or `429`. Canopy:
  verifies the caller is the bound tenant; clamps priority to {5, 10}; derives
  `apns-topic` + `apns-push-type` from `push_type` (`liveactivity` →
  `com.mvks5.bambu.push-type.liveactivity`, `alert` → `com.mvks5.bambu`; hardcoded);
  caps payload at APNs' 4096 bytes; signs the JWT (cached ~40 min); POSTs APNs on the
  binding's environment host; returns the APNs status and reason **verbatim** so Trellis's
  existing token hygiene works unchanged; deletes the binding on 410/`BadDeviceToken`.
  Payload contents (`event`, `content-state`, `dismissal-date`, `alert` block, stale dates)
  are opaque passthrough — push-to-start vs update is not Canopy's concern.
- `GET /v1/health` → `{ok, version}`. Deliberately bare — unlike la-push's count-reporting
  health page, Canopy's must reveal nothing about tenants.

Rate limits (env-tunable defaults; a backstop, not shaping — Trellis already shapes at
`MIN_UPDATE_S = 30`):

- per token: sustained 1 push/10 s, burst 5;
- per tenant: 120 pushes/min, 60 claims/min, 50 live bindings;
- global: circuit breaker on APNs error-rate spike or configured QPS ceiling → 429 with
  `Retry-After` + operator alert.

Storage: SQLite, two tables (`tenants`: id, secret_hash, created_at, last_seen;
`bindings`: token_hash, pairing_hash, tenant_id, kind, environment, lease_expiry,
created_at, last_push_at) plus in-memory rate buckets. Raw tokens arrive per-request and
die with it. Daily SQLite backup. If the bindings DB is lost anyway, tokens read as
UNBOUND and re-bind as each phone next launches the app and re-registers — a partial push
outage that self-heals per-device, with no tenant action (Trellis cannot re-claim on its
own: it holds no pairing secrets — accepted trade, see §8).

Logs: tenant id, token-hash prefix, status, latency. Never payloads, never raw tokens,
never per-request IPs.

## 7. Live Activity flow, end to end (relay mode)

1. **App launch** — `pushToStartTokenUpdates` fires → `POST /register-start` to the user's
   Trellis with the pairing secret; Trellis forwards the claim to Canopy. Likewise
   `/register-device` for the alert banner token.
2. **Print starts** — Trellis's poll loop sees a live state with no card and builds the
   push-to-start payload itself (`event: start`, attributes, the mandatory `alert` block —
   the "APNs 200s then silently discards without it" lesson stays encoded in Trellis).
   `POST canopy /v1/push {push_type: liveactivity, priority: 10, payload}`.
3. **Card appears** — ActivityKit mints the per-activity update token; the app's
   `pushTokenUpdates` fires → `/register` with pairing secret → claim → bound.
4. **Updates** — on meaningful change Trellis builds the ContentState envelope (client
   `expo` vs `native` shape stays entirely its concern) and pushes via Canopy at the
   priority it already chooses today. End pushes carry `dismissal-date` in the payload,
   passthrough.
5. **Feedback** — APNs status verbatim; on 400/410 Trellis drops its registration exactly
   as today, and Canopy has dropped the binding.
6. **`/sync` dismissal reconcile** — phone ↔ Trellis only; Canopy uninvolved. The RN
   `/sync` bind path is the one registration that can bind a token `/register` never saw;
   since only the legacy RN app uses `/sync`, those bindings ride the Trellis-minted
   fallback secret (§9) — no RN app change.

Hard limitation, stated in user-facing docs: **Live Activity payloads cannot be
end-to-end encrypted.** ActivityKit decodes ContentState directly from the APNs payload and
Apple provides no mutation hook for the `liveactivity` push type. Printer names and
filenames therefore transit Canopy in plaintext; the no-persistence rules in §6/§8 are the
mitigation, and they are a trust statement, not cryptography. (Alert banners *could* later
be E2E'd via `mutable-content` + a notification service extension; out of scope.)

Additionally, adopt the standing suggestion from `07-realtime.md:898`: Trellis sets
`stale-date` on card pushes so a dead feed (Canopy or Trellis down) visibly stales the
card instead of letting it lie.

## 8. Privacy posture (what the owner can and cannot see)

| Data | Canopy at rest | Canopy in transit | Notes |
|---|---|---|---|
| Push tokens | SHA-256 only | raw, per-request | needed to call APNs |
| Pairing secrets | SHA-256 only | raw, per-claim | durable home is the phone's Keychain only |
| Push payloads (names, progress, temps) | **never** | plaintext, one forward | Apple's design; no logging |
| Tenant credentials | SHA-256 only | bearer over TLS | |
| User Bambuddy URLs / API keys / cameras / libraries | **never** | **never** | Canopy accepts inbound only |
| IP addresses | never (in-memory rate buckets only) | inherent to HTTP | not logged per-request |

Trellis-side: pairing secrets transit but are not persisted (except the legacy-RN fallback
secrets, §9, which are Trellis-minted and marked as such).

## 9. Trellis changes

- **Rename** per §2. `docs/guides/push-notifications.md`, `deploy/README.md`, repo-root
  `CLAUDE.md`, and `docs/native-rewrite/` references updated. Collections, cooldown, p2s,
  classify: untouched.
- **Two-backend APNs interface**: `DIRECT` (today's `.p8` env set — preserved for the
  owner and for self-signers on their own Apple team) and `RELAY` (`CANOPY_URL`). Exactly
  one must be configured; both or neither fails at startup — honoring the lesson from the
  hardcoded-`APNS_*` era (`${VAR:?}` fail-hard style).
- **Auto-enrollment**: in relay mode, on first boot with no stored credential, Trellis
  calls `/v1/enroll` and stores the tenant credential in its data volume
  (`data/tenant.json`, sibling of `registrations.json`).
- **Claim forwarding**: every registration forwards a claim; claims are
  forward-and-forget (no pairing-secret persistence). On push `403` (`not_bound` or
  `not_owner`), Trellis marks the registration push-suspended until a fresh registration
  re-claims it (no retry-spam), and surfaces the condition in its own `/health`.
- **Legacy RN clients**: the RN app will not carry a pairing secret. In relay mode,
  Trellis mints a per-token fallback secret for secretless registrations and persists it
  in `registrations.json`. This re-introduces the server-possessed weakness *only* for the
  legacy app (which remains personal/TestFlight), and is documented as such.

## 10. Sprout changes

- Mint the pairing secret lazily; Keychain item `bambu.pairing`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (token registrations can fire from
  background token-rotation streams; the config blob's `WhenUnlocked` is too strict here).
  Deliberately separate from `AppConfig` so config wipes never destroy it.
- Add `pairing_secret` and `environment` (compile-time: `#if DEBUG` → `sandbox`, else
  `production`) to `StartRegistration`, `CardRegistration`, and the device registration
  body — snake_case, tested like the existing fields. Note: the native app does not yet
  POST `/register-device` at all (a known gap, `13-code-review.md` /
  `00-overview.md:116`); that registration must be built before it can carry the new
  fields, and this design is the reason to finally do it. The `previous_secret` protocol
  field is designed in now; rotation UI ("Reset push pairing") can come later.
- `ConfigRules` derivation becomes `bambuddy.` → `trellis.`; explicit `pushUrl` still
  wins; the RN app's `lapush.` derivation is untouched (the owner keeps a `lapush.` CNAME
  during transition).
- The push on/off toggle, `laPushUrl` vs `resolvePushUrl` split, and off-state behavior
  are already correct and unchanged.

## 11. Failure modes

| Failure | Behavior |
|---|---|
| Canopy down | Pushes and claims fail; Trellis retries with backoff; cards go visibly stale (`stale-date`); local-mode users unaffected. |
| Canopy bindings DB lost | Tokens re-bind as each phone next opens the app (§6). |
| Push rejected `403 not_bound` | Re-claim impossible from Trellis alone; registration marked push-suspended until the phone re-registers; visible in Trellis `/health`. |
| Trellis down / user's server dead | Same as today: no pushes for that user; rebuild + phone re-registration restores everything (§5). |
| Attacker-rotated binding (worst case) | Push DOS for that user's affected tokens until lease expiry (≤30 d); per-activity tokens recover on the next print regardless. |
| APNs key compromised | Owner revokes + uploads a new `.p8` to Canopy; zero tenant/user action (invariant 5, §3). |

## 12. Testing

- **Canopy (Go)**: table-driven tests over the binding state machine (§5's table, one row
  per case: claim/mismatch/lease-expiry/rotation/410-release); handler tests via
  `httptest`; a fake APNs server for the forward path (status passthrough, 410-unbind);
  topic-forcing and priority-clamp tests; rate-limiter tests with a fake clock.
- **Trellis (Python, stdlib unittest as today)**: the two APNs backends behind one
  interface must be observably equivalent to the existing token-hygiene code; claim
  forwarding; fallback-secret minting for secretless registrations; push-suspension on
  `not_bound`; startup fail-hard on ambiguous backend config.
- **Sprout (XCTest)**: extend `LiveActivityRegistrationTests` for the new body fields;
  Keychain pairing-item lifecycle (survives config wipe); derivation swap tests.

## 13. Rollout

1. Build Canopy; deploy on a small VPS behind Caddy; sandbox-test end-to-end with a DEBUG
   build of Sprout (environment routing exercised from day one).
2. Rename la-push → Trellis (dir, container, docs); owner DNS gains `trellis.<domain>`,
   keeps `lapush.<domain>` as a CNAME for the RN app.
3. Implement Trellis relay mode + claim forwarding + legacy fallback; the owner flips his
   own Trellis to relay mode (dogfooding; DIRECT mode remains supported and tested).
4. Sprout: pairing secret + new fields + derivation; TestFlight build.
5. Self-hoster guide: one compose file bringing up Bambuddy + Trellis with `CANOPY_URL`
   preset to the owner's relay; secrets checklist.
6. App Store submission: review requires a reachable demo Bambuddy + Trellis with demo
   credentials (the app is a client of a self-hosted server — App Review must be able to
   log in). Distribution checklist, not architecture.

## 14. Out of scope / future hardening

- **App Attest** on enrollment or claims (would close the narrow claim-before-first-bind
  race for leaked tokens); the claim API's rules don't change, so it layers on cleanly.
- Invite-code enrollment (dormant valve already present, §6).
- E2E alert banners via notification service extension.
- Android/FCM (would add a `platform` field to `/register-device` and a second sender in
  Trellis, per `docs/guides/android.md` — Canopy would gain an FCM credential and topic
  table entry).
- Payload-scrubbing knob (user opts filenames out of push payloads at the Trellis level).
- Operator tooling: manual unbind by token hash for support cases.
