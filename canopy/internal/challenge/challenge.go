// Package challenge issues and consumes the single-use nonces a claim must sign
// over.
//
// Three properties are load-bearing, and the first two were absent from an
// earlier draft of the design where the columns existed and nothing read them:
//
//   - A challenge is bound to the tenant it was issued to. Without that check a
//     captured claim can be replayed under a *different* tenant, which is worse
//     than a verbatim replay because every accepting binding rule re-points the
//     tenant to the caller.
//   - A challenge is bound to its purpose. Attestation challenges live 15
//     minutes because Apple asks that attestation retries reuse identical
//     inputs; letting one satisfy an assertion would stretch the assertion
//     replay window by more than sevenfold.
//   - A challenge is consumed on *success*, not on presentation, so a client
//     following Apple's DCError.serverUnavailable guidance — retry with the same
//     key and the same client-data hash — still validates.
package challenge

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"time"

	"github.com/mvks5/canopy/internal/hashing"
	"github.com/mvks5/canopy/internal/store"
)

// Purpose is what a challenge may be spent on.
type Purpose string

const (
	// Attestation is the first claim from a new App Attest key.
	Attestation Purpose = "attestation"
	// Assertion is every later claim.
	Assertion Purpose = "assertion"
)

// TTL is how long a challenge of this purpose remains spendable.
func (p Purpose) TTL() time.Duration {
	if p == Attestation {
		return 15 * time.Minute
	}
	return 120 * time.Second
}

// Valid reports whether p is a purpose this service issues.
func (p Purpose) Valid() bool { return p == Attestation || p == Assertion }

// ErrBadPurpose is returned for an unrecognised purpose.
var ErrBadPurpose = errors.New("challenge: unknown purpose")

// Service issues and consumes challenges.
type Service struct{ Store *store.Store }

// Issued is a freshly minted challenge.
type Issued struct {
	Challenge string
	ExpiresAt time.Time
}

// Issue mints a challenge for tenant and purpose.
func (s *Service) Issue(tenant string, p Purpose, now time.Time) (Issued, error) {
	if !p.Valid() {
		return Issued{}, ErrBadPurpose
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return Issued{}, err
	}
	nonce := base64.RawURLEncoding.EncodeToString(b)
	expires := now.Add(p.TTL())

	if err := s.Store.PutChallenge(hashing.Digest(nonce), tenant, string(p), expires, now); err != nil {
		return Issued{}, err
	}
	return Issued{Challenge: nonce, ExpiresAt: expires}, nil
}

// Consume spends a challenge, reporting whether one matching all of the nonce,
// the tenant and the purpose was outstanding and unexpired.
func (s *Service) Consume(nonce, tenant string, p Purpose, now time.Time) (bool, error) {
	if nonce == "" || !p.Valid() {
		return false, nil
	}
	return s.Store.ConsumeChallenge(hashing.Digest(nonce), tenant, string(p), now)
}
