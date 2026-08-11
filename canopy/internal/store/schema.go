package store

// schema is applied on every Open. Canopy stores hashes, public keys and
// counters — never push payloads, never raw tokens. Raw tokens arrive per
// request and die with it.
const schema = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS bindings (
    token_hash                TEXT PRIMARY KEY,
    binding_kind              TEXT NOT NULL,
    apns_environment          TEXT NOT NULL,
    tenant                    TEXT NOT NULL,
    device_id                 TEXT NOT NULL,
    pairing_public_key        TEXT NOT NULL,
    attest_key_id             TEXT NOT NULL,
    lease_expiry              INTEGER NOT NULL,
    last_delivery_at          INTEGER NOT NULL DEFAULT 0,
    last_successful_claim_at  INTEGER NOT NULL DEFAULT 0,
    last_failed_claim_at      INTEGER NOT NULL DEFAULT 0,
    released_at               INTEGER,
    created_at                INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS bindings_tenant_lease
    ON bindings (tenant, released_at, lease_expiry);
`
