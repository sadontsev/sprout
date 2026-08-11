package challenge

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/mvks5/canopy/internal/store"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

func newService(t *testing.T) *Service {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return &Service{Store: s}
}

func TestIssueThenConsume(t *testing.T) {
	svc := newService(t)

	got, err := svc.Issue("tenant-1", Assertion, t0)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if got.Challenge == "" {
		t.Fatal("Issue returned an empty challenge")
	}
	if !got.ExpiresAt.Equal(t0.Add(Assertion.TTL())) {
		t.Errorf("ExpiresAt = %v, want %v", got.ExpiresAt, t0.Add(Assertion.TTL()))
	}

	ok, err := svc.Consume(got.Challenge, "tenant-1", Assertion, t0.Add(time.Second))
	if err != nil {
		t.Fatalf("Consume: %v", err)
	}
	if !ok {
		t.Fatal("a freshly issued challenge must consume")
	}
}

func TestChallengeIsSingleUse(t *testing.T) {
	svc := newService(t)
	c, _ := svc.Issue("tenant-1", Assertion, t0)

	if ok, _ := svc.Consume(c.Challenge, "tenant-1", Assertion, t0); !ok {
		t.Fatal("first use must succeed")
	}
	if ok, _ := svc.Consume(c.Challenge, "tenant-1", Assertion, t0); ok {
		t.Fatal("a challenge must not be spendable twice")
	}
}

func TestChallengeIsBoundToItsTenant(t *testing.T) {
	svc := newService(t)
	c, _ := svc.Issue("tenant-1", Assertion, t0)

	if ok, _ := svc.Consume(c.Challenge, "tenant-2", Assertion, t0); ok {
		t.Fatal("a challenge issued to one tenant must not be spendable by another: " +
			"every accepting binding rule re-points the tenant, so a cross-tenant " +
			"replay is a takeover, not a duplicate")
	}
	// The rightful tenant can still spend it — a failed attempt consumes nothing.
	if ok, _ := svc.Consume(c.Challenge, "tenant-1", Assertion, t0); !ok {
		t.Error("a cross-tenant attempt must not consume the challenge")
	}
}

func TestChallengeIsBoundToItsPurpose(t *testing.T) {
	svc := newService(t)
	c, _ := svc.Issue("tenant-1", Attestation, t0)

	if ok, _ := svc.Consume(c.Challenge, "tenant-1", Assertion, t0); ok {
		t.Fatal("an attestation challenge must not satisfy an assertion: its TTL is " +
			"7.5x longer, so allowing it would stretch the assertion replay window")
	}
	if ok, _ := svc.Consume(c.Challenge, "tenant-1", Attestation, t0); !ok {
		t.Error("a wrong-purpose attempt must not consume the challenge")
	}
}

func TestChallengeExpires(t *testing.T) {
	svc := newService(t)

	assertion, _ := svc.Issue("tenant-1", Assertion, t0)
	if ok, _ := svc.Consume(assertion.Challenge, "tenant-1", Assertion, t0.Add(Assertion.TTL()+time.Second)); ok {
		t.Error("an expired assertion challenge must not consume")
	}

	att, _ := svc.Issue("tenant-1", Attestation, t0)
	if ok, _ := svc.Consume(att.Challenge, "tenant-1", Attestation, t0.Add(10*time.Minute)); !ok {
		t.Error("an attestation challenge must still be valid at 10 minutes: Apple asks " +
			"that serverUnavailable retries reuse identical inputs")
	}
}

func TestPurposeTTLs(t *testing.T) {
	if Attestation.TTL() != 15*time.Minute {
		t.Errorf("attestation TTL = %v, want 15m", Attestation.TTL())
	}
	if Assertion.TTL() != 120*time.Second {
		t.Errorf("assertion TTL = %v, want 120s", Assertion.TTL())
	}
	if Attestation.TTL() <= Assertion.TTL() {
		t.Error("the attestation window is deliberately the longer of the two")
	}
}

func TestUnknownPurposeIsRejected(t *testing.T) {
	svc := newService(t)

	if _, err := svc.Issue("tenant-1", Purpose("whatever"), t0); !errors.Is(err, ErrBadPurpose) {
		t.Errorf("Issue err = %v, want ErrBadPurpose", err)
	}
	if ok, _ := svc.Consume("anything", "tenant-1", Purpose("whatever"), t0); ok {
		t.Error("an unknown purpose must never consume")
	}
}

func TestEmptyChallengeNeverConsumes(t *testing.T) {
	svc := newService(t)
	if ok, _ := svc.Consume("", "tenant-1", Assertion, t0); ok {
		t.Error("an absent challenge must not consume")
	}
}

func TestPurgeExpiredChallenges(t *testing.T) {
	svc := newService(t)
	c, _ := svc.Issue("tenant-1", Assertion, t0)

	if err := svc.Store.PurgeExpiredChallenges(t0.Add(Assertion.TTL() + time.Second)); err != nil {
		t.Fatalf("PurgeExpiredChallenges: %v", err)
	}
	if ok, _ := svc.Consume(c.Challenge, "tenant-1", Assertion, t0); ok {
		t.Error("a purged challenge must be gone")
	}
}
