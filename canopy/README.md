# Canopy

The owner-hosted APNs relay for Sprout. Holds the APNs signing keys and decides
who may push to which device token; understands nothing about Live Activities.

Design: `docs/superpowers/specs/2026-08-11-trellis-canopy-push-design.md`.

Canopy accepts inbound requests only. It never contacts a user's Bambuddy, and
it stores hashes, public keys and counters — never push payloads, never raw
tokens.

## Test

    go test ./...

## Dependency budget

Three, total, forever: `modernc.org/sqlite`, `golang.org/x/time/rate`,
`github.com/fxamacker/cbor/v2`. This service holds the signing keys for every
install of the app; its supply chain is part of its threat model.
