package tenant

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

func TestEnrollThenAuthenticate(t *testing.T) {
	svc := newService(t)

	c, err := svc.Enroll("", "", t0)
	if err != nil {
		t.Fatalf("Enroll: %v", err)
	}
	if c.ID == "" || c.Secret == "" || c.Recovery == "" {
		t.Fatalf("Enroll returned an incomplete credential: %+v", c)
	}

	id, err := svc.Authenticate("Bearer " + c.Bearer())
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if id != c.ID {
		t.Errorf("id = %q, want %q", id, c.ID)
	}
}

func TestAuthenticateRejectsBadCredentials(t *testing.T) {
	svc := newService(t)
	c, _ := svc.Enroll("", "", t0)

	bad := []string{
		"",
		"Bearer ",
		"Bearer no-dot",
		"Bearer " + c.ID + ".wrong-secret",
		"Bearer unknown-tenant." + c.Secret,
		c.Bearer(), // no scheme
	}
	for _, h := range bad {
		if _, err := svc.Authenticate(h); !errors.Is(err, ErrUnauthenticated) {
			t.Errorf("Authenticate(%q) = %v, want ErrUnauthenticated", h, err)
		}
	}
}

func TestEnrollIsGatedByInviteCodeWhenSet(t *testing.T) {
	svc := newService(t)
	svc.InviteCode = "let-me-in"

	if _, err := svc.Enroll("", "", t0); !errors.Is(err, ErrInviteRequired) {
		t.Errorf("err = %v, want ErrInviteRequired", err)
	}
	if _, err := svc.Enroll("wrong", "", t0); !errors.Is(err, ErrInviteRequired) {
		t.Errorf("err = %v, want ErrInviteRequired for a wrong code", err)
	}
	if _, err := svc.Enroll("let-me-in", "", t0); err != nil {
		t.Errorf("the right invite code must enroll: %v", err)
	}
}

func TestRecoveryCodeReadoptsTheSameTenant(t *testing.T) {
	svc := newService(t)
	first, _ := svc.Enroll("", "", t0)

	// The server is rebuilt: same user, new credential, and crucially the same
	// tenant identity, so the bindings it already holds stay reachable.
	second, err := svc.Enroll("", first.Recovery, t0.Add(time.Hour))
	if err != nil {
		t.Fatalf("recovery enroll: %v", err)
	}
	if second.ID != first.ID {
		t.Fatalf("id = %q, want the original %q — a recovery enroll must re-adopt, not create", second.ID, first.ID)
	}
	if second.Secret == first.Secret {
		t.Error("a recovery enroll must issue a fresh secret")
	}

	if _, err := svc.Authenticate("Bearer " + second.Bearer()); err != nil {
		t.Errorf("the new credential must authenticate: %v", err)
	}
	if _, err := svc.Authenticate("Bearer " + first.Bearer()); !errors.Is(err, ErrUnauthenticated) {
		t.Error("the superseded credential must stop working")
	}
}

func TestRecoveryCodeIsSingleUse(t *testing.T) {
	svc := newService(t)
	first, _ := svc.Enroll("", "", t0)

	if _, err := svc.Enroll("", first.Recovery, t0); err != nil {
		t.Fatalf("first redemption: %v", err)
	}
	if _, err := svc.Enroll("", first.Recovery, t0); !errors.Is(err, ErrUnknownRecovery) {
		t.Error("a redeemed recovery code must not work twice: it confers tenant identity")
	}
}

func TestUnknownRecoveryCodeIsRejected(t *testing.T) {
	svc := newService(t)
	svc.Enroll("", "", t0)

	if _, err := svc.Enroll("", "not-a-real-code", t0); !errors.Is(err, ErrUnknownRecovery) {
		t.Errorf("err = %v, want ErrUnknownRecovery", err)
	}
}

func TestEnrollmentIsCapped(t *testing.T) {
	svc := newService(t)
	svc.MaxTenants = 2

	for i := 0; i < 2; i++ {
		if _, err := svc.Enroll("", "", t0); err != nil {
			t.Fatalf("enroll %d: %v", i, err)
		}
	}
	if _, err := svc.Enroll("", "", t0); !errors.Is(err, ErrFull) {
		t.Errorf("err = %v, want ErrFull", err)
	}
}

func TestRecoveryEnrollIsNotBlockedByTheCap(t *testing.T) {
	svc := newService(t)
	svc.MaxTenants = 1

	first, err := svc.Enroll("", "", t0)
	if err != nil {
		t.Fatalf("Enroll: %v", err)
	}
	if _, err := svc.Enroll("", first.Recovery, t0); err != nil {
		t.Errorf("a recovery enroll re-adopts an existing tenant and must not be capped: %v", err)
	}
}

func TestSecretsAreNotStoredInTheClear(t *testing.T) {
	svc := newService(t)
	c, _ := svc.Enroll("", "", t0)

	stored, err := svc.Store.TenantSecretHash(c.ID)
	if err != nil {
		t.Fatalf("TenantSecretHash: %v", err)
	}
	if stored == c.Secret {
		t.Fatal("the tenant secret must be stored as a digest, never verbatim")
	}
	if stored == "" {
		t.Fatal("no digest was stored")
	}
}

func TestRecoveryWorksWithoutAnInvite(t *testing.T) {
	// The invite gates NEW tenants. Requiring it for recovery too meant a user whose data volume
	// was lost had to ask the operator for an invite before the recovery code they were told to
	// save would do anything — the exact situation it exists to let them handle alone.
	s := newService(t)
	s.InviteCode = "let-me-in"

	first, err := s.Enroll("let-me-in", "", t0)
	if err != nil {
		t.Fatalf("initial enroll: %v", err)
	}

	// Data volume lost; all that survives is the recovery code.
	back, err := s.Enroll("", first.Recovery, t0.Add(time.Hour))
	if err != nil {
		t.Fatalf("recovery without an invite: %v", err)
	}
	if back.ID != first.ID {
		t.Errorf("recovered id = %q, want the original %q", back.ID, first.ID)
	}
	if back.Secret == first.Secret {
		t.Error("the secret must rotate, or a leaked one stays valid")
	}
}

func TestANewTenantStillNeedsTheInvite(t *testing.T) {
	// The gate must not have been widened into nothing.
	s := newService(t)
	s.InviteCode = "let-me-in"

	if _, err := s.Enroll("", "", t0); !errors.Is(err, ErrInviteRequired) {
		t.Fatalf("err = %v, want ErrInviteRequired", err)
	}
	if _, err := s.Enroll("wrong", "", t0); !errors.Is(err, ErrInviteRequired) {
		t.Fatalf("err = %v, want ErrInviteRequired for a wrong code", err)
	}
}

func TestAnUnknownRecoveryCodeIsStillRefused(t *testing.T) {
	// Skipping the invite for recovery must not become a way in for someone holding nothing.
	s := newService(t)
	s.InviteCode = "let-me-in"

	_, err := s.Enroll("", "not-a-real-recovery-code", t0)
	if !errors.Is(err, ErrUnknownRecovery) {
		t.Fatalf("err = %v, want ErrUnknownRecovery", err)
	}
}
