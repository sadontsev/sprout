# Canopy

The owner-hosted APNs relay for Sprout. Holds the APNs signing keys and decides
who may push to which device token; understands nothing about Live Activities.

Design: `docs/design/push-architecture.md`.

Canopy accepts inbound requests only. It never contacts a user's Bambuddy, and
it stores hashes, public keys and counters — never push payloads, never raw
tokens.

## Run

All configuration is environment variables, and everything that matters is
required rather than defaulted — this service holds the signing keys for every
install of the app, so a missing value stops the process instead of silently
selecting a behaviour nobody chose.

    CANOPY_BUNDLE_ID=com.example.app \
    CANOPY_TEAM_ID=TEAMID6789 \
    CANOPY_APNS_KEY_SANDBOX=/keys/sandbox.p8 \
    CANOPY_APNS_KEY_ID_SANDBOX=ABCDE12345 \
    CANOPY_APNS_KEY_PRODUCTION=/keys/production.p8 \
    CANOPY_APNS_KEY_ID_PRODUCTION=FGHIJ67890 \
    CANOPY_APPLE_ROOT_CA=/keys/apple-app-attest-root.pem \
    CANOPY_DB=/var/lib/canopy/canopy.db \
    CANOPY_ADDR=127.0.0.1:8080 \
      ./canopy

Optional: `CANOPY_INVITE_CODE` gates enrollment, `CANOPY_MAX_TENANTS` caps it,
and `CANOPY_ALLOW_DEVELOPMENT_ATTEST=1` permits Apple's development App Attest
environment (leave unset in production).

`CANOPY_DEVICECHECK_KEY` + `CANOPY_DEVICECHECK_KEY_ID` enable the fraud metric.
That is a **DeviceCheck** key from Certificates, Identifiers & Profiles — not
the APNs key above, and not an App Store Connect key, though all three download
as `AuthKey_<id>.p8` and are identical on disk. Its JWT is issued by the TEAM ID
with no `aud`, where an App Store Connect token carries an issuer UUID and
`aud: appstoreconnect-v1`; the wrong one answers 401 with nothing that says so.
There is no issuer variable: the issuer is `CANOPY_TEAM_ID`.

`.env.example` documents the rest. `docker compose up -d --build` is the normal
path; `scripts-deploy.sh` does it remotely, with a backup first.

Two APNs keys are required, one per environment, because modern APNs keys are
environment-scoped: the `BadDeviceToken` retry swaps host *and* signing key
together. A legacy universal key may be pointed at both paths.

## Operating

### Enrolment

Open by default, and for a relay serving an App Store build that is the point:
a stranger installs the app, deploys their own Trellis, and it enrols itself
with nothing to ask you for. It receives a tenant id, a bearer, and a recovery
code only it ever sees.

Open enrolment is not open access. A tenant that has just enrolled can do
nothing: pushing needs a binding, a binding needs an App Attest claim from a
genuine build on real hardware, and `Kind.Permits` limits what a binding may
send. Verified against the live relay — a freshly enrolled stranger pushing at
another tenant's token gets `403 not_owner`, for a Live Activity update and for
an alert banner alike.

What open enrolment does expose is the tenant table. `CANOPY_MAX_TENANTS`
(default 10000) bounds it and enrolment is rate-limited to 2/min per IP, so
filling it from one address takes days — but it is the resource to watch, and
the one reason to set `CANOPY_INVITE_CODE` on a relay that is not meant to
serve the public.

An invite gates NEW tenants only. A recovery code skips it, so a user who lost
their data volume gets back in without asking you for anything.

### Looking at state

There is no admin API — deliberately, since one would be a second way to reach
every binding. Read the database directly:

    sqlite3 data/canopy.db \
      "SELECT binding_kind, apns_environment, substr(token_hash,1,12), \
              datetime(lease_expiry/1000,'unixepoch') FROM bindings;"

`released_at IS NULL AND lease_expiry > now` is what "live" means.

### Unbinding

The recovery path when a token is stuck — most often `kind_mismatch`, where a
token was first bound under one kind and the honest owner now claims it under
another:

    sqlite3 data/canopy.db "DELETE FROM bindings WHERE token_hash = '<hash>';"

That returns the token to UNSEEN, and the next honest claim takes it. Tenants
can do this for their own bindings over the API (`DELETE /v1/bindings`); the
manual route is for when they cannot.

### Removing tenants that never bound anything

    ./canopy prune-tenants                    # reports, deletes nothing
    ./canopy prune-tenants --apply            # deletes what it just listed
    ./canopy prune-tenants --older-than 90d   # be more conservative

Dry run by default, and the age bound is a MINIMUM. That direction is the point: an empty tenant
that enrolled an hour ago is far more likely to be a real deployment mid-setup — enrolled, app not
opened yet — than junk. Doing this by hand once, with the filter the other way round, deleted a real
user's tenant and left them holding credentials this database no longer recognised, with nothing on
their side to explain why push had stopped.

A tenant holding any binding is never a candidate, released or expired, and `DeleteTenant` refuses
one in SQL rather than trusting the caller to have checked.

### Backups

`data/` holds the bindings and the attested public keys, and **a device cannot
re-attest on demand**. Losing it costs every install a re-attestation round it
has no way to know it needs, so this is durable state rather than a cache.
`scripts-deploy.sh` takes a WAL-correct copy (`sqlite3 .backup`, no downtime)
before every deploy; if you deploy another way, take one yourself.

### The fraud metric

An hourly sweep redeems each stored attestation receipt and records how many
keys that device has attested, alerting above 25. It is entirely optional: with
no DeviceCheck key the sweep never runs and every other check is unaffected.

A newly created DeviceCheck key **does not work for up to 24 hours** — until
Apple propagates it, tokens signed by it are refused without being verified, so
a deliberately corrupted signature and a valid one fail identically. The
redemption endpoint answers a bare 401 with an empty body, even to a request
carrying no Authorization header, so it cannot tell you which. To distinguish
propagation from a wrong key, sign a token with the same key and send it to
`api.development.devicecheck.apple.com/v1/validate_device_token`, which returns
a readable message.

## Test

    go test ./...

`internal/appattest/README.md` explains the one fixture that is not committed
and why capturing it matters: every other test here builds its attestation with
the same code that parses it, and this package has already shipped a verifier
and a fixture that agreed with each other while both were wrong about what Apple
signs.

## Dependency budget

Three, total, forever: `modernc.org/sqlite`, `golang.org/x/time/rate`,
`github.com/fxamacker/cbor/v2`. This service holds the signing keys for every
install of the app; its supply chain is part of its threat model.
