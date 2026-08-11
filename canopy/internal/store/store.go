// Package store owns Canopy's SQLite persistence. It translates binding rows to
// and from the database and answers the cap query; it makes no decisions.
package store

import (
	"database/sql"
	"errors"
	"time"

	"github.com/mvks5/canopy/internal/binding"

	_ "modernc.org/sqlite"
)

// Store is a handle on the Canopy database.
type Store struct{ db *sql.DB }

// Open opens (creating if needed) the database at path and applies the schema.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

// Close releases the database handle.
func (s *Store) Close() error { return s.db.Close() }

// GetBinding returns the row for tokenHash, or (nil, nil) when the token is
// UNSEEN. A missing row is not an error: "no row exists" is a state the decision
// rules act on, not a failure.
func (s *Store) GetBinding(tokenHash string) (*binding.Row, error) {
	const q = `SELECT token_hash, binding_kind, apns_environment, tenant, device_id,
	                  pairing_public_key, attest_key_id, lease_expiry,
	                  last_delivery_at, last_successful_claim_at, last_failed_claim_at,
	                  released_at, created_at
	             FROM bindings WHERE token_hash = ?`

	var (
		r         binding.Row
		kind      string
		lease     int64
		delivery  int64
		okClaim   int64
		failClaim int64
		released  sql.NullInt64
		created   int64
	)
	err := s.db.QueryRow(q, tokenHash).Scan(
		&r.TokenHash, &kind, &r.APNSEnvironment, &r.Tenant, &r.DeviceID,
		&r.PairingPublicKey, &r.AttestKeyID, &lease,
		&delivery, &okClaim, &failClaim, &released, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	r.Kind = binding.Kind(kind)
	r.LeaseExpiry = time.UnixMilli(lease).UTC()
	r.LastDeliveryAt = time.UnixMilli(delivery).UTC()
	r.LastSuccessfulClaimAt = time.UnixMilli(okClaim).UTC()
	r.LastFailedClaimAt = time.UnixMilli(failClaim).UTC()
	r.CreatedAt = time.UnixMilli(created).UTC()
	if released.Valid {
		t := time.UnixMilli(released.Int64).UTC()
		r.ReleasedAt = &t
	}
	return &r, nil
}

// PutBinding inserts or replaces the row for r.TokenHash.
func (s *Store) PutBinding(r *binding.Row) error {
	const q = `INSERT INTO bindings (
	               token_hash, binding_kind, apns_environment, tenant, device_id,
	               pairing_public_key, attest_key_id, lease_expiry,
	               last_delivery_at, last_successful_claim_at, last_failed_claim_at,
	               released_at, created_at)
	           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
	           ON CONFLICT(token_hash) DO UPDATE SET
	               binding_kind = excluded.binding_kind,
	               apns_environment = excluded.apns_environment,
	               tenant = excluded.tenant,
	               device_id = excluded.device_id,
	               pairing_public_key = excluded.pairing_public_key,
	               attest_key_id = excluded.attest_key_id,
	               lease_expiry = excluded.lease_expiry,
	               last_delivery_at = excluded.last_delivery_at,
	               last_successful_claim_at = excluded.last_successful_claim_at,
	               last_failed_claim_at = excluded.last_failed_claim_at,
	               released_at = excluded.released_at,
	               created_at = excluded.created_at`

	var released any
	if r.ReleasedAt != nil {
		released = r.ReleasedAt.UnixMilli()
	}
	_, err := s.db.Exec(q,
		r.TokenHash, string(r.Kind), r.APNSEnvironment, r.Tenant, r.DeviceID,
		r.PairingPublicKey, r.AttestKeyID, r.LeaseExpiry.UnixMilli(),
		r.LastDeliveryAt.UnixMilli(), r.LastSuccessfulClaimAt.UnixMilli(),
		r.LastFailedClaimAt.UnixMilli(), released, r.CreatedAt.UnixMilli())
	return err
}

// LiveCount returns how many of tenant's bindings count against its cap: rows
// that are unreleased and still inside their lease.
func (s *Store) LiveCount(tenant string, now time.Time) (int, error) {
	const q = `SELECT COUNT(*) FROM bindings
	            WHERE tenant = ? AND released_at IS NULL AND lease_expiry > ?`
	var n int
	err := s.db.QueryRow(q, tenant, now.UnixMilli()).Scan(&n)
	return n, err
}

// PutVouch records an outstanding vouch. The nonce is stored as a digest: like
// every other secret Canopy must recognise, it is never held in the clear.
func (s *Store) PutVouch(tokenHash, nonceHash, tenant string, expiresAt, now time.Time) error {
	const q = `INSERT OR REPLACE INTO vouches
	               (token_hash, nonce_hash, tenant, expires_at, created_at)
	           VALUES (?,?,?,?,?)`
	_, err := s.db.Exec(q, tokenHash, nonceHash, tenant, expiresAt.UnixMilli(), now.UnixMilli())
	return err
}

// ConsumeVouch reports whether an unexpired vouch exists for exactly this token,
// nonce and tenant, and deletes it. Single use is the point: a nonce that could
// be replayed would prove reachability once and authorise binding forever.
func (s *Store) ConsumeVouch(tokenHash, nonceHash, tenant string, now time.Time) (bool, error) {
	const q = `DELETE FROM vouches
	            WHERE token_hash = ? AND nonce_hash = ? AND tenant = ? AND expires_at > ?`
	res, err := s.db.Exec(q, tokenHash, nonceHash, tenant, now.UnixMilli())
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// CountVouchesSince counts vouches minted for a token across every tenant. The
// cap built on it is deliberately global: a per-tenant limit alone is defeated
// by enrolling more tenants, and what that would buy an attacker is waking a
// known victim's app at will.
func (s *Store) CountVouchesSince(tokenHash string, since time.Time) (int, error) {
	const q = `SELECT COUNT(*) FROM vouches WHERE token_hash = ? AND created_at >= ?`
	var n int
	err := s.db.QueryRow(q, tokenHash, since.UnixMilli()).Scan(&n)
	return n, err
}

// PurgeExpiredVouches removes vouches past their expiry.
func (s *Store) PurgeExpiredVouches(now time.Time) error {
	_, err := s.db.Exec(`DELETE FROM vouches WHERE expires_at <= ?`, now.UnixMilli())
	return err
}

// --- tenants ---

// PutTenant creates a tenant.
func (s *Store) PutTenant(id, secretHash, recoveryHash string, now time.Time) error {
	const q = `INSERT INTO tenants (id, secret_hash, recovery_hash, created_at, last_seen)
	           VALUES (?,?,?,?,?)`
	_, err := s.db.Exec(q, id, secretHash, recoveryHash, now.UnixMilli(), now.UnixMilli())
	return err
}

// TenantSecretHash returns the stored secret digest for id, or "" if unknown.
func (s *Store) TenantSecretHash(id string) (string, error) {
	var h string
	err := s.db.QueryRow(`SELECT secret_hash FROM tenants WHERE id = ?`, id).Scan(&h)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return h, err
}

// TenantByRecovery returns the tenant id whose recovery digest matches, or "".
func (s *Store) TenantByRecovery(recoveryHash string) (string, error) {
	var id string
	err := s.db.QueryRow(`SELECT id FROM tenants WHERE recovery_hash = ?`, recoveryHash).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// RotateTenantSecret replaces a tenant's secret and recovery digests, keeping
// its identity. This is what makes a rebuilt server recover its bindings: the
// tenant is the same party, holding a new credential.
func (s *Store) RotateTenantSecret(id, secretHash, recoveryHash string, now time.Time) error {
	const q = `UPDATE tenants SET secret_hash = ?, recovery_hash = ?, last_seen = ? WHERE id = ?`
	_, err := s.db.Exec(q, secretHash, recoveryHash, now.UnixMilli(), id)
	return err
}

// CountTenants returns the total number of enrolled tenants.
func (s *Store) CountTenants() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM tenants`).Scan(&n)
	return n, err
}

// --- challenges ---

// PutChallenge records an issued challenge.
func (s *Store) PutChallenge(nonceHash, tenant, purpose string, expiresAt, now time.Time) error {
	const q = `INSERT OR REPLACE INTO challenges (nonce_hash, tenant, purpose, expires_at, created_at)
	           VALUES (?,?,?,?,?)`
	_, err := s.db.Exec(q, nonceHash, tenant, purpose, expiresAt.UnixMilli(), now.UnixMilli())
	return err
}

// ConsumeChallenge deletes and reports the challenge matching all of nonce,
// tenant and purpose. Checking all three is the point: the tenant column stops
// a captured claim being replayed under a different tenant, and the purpose
// column stops a 15-minute attestation challenge extending the assertion replay
// window.
func (s *Store) ConsumeChallenge(nonceHash, tenant, purpose string, now time.Time) (bool, error) {
	const q = `DELETE FROM challenges
	            WHERE nonce_hash = ? AND tenant = ? AND purpose = ? AND expires_at > ?`
	res, err := s.db.Exec(q, nonceHash, tenant, purpose, now.UnixMilli())
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// PurgeExpiredChallenges removes challenges past their expiry.
func (s *Store) PurgeExpiredChallenges(now time.Time) error {
	_, err := s.db.Exec(`DELETE FROM challenges WHERE expires_at <= ?`, now.UnixMilli())
	return err
}

// ReleaseBinding marks the row released, but only for the tenant that holds it.
// Release is not deletion: the row keeps its anchors and its retention horizon,
// so a released token is never reopened to a first-come claim.
func (s *Store) ReleaseBinding(tokenHash, tenant string, now time.Time) (bool, error) {
	const q = `UPDATE bindings SET released_at = ? WHERE token_hash = ? AND tenant = ?`
	res, err := s.db.Exec(q, now.UnixMilli(), tokenHash, tenant)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// DeleteBinding removes the row, returning the token to UNSEEN. Only the tenant
// that holds it may do this: it is the most security-sensitive transition in the
// design, which is why it is an explicit, authenticated, user-initiated action
// rather than something a rule infers.
func (s *Store) DeleteBinding(tokenHash, tenant string) (bool, error) {
	res, err := s.db.Exec(`DELETE FROM bindings WHERE token_hash = ? AND tenant = ?`, tokenHash, tenant)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// DropBinding removes the row regardless of tenant. Used when APNs reports the
// token is dead, where there is no tenant to consult.
func (s *Store) DropBinding(tokenHash string) error {
	_, err := s.db.Exec(`DELETE FROM bindings WHERE token_hash = ?`, tokenHash)
	return err
}

// MarkDelivered records a successful push: it stamps the delivery clock and
// renews the lease, which is what keeps an actively-used token from ever
// drifting toward dormancy.
func (s *Store) MarkDelivered(tokenHash string, now, leaseExpiry time.Time) error {
	const q = `UPDATE bindings SET last_delivery_at = ?, lease_expiry = ? WHERE token_hash = ?`
	_, err := s.db.Exec(q, now.UnixMilli(), leaseExpiry.UnixMilli(), tokenHash)
	return err
}

// SetAPNSEnvironment persists a gateway self-correction. It is deliberately not
// something a claim can do: the phone derives the environment from an
// entitlement and would keep supplying the same wrong value, silently reverting
// the correction.
func (s *Store) SetAPNSEnvironment(tokenHash, env string) error {
	_, err := s.db.Exec(`UPDATE bindings SET apns_environment = ? WHERE token_hash = ?`, env, tokenHash)
	return err
}
