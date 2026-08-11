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
