// Package keystore makes App Attest verification stateful.
//
// internal/appattest is pure — it takes a public key and a counter as arguments
// so the procedure can be tested exhaustively without a database. This package
// is the thin layer that remembers: it persists a key at attestation, looks it
// up for an assertion, and advances the counter. It adds no cryptography.
package keystore

import (
	"crypto/ecdsa"
	"errors"
	"sync"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/appattest"
	"github.com/sadontsev/sprout/canopy/internal/pairing"
	"github.com/sadontsev/sprout/canopy/internal/store"
)

// ErrReattestRequired means Canopy holds no public key for this key id, so an
// assertion cannot be checked. It is distinct from a rejection: the honest cause
// is a Canopy restore that predates the key, and the app's answer is to generate
// a new App Attest key and send an attestation. Reporting it as "invalid" would
// leave a whole install permanently unable to claim.
var ErrReattestRequired = errors.New("keystore: no attested key on file")

// ErrKeyTenantLimit means one attest key holds live bindings across too many
// tenants — the shape of a hooked device walking one key between victims.
var ErrKeyTenantLimit = errors.New("keystore: attest key spans too many tenants")

// MaxTenantsPerKey bounds how many tenants may hold live bindings under a single
// attest key. Three covers a household rebuild with room to spare.
const MaxTenantsPerKey = 3

// Service verifies proofs and remembers the keys they establish.
type Service struct {
	Store    *store.Store
	Verifier *appattest.Verifier

	// Serialises verify-and-bump PER KEY.
	//
	// VerifyAssertion is a read-modify-write: it reads the stored counter, checks
	// the assertion against it, then persists the new one. Two requests carrying
	// the same key interleaved there both read the old counter, both verified
	// against it, and both wrote — so the higher counter could be overwritten by
	// the lower and a replay of an already-spent assertion would then pass. The
	// window is small and entirely reachable: the app registers three token kinds
	// around the same moment, and a client that retries on timeout doubles every
	// request.
	//
	// Per key rather than one global lock: two phones share nothing here, and a
	// slow verification for one must not stall every other tenant's claim.
	mu    sync.Mutex
	locks map[string]*sync.Mutex
}

// keyLock returns the mutex guarding one key id, creating it on first use.
func (s *Service) keyLock(keyID string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.locks == nil {
		s.locks = make(map[string]*sync.Mutex)
	}
	l, ok := s.locks[keyID]
	if !ok {
		l = &sync.Mutex{}
		s.locks[keyID] = l
	}
	return l
}

// VerifyAttestation checks a first-use attestation and persists the key,
// counter, environment and receipt it establishes.
func (s *Service) VerifyAttestation(attestation []byte, keyID string, clientData []byte, now time.Time) error {
	attested, err := s.Verifier.VerifyAttestation(attestation, keyID, clientData, now)
	if err != nil {
		return err
	}
	return s.Store.PutAttestKey(store.AttestKey{
		KeyID:       keyID,
		PublicKey:   pairing.EncodePublicKey(attested.PublicKey),
		Counter:     attested.Counter,
		Environment: string(attested.Environment),
		Receipt:     attested.Receipt,
	}, now)
}

// VerifyAssertion checks a later assertion against the stored key and advances
// the counter.
func (s *Service) VerifyAssertion(assertion []byte, keyID string, clientData []byte, now time.Time) error {
	// Held across the whole read-check-write. See `locks`.
	l := s.keyLock(keyID)
	l.Lock()
	defer l.Unlock()

	rec, err := s.Store.GetAttestKey(keyID)
	if err != nil {
		return err
	}
	if rec == nil {
		return ErrReattestRequired
	}
	pub, err := pairing.ParsePublicKey(rec.PublicKey)
	if err != nil {
		return err
	}

	n, err := s.Store.CountAttestKeyTenants(keyID, now)
	if err != nil {
		return err
	}
	if n > MaxTenantsPerKey {
		return ErrKeyTenantLimit
	}

	counter, err := s.Verifier.VerifyAssertion(assertion, pub, rec.Counter, clientData)
	if err != nil {
		return err
	}
	return s.Store.BumpAttestCounter(keyID, counter, now)
}

// PublicKeyFor exposes the stored key, for callers that need it directly.
func (s *Service) PublicKeyFor(keyID string) (*ecdsa.PublicKey, error) {
	rec, err := s.Store.GetAttestKey(keyID)
	if err != nil {
		return nil, err
	}
	if rec == nil {
		return nil, ErrReattestRequired
	}
	return pairing.ParsePublicKey(rec.PublicKey)
}
