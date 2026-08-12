// Package vouch proves that whoever is claiming a device token actually
// receives pushes on it.
//
// Canopy cannot ask Apple which device a token belongs to. It can ask the token:
// a silent push carrying a random nonce, echoed back inside the next claim's
// signed client data. An attacker holding a stolen token *value* — from logs, a
// LAN sniff, a stale backup — receives nothing and cannot answer.
//
// Only device tokens can be vouched. Push-to-start and per-activity tokens
// accept no silent push, so their values remain first-come; that is a stated
// residual of the design, not an omission here.
package vouch

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/apns"
	"github.com/sadontsev/sprout/canopy/internal/hashing"
	"github.com/sadontsev/sprout/canopy/internal/store"
)

const (
	// TTL is how long a minted nonce stays usable.
	TTL = 10 * time.Minute
	// NonceBytes is the size of the random nonce.
	NonceBytes = 32
	// MaxPerTokenPerHour caps how often *anyone* may cause a silent push to one
	// token. The cap is global rather than per tenant on purpose: a per-tenant
	// limit is defeated by enrolling more tenants, and what that buys an
	// attacker is waking a known victim's app at will.
	MaxPerTokenPerHour = 6
	// RateWindow is the window MaxPerTokenPerHour applies over.
	RateWindow = time.Hour
)

// ErrRateLimited is returned when a token has been vouched too often.
var ErrRateLimited = errors.New("vouch: token has been vouched too recently")

// Sender is the subset of the APNs client this package needs.
type Sender interface {
	Send(ctx context.Context, p apns.Push, now time.Time) (apns.Result, apns.Environment)
}

// Service mints and verifies vouches.
type Service struct {
	Store *store.Store
	APNs  Sender
}

// Mint generates a nonce, records its digest against (token, tenant), and sends
// it to the token as a silent push.
//
// The APNs outcome is deliberately not returned. The caller answers 202
// regardless, so this endpoint cannot be used to distinguish a live token from a
// dead one — it is the one endpoint that pushes to a token nobody has yet proven
// they own.
func (s *Service) Mint(ctx context.Context, rawToken, tenant string, env apns.Environment, now time.Time) error {
	tokenHash := hashing.Digest(rawToken)

	n, err := s.Store.CountVouchesSince(tokenHash, now.Add(-RateWindow))
	if err != nil {
		return err
	}
	if n >= MaxPerTokenPerHour {
		return ErrRateLimited
	}

	raw := make([]byte, NonceBytes)
	if _, err := rand.Read(raw); err != nil {
		return err
	}
	nonce := base64.RawURLEncoding.EncodeToString(raw)

	if err := s.Store.PutVouch(tokenHash, hashing.Digest(nonce), tenant, now.Add(TTL), now); err != nil {
		return err
	}

	payload, err := json.Marshal(map[string]any{
		"aps":         map[string]any{"content-available": 1},
		"vouch_nonce": nonce,
	})
	if err != nil {
		return err
	}

	// Fire and ignore: a delivery failure must not leak back to the caller, and
	// the nonce simply expires unused if the push never lands.
	s.APNs.Send(ctx, apns.Push{
		Token:       rawToken,
		Environment: env,
		Type:        apns.Background,
		Priority:    5,
		Payload:     payload,
	}, now)

	return nil
}

// Verify consumes the vouch for (token, nonce, tenant), reporting whether one
// was outstanding. It is single-use: a replayable nonce would prove reachability
// once and authorise binding forever.
func (s *Service) Verify(rawToken, nonce, tenant string, now time.Time) (bool, error) {
	if nonce == "" {
		return false, nil
	}
	return s.Store.ConsumeVouch(hashing.Digest(rawToken), hashing.Digest(nonce), tenant, now)
}
