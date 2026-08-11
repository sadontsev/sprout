# Canopy

The owner-hosted APNs relay for Sprout. Holds the APNs signing keys and decides
who may push to which device token; understands nothing about Live Activities.

Design: `docs/superpowers/specs/2026-08-11-trellis-canopy-push-design.md`.

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

Two APNs keys are required, one per environment, because modern APNs keys are
environment-scoped: the `BadDeviceToken` retry swaps host *and* signing key
together. A legacy universal key may be pointed at both paths.

## Test

    go test ./...

## Dependency budget

Three, total, forever: `modernc.org/sqlite`, `golang.org/x/time/rate`,
`github.com/fxamacker/cbor/v2`. This service holds the signing keys for every
install of the app; its supply chain is part of its threat model.
