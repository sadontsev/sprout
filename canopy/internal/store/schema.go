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

-- A vouch proves the claimant actually receives pushes on the token it is
-- claiming. It is keyed by token AND tenant and consumed on use: revision 7 of
-- the design recorded it per install instead, which let an attacker vouch a
-- token they owned and then bind anybody's.
CREATE TABLE IF NOT EXISTS vouches (
    token_hash  TEXT NOT NULL,
    nonce_hash  TEXT NOT NULL,
    tenant      TEXT NOT NULL,
    expires_at  INTEGER NOT NULL,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (token_hash, nonce_hash)
);

CREATE INDEX IF NOT EXISTS vouches_token_created
    ON vouches (token_hash, created_at);

CREATE TABLE IF NOT EXISTS tenants (
    id            TEXT PRIMARY KEY,
    secret_hash   TEXT NOT NULL,
    recovery_hash TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    last_seen     INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS tenants_recovery ON tenants (recovery_hash);

-- A challenge is bound to the tenant it was issued to and to the purpose it was
-- issued for. Storing those columns and never reading them left a claim
-- replayable under a different tenant, which is worse than a verbatim replay
-- because every accepting rule re-points the tenant.
-- Attest keys outlive the bindings they were used to claim: an assertion must
-- still verify long after any particular card is gone. They are therefore never
-- garbage-collected along with bindings.
CREATE TABLE IF NOT EXISTS attest_keys (
    key_id             TEXT PRIMARY KEY,
    public_key         TEXT NOT NULL,
    counter            INTEGER NOT NULL,
    attest_environment TEXT NOT NULL,
    receipt            BLOB,
    first_seen         INTEGER NOT NULL,
    last_seen          INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS challenges (
    nonce_hash TEXT PRIMARY KEY,
    tenant     TEXT NOT NULL,
    purpose    TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);
`

// migrations are additive column adds applied after the schema, each idempotent
// because SQLite has no ADD COLUMN IF NOT EXISTS and a duplicate is the normal
// case on every start after the first.
//
// A CREATE TABLE IF NOT EXISTS never revisits a table that already exists, so a
// column added to the schema above alone would reach a fresh database and skip
// every deployment that already has rows — which is precisely the one that has
// the history worth reading.
var migrations = []string{
	// The fraud-assessment metric, kept beside the receipt it is read from.
	// risk_metric is NULLABLE on purpose: an unredeemed key has no answer, and a
	// NOT NULL DEFAULT 0 would record every device as clean rather than unknown.
	`ALTER TABLE attest_keys ADD COLUMN risk_metric INTEGER`,
	`ALTER TABLE attest_keys ADD COLUMN risk_checked_at INTEGER`,
	// When Apple will next accept a redemption of this receipt. Redeeming sooner
	// answers 429 and burns the attempt without producing a metric.
	`ALTER TABLE attest_keys ADD COLUMN risk_not_before INTEGER`,
}
