// Package store owns Canopy's SQLite persistence. It translates binding rows to
// and from the database and answers the cap query; it makes no decisions.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/binding"

	_ "modernc.org/sqlite"
)

// Store is a handle on the Canopy database.
type Store struct{ db *sql.DB }

// Open opens (creating if needed) the database at path and applies the schema.
func Open(path string) (*Store, error) {
	// PRAGMAs belong in the DSN, not in the schema. database/sql keeps a POOL, and most pragmas are
	// per-connection: one executed through db.Exec lands on whichever connection served it and no
	// other connection in the pool ever sees it. In the DSN the driver applies them to each
	// connection as it opens.
	//
	// busy_timeout was missing altogether. Without it a writer that finds the database locked fails
	// IMMEDIATELY with SQLITE_BUSY instead of waiting, and in production that surfaced as
	// `ERROR "issue challenge" err="database is locked"` — each one a claim the app could not
	// complete, so a push token went unbound and a card stopped updating until the retry. It is
	// intermittent and self-healing, which is exactly why it went unnoticed.
	//
	// foreign_keys was in the schema, and therefore ON for one connection out of the pool.
	dsn := "file:" + path + "?" + strings.Join([]string{
		"_pragma=busy_timeout(5000)",
		"_pragma=journal_mode(WAL)",
		"_pragma=foreign_keys(on)",
		// NORMAL is the documented companion to WAL: durable across a process crash, at risk only
		// from an OS-level one — and this database is restored from backup in that case anyway.
		"_pragma=synchronous(normal)",
	}, "&")
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	for _, m := range migrations {
		// "duplicate column name" is the expected answer on every start after the
		// one that applied it. Any other error is real and must stop the process,
		// so this matches on the message rather than swallowing all failures.
		if _, err := db.Exec(m); err != nil && !strings.Contains(err.Error(), "duplicate column name") {
			db.Close()
			return nil, fmt.Errorf("migration %q: %w", m, err)
		}
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

// --- attest keys ---

// AttestKey is a device's App Attest key as Canopy knows it.
type AttestKey struct {
	KeyID       string
	PublicKey   string // base64url X9.63 uncompressed point
	Counter     uint32
	Environment string
	Receipt     []byte
}

// PutAttestKey records a newly attested key. The receipt is captured here
// because Apple only issues one at attestation time, and it is the input to the
// fraud-assessment metric that eventually bounds the hooked-device residual.
func (s *Store) PutAttestKey(k AttestKey, now time.Time) error {
	const q = `INSERT INTO attest_keys
	               (key_id, public_key, counter, attest_environment, receipt, first_seen, last_seen)
	           VALUES (?,?,?,?,?,?,?)
	           ON CONFLICT(key_id) DO UPDATE SET last_seen = excluded.last_seen`
	_, err := s.db.Exec(q, k.KeyID, k.PublicKey, k.Counter, k.Environment, k.Receipt,
		now.UnixMilli(), now.UnixMilli())
	return err
}

// GetAttestKey returns the stored key, or (nil, nil) if Canopy has never seen
// it — which is what tells a caller to answer reattest_required rather than
// treating the claim as hostile.
func (s *Store) GetAttestKey(keyID string) (*AttestKey, error) {
	const q = `SELECT key_id, public_key, counter, attest_environment, receipt
	             FROM attest_keys WHERE key_id = ?`
	var k AttestKey
	err := s.db.QueryRow(q, keyID).Scan(&k.KeyID, &k.PublicKey, &k.Counter, &k.Environment, &k.Receipt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &k, nil
}

// BumpAttestCounter persists the counter an assertion advanced to.
func (s *Store) BumpAttestCounter(keyID string, counter uint32, now time.Time) error {
	const q = `UPDATE attest_keys SET counter = ?, last_seen = ? WHERE key_id = ?`
	_, err := s.db.Exec(q, counter, now.UnixMilli(), keyID)
	return err
}

// AttestKeysDueForRedemption returns keys whose receipt Apple will accept now.
//
// A key is due when it has a receipt and either has never been redeemed or has
// passed the not-before Apple stated. Ordering by that instant means a backlog
// drains oldest-first rather than starving whichever key sorts last by id.
//
// limit bounds one pass: redemption is a network round trip per key, and the
// operator's DeviceCheck key is shared with everything else that uses it.
func (s *Store) AttestKeysDueForRedemption(now time.Time, limit int) ([]AttestKey, error) {
	const q = `SELECT key_id, public_key, counter, attest_environment, receipt
	             FROM attest_keys
	            WHERE receipt IS NOT NULL AND LENGTH(receipt) > 0
	              AND (risk_not_before IS NULL OR risk_not_before <= ?)
	         ORDER BY COALESCE(risk_not_before, 0) ASC, key_id ASC
	            LIMIT ?`
	rows, err := s.db.Query(q, now.UnixMilli(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []AttestKey
	for rows.Next() {
		var k AttestKey
		if err := rows.Scan(&k.KeyID, &k.PublicKey, &k.Counter, &k.Environment, &k.Receipt); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// AttestRisk is one key's fraud assessment as Canopy recorded it.
type AttestRisk struct {
	Metric    int
	HasMetric bool
	CheckedAt time.Time
	NotBefore time.Time
}

// PutAttestRisk records an assessment and the refreshed receipt that produced it.
//
// The receipt is replaced because Apple supersedes it on every redemption: keeping
// the original would make the second redemption fail and every one after it.
// metric is written only when present — an ATTEST receipt yields none, and writing
// a zero would turn "not yet known" into "known to be clean".
func (s *Store) PutAttestRisk(keyID string, metricValue int, hasMetric bool, receipt []byte, notBeforeAt, now time.Time) error {
	var metric any
	if hasMetric {
		metric = metricValue
	}
	var notBefore any
	if !notBeforeAt.IsZero() {
		notBefore = notBeforeAt.UnixMilli()
	}
	const q = `UPDATE attest_keys
	              SET risk_metric = COALESCE(?, risk_metric),
	                  risk_checked_at = ?,
	                  risk_not_before = ?,
	                  receipt = ?
	            WHERE key_id = ?`
	_, err := s.db.Exec(q, metric, now.UnixMilli(), notBefore, receipt, keyID)
	return err
}

// DeferAttestRedemption pushes a key's next attempt out without recording a
// metric. Used when Apple throttles or the call fails: without it a permanently
// failing key is retried on every sweep forever, and its failures crowd out the
// keys that would answer.
func (s *Store) DeferAttestRedemption(keyID string, until, now time.Time) error {
	const q = `UPDATE attest_keys SET risk_checked_at = ?, risk_not_before = ? WHERE key_id = ?`
	_, err := s.db.Exec(q, now.UnixMilli(), until.UnixMilli(), keyID)
	return err
}

// GetAttestRisk reads back a recorded assessment.
func (s *Store) GetAttestRisk(keyID string) (*AttestRisk, error) {
	const q = `SELECT risk_metric, risk_checked_at, risk_not_before FROM attest_keys WHERE key_id = ?`
	var metric, checked, notBefore sql.NullInt64
	err := s.db.QueryRow(q, keyID).Scan(&metric, &checked, &notBefore)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r := &AttestRisk{Metric: int(metric.Int64), HasMetric: metric.Valid}
	if checked.Valid {
		r.CheckedAt = time.UnixMilli(checked.Int64).UTC()
	}
	if notBefore.Valid {
		r.NotBefore = time.UnixMilli(notBefore.Int64).UTC()
	}
	return r, nil
}

// CountAttestKeyTenants reports how many distinct tenants hold live bindings
// under one attest key. One key legitimately covers several tokens for one
// device across a household rebuild; the same key spread across many tenants is
// the signature of a hooked device walking one key between victims.
func (s *Store) CountAttestKeyTenants(keyID string, now time.Time) (int, error) {
	const q = `SELECT COUNT(DISTINCT tenant) FROM bindings
	            WHERE attest_key_id = ? AND released_at IS NULL AND lease_expiry > ?`
	var n int
	err := s.db.QueryRow(q, keyID, now.UnixMilli()).Scan(&n)
	return n, err
}

// --- operator maintenance ---

// PrunableTenant is a tenant that holds no bindings at all.
type PrunableTenant struct {
	ID        string
	CreatedAt time.Time
	LastSeen  time.Time
}

// TenantsWithoutBindings returns tenants that have never held a binding and were created before
// `before`.
//
// The age bound is a MINIMUM age, and that direction is the whole point. Cleaning up test tenants
// by hand once, the filter used was "no bindings AND created recently" — which is exactly backwards:
// a brand-new tenant with no bindings is most likely a real user who enrolled a minute ago and has
// not opened the app yet. That deletion left a real deployment holding credentials this database no
// longer recognised. An old tenant with no bindings is the one that is safe to assume is junk.
//
// Bindings are checked with NOT EXISTS rather than a count, so a tenant that ever bound anything —
// released or expired — is never a candidate.
func (s *Store) TenantsWithoutBindings(before time.Time) ([]PrunableTenant, error) {
	const q = `SELECT id, created_at, last_seen FROM tenants t
	            WHERE t.created_at < ?
	              AND NOT EXISTS (SELECT 1 FROM bindings b WHERE b.tenant = t.id)
	         ORDER BY t.created_at`
	rows, err := s.db.Query(q, before.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []PrunableTenant
	for rows.Next() {
		var t PrunableTenant
		var created, seen int64
		if err := rows.Scan(&t.ID, &created, &seen); err != nil {
			return nil, err
		}
		t.CreatedAt = time.UnixMilli(created).UTC()
		t.LastSeen = time.UnixMilli(seen).UTC()
		out = append(out, t)
	}
	return out, rows.Err()
}

// DeleteTenant removes a tenant, and refuses if it holds any binding.
//
// The refusal is in the SQL rather than in the caller: a check the caller performs is a check a
// future caller can forget, and what it guards here is somebody's push stopping for good.
func (s *Store) DeleteTenant(id string) (bool, error) {
	const q = `DELETE FROM tenants
	            WHERE id = ?
	              AND NOT EXISTS (SELECT 1 FROM bindings b WHERE b.tenant = tenants.id)`
	res, err := s.db.Exec(q, id)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}
