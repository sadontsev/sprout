// Package tenant enrolls and authenticates the self-hosted Trellis instances
// that talk to Canopy.
//
// A tenant is a delivery agent, not an owner: it is the party allowed to push to
// a token, but ownership of that token rests on the device's keypairs. Losing a
// tenant credential therefore costs a user their push until they re-enroll — it
// never costs them their bindings, provided they can prove the same tenant
// identity, which is what the recovery code is for.
package tenant

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	"github.com/mvks5/canopy/internal/hashing"
	"github.com/mvks5/canopy/internal/store"
)

var (
	// ErrInviteRequired is returned when enrollment is gated and the caller
	// supplied no valid invite code.
	ErrInviteRequired = errors.New("tenant: an invite code is required")
	// ErrUnknownRecovery is returned for a recovery code matching no tenant.
	ErrUnknownRecovery = errors.New("tenant: unknown recovery code")
	// ErrFull is returned when the deployment's tenant cap is reached.
	ErrFull = errors.New("tenant: enrollment is at capacity")
	// ErrUnauthenticated is returned for a missing or wrong bearer credential.
	ErrUnauthenticated = errors.New("tenant: unauthenticated")
)

// DefaultMaxTenants bounds how many tenants a deployment will enroll.
const DefaultMaxTenants = 10000

// Service enrolls and authenticates tenants.
type Service struct {
	Store *store.Store
	// InviteCode, when non-empty, is required to enroll.
	InviteCode string
	// MaxTenants caps enrollment; zero means DefaultMaxTenants.
	MaxTenants int
}

// Credentials are handed to a Trellis once, at enrollment.
type Credentials struct {
	ID     string
	Secret string
	// Recovery restores this same tenant identity after the data volume is
	// lost. Canopy stores only its digest and shows it once; without it, a
	// rebuilt server enrolls as a *new* tenant and its user's existing
	// bindings can only be recovered by resetting pairing from the app.
	Recovery string
}

// Bearer is the Authorization value a tenant presents.
func (c Credentials) Bearer() string { return c.ID + "." + c.Secret }

// Enroll creates a tenant, or — when recoveryCode matches an existing one —
// re-adopts that identity with a fresh secret.
func (s *Service) Enroll(inviteCode, recoveryCode string, now time.Time) (Credentials, error) {
	// The invite gates NEW tenants, not the return of an existing one.
	//
	// It ran first, unconditionally, so a user whose data volume was lost needed the operator to
	// hand out an invite before their recovery code would work — which is precisely the situation
	// the recovery code exists to let them handle alone. The gate answers "may a stranger create a
	// tenant here?"; a recovery code answers "am I already one?", and only the first is what an
	// invite is for.
	//
	// Safe because the recovery code IS the credential: it is 32 random bytes, single-use, and
	// rotated on redemption, so anyone holding one already owns that tenant and gains nothing by
	// skipping the invite. Enrolment is rate-limited per IP besides. An unknown code still fails —
	// this widens nothing except the door back in for someone who was already inside.
	if recoveryCode == "" && s.InviteCode != "" &&
		!hashing.Equal(hashing.Digest(inviteCode), hashing.Digest(s.InviteCode)) {
		return Credentials{}, ErrInviteRequired
	}

	secret, err := randomToken()
	if err != nil {
		return Credentials{}, err
	}
	recovery, err := randomToken()
	if err != nil {
		return Credentials{}, err
	}

	if recoveryCode != "" {
		id, err := s.Store.TenantByRecovery(hashing.Digest(recoveryCode))
		if err != nil {
			return Credentials{}, err
		}
		if id == "" {
			return Credentials{}, ErrUnknownRecovery
		}
		// The recovery code is single use: it is replaced along with the
		// secret, so a leaked one cannot be redeemed twice.
		if err := s.Store.RotateTenantSecret(id, hashing.Digest(secret), hashing.Digest(recovery), now); err != nil {
			return Credentials{}, err
		}
		return Credentials{ID: id, Secret: secret, Recovery: recovery}, nil
	}

	max := s.MaxTenants
	if max == 0 {
		max = DefaultMaxTenants
	}
	n, err := s.Store.CountTenants()
	if err != nil {
		return Credentials{}, err
	}
	if n >= max {
		return Credentials{}, ErrFull
	}

	id, err := randomToken()
	if err != nil {
		return Credentials{}, err
	}
	if err := s.Store.PutTenant(id, hashing.Digest(secret), hashing.Digest(recovery), now); err != nil {
		return Credentials{}, err
	}
	return Credentials{ID: id, Secret: secret, Recovery: recovery}, nil
}

// Authenticate resolves an Authorization header value to a tenant id.
func (s *Service) Authenticate(authorization string) (string, error) {
	const prefix = "Bearer "
	if len(authorization) <= len(prefix) || !strings.EqualFold(authorization[:len(prefix)], prefix) {
		return "", ErrUnauthenticated
	}
	id, secret, ok := strings.Cut(authorization[len(prefix):], ".")
	if !ok || id == "" || secret == "" {
		return "", ErrUnauthenticated
	}

	stored, err := s.Store.TenantSecretHash(id)
	if err != nil {
		return "", err
	}
	if stored == "" || !hashing.Equal(stored, hashing.Digest(secret)) {
		return "", ErrUnauthenticated
	}
	return id, nil
}

func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
