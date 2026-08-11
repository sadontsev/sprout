package fraud

import (
	"context"
	"errors"
	"log/slog"
	"time"
)

// Keys is the slice of the store the sweep needs. An interface rather than the concrete store so
// the sweep's decisions — which keys, how often, what to do with each outcome — are testable
// without SQLite, which is where the interesting rules actually live.
type Keys interface {
	AttestKeysDueForRedemption(now time.Time, limit int) ([]KeyRecord, error)
	PutAttestRisk(keyID string, metric int, hasMetric bool, receipt []byte, notBefore, now time.Time) error
	DeferAttestRedemption(keyID string, until, now time.Time) error
}

// KeyRecord is what the sweep needs to know about one attested key.
type KeyRecord struct {
	KeyID       string
	Environment string
	Receipt     []byte
}

// Backoff after a redemption that produced no answer.
//
// A receipt Apple will not read is usually permanently unreadable — a receipt for a key from
// another team, or one whose environment was recorded wrong — so retrying it hourly buys nothing
// and crowds out keys that would answer. A day is long enough to be harmless and short enough that
// a configuration fix takes effect without an operator remembering this exists.
const (
	FailureBackoff  = 24 * time.Hour
	ThrottleBackoff = 6 * time.Hour
	// DefaultBatch bounds one pass. Redemption is one round trip per key against a credential the
	// operator shares with everything else that uses this DeviceCheck key.
	DefaultBatch = 50
)

// Sweeper redeems receipts and reports what it learns.
type Sweeper struct {
	Keys   Keys
	Client *Client
	Log    *slog.Logger
	// AppID is the app these receipts must belong to, as team.bundle. A receipt from another app
	// would parse and yield a number that means nothing here.
	AppID string
	// Alert is called for each device that crosses the threshold. Separate from logging because an
	// operator who wanted to be told will not be reading logs.
	Alert func(keyID string, a Assessment)
	Batch int
}

// Result summarises one pass, for the caller to log or test against.
type Result struct {
	Considered int
	Redeemed   int
	Suspicious int
	Deferred   int
}

// Run redeems every receipt currently due.
//
// It never returns an error for an individual key: one unreadable receipt must not stop the pass,
// because the keys that would answer are the point. Only a failure to read the due list at all is
// fatal to the pass.
func (s *Sweeper) Run(ctx context.Context, now time.Time) (Result, error) {
	var res Result
	if s.Client == nil {
		// Not configured. Not an error, and deliberately not logged at error level: this is the
		// state of every deployment that has not supplied a DeviceCheck key, which is a
		// supported way to run Canopy.
		return res, nil
	}

	batch := s.Batch
	if batch <= 0 {
		batch = DefaultBatch
	}
	due, err := s.Keys.AttestKeysDueForRedemption(now, batch)
	if err != nil {
		return res, err
	}
	res.Considered = len(due)

	for _, k := range due {
		if err := ctx.Err(); err != nil {
			return res, err
		}
		ok, err := s.redeemOne(ctx, k, now, &res)
		if errors.Is(err, ErrUnauthorized) {
			// Not this receipt's fault, and not the next forty-nine's either: Apple checks the
			// token before it reads the receipt, so every remaining key would fail identically.
			// Stop the pass, say so once, and leave every key DUE — deferring them would turn a
			// misconfigured key into a day of silence in which nothing looks wrong.
			s.log().Error("fraud: Apple rejected the DeviceCheck token, so no receipt could be "+
				"assessed; a newly created key can take up to 24h to propagate, otherwise check "+
				"it has the DeviceCheck service enabled", "key_id", k.KeyID, "err", err)
			return res, err
		}
		if ok {
			res.Redeemed++
		} else {
			res.Deferred++
		}
	}
	return res, nil
}

// redeemOne handles a single key. It reports whether an assessment was produced, and returns the
// error only when it is one the whole pass must react to.
func (s *Sweeper) redeemOne(ctx context.Context, k KeyRecord, now time.Time, res *Result) (bool, error) {
	// The environment travels with the key, so the client sends each receipt to the host matching
	// where it was attested. Canopy's own environment is a different question and must not be
	// substituted here.
	a, err := s.Client.Redeem(ctx, k.Receipt, k.Environment, now)
	switch {
	case err == nil:
	case errors.Is(err, ErrUnauthorized):
		// Deliberately no defer_: the receipt is fine, the credential is not.
		return false, err
	case errors.Is(err, ErrThrottled):
		s.defer_(k.KeyID, now.Add(ThrottleBackoff), now)
		return false, nil
	default:
		s.log().Warn("fraud: redemption failed",
			"key_id", k.KeyID, "environment", k.Environment, "err", err)
		s.defer_(k.KeyID, now.Add(FailureBackoff), now)
		return false, nil
	}

	if s.AppID != "" && a.AppID != "" && a.AppID != s.AppID {
		// A receipt for another app parses cleanly and yields a number that means nothing about
		// this one. Recording it would attribute a stranger's key count to this device.
		s.log().Warn("fraud: receipt belongs to another app",
			"key_id", k.KeyID, "receipt_app_id", a.AppID, "want", s.AppID)
		s.defer_(k.KeyID, now.Add(FailureBackoff), now)
		return false, nil
	}

	// Apple states when it will next accept this receipt. Falling back to a fixed interval when it
	// does not would guarantee a 429 on the next pass.
	next := a.NotBefore
	if next.IsZero() || !next.After(now) {
		next = now.Add(ThrottleBackoff)
	}
	if err := s.Keys.PutAttestRisk(k.KeyID, a.Keys, a.HasKeys, a.Receipt, next, now); err != nil {
		s.log().Error("fraud: recording assessment", "key_id", k.KeyID, "err", err)
		return false, nil
	}

	if a.Suspicious() {
		res.Suspicious++
		s.log().Warn("fraud: device has attested an unusual number of keys",
			"key_id", k.KeyID, "keys", a.Keys, "threshold", SuspiciousKeyCount)
		if s.Alert != nil {
			s.Alert(k.KeyID, a)
		}
	}
	return true, nil
}

func (s *Sweeper) defer_(keyID string, until, now time.Time) {
	if err := s.Keys.DeferAttestRedemption(keyID, until, now); err != nil {
		s.log().Error("fraud: deferring redemption", "key_id", keyID, "err", err)
	}
}

func (s *Sweeper) log() *slog.Logger {
	if s.Log != nil {
		return s.Log
	}
	return slog.Default()
}
