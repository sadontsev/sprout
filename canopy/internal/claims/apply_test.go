package claims

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/binding"
	"github.com/sadontsev/sprout/canopy/internal/store"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

func openTemp(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func deviceClaim() binding.Claim {
	return binding.Claim{
		TokenHash: "tok-A", Kind: binding.KindDevice, Tenant: "tenant-1",
		DeviceID: "dev-1", AttestKeyID: "attest-1", PairingPublicKey: "pair-1",
		APNSEnvironment:  "production",
		AttestProofValid: true, PairingSigValid: true, VouchOK: true,
	}
}

func TestApplyBindsThenRecognises(t *testing.T) {
	s := openTemp(t)

	first, err := Apply(s, deviceClaim(), t0)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if !first.Accepted || first.Rule != binding.RuleR0 {
		t.Fatalf("first claim: rule %q accepted %v, want R0 accepted", first.Rule, first.Accepted)
	}

	second, err := Apply(s, deviceClaim(), t0.Add(time.Hour))
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if !second.Accepted || second.Rule != binding.RuleR1 {
		t.Fatalf("second claim: rule %q accepted %v, want R1 accepted", second.Rule, second.Accepted)
	}
}

func TestApplyPersistsTheVouchRequirementAcrossCalls(t *testing.T) {
	s := openTemp(t)
	c := deviceClaim()
	c.VouchOK = false

	got, err := Apply(s, c, t0)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if got.Accepted {
		t.Fatal("an unseen device token without a vouch must not bind")
	}
	if got.Reason != binding.ReasonVouchRequired {
		t.Errorf("Reason = %q, want vouch_required", got.Reason)
	}
	if row, _ := s.GetBinding("tok-A"); row != nil {
		t.Fatal("a refused claim must not write a binding")
	}
}

func TestApplyStampsFailedClaimWithoutAdvancingDormancy(t *testing.T) {
	s := openTemp(t)
	if _, err := Apply(s, deviceClaim(), t0); err != nil {
		t.Fatalf("seed: %v", err)
	}

	bad := deviceClaim()
	bad.PairingPublicKey = "pair-attacker"
	bad.AttestKeyID = "attest-attacker"
	later := t0.Add(80 * 24 * time.Hour)
	got, err := Apply(s, bad, later)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if got.Accepted {
		t.Fatal("expected refusal")
	}

	row, _ := s.GetBinding("tok-A")
	if !row.LastFailedClaimAt.Equal(later) {
		t.Errorf("LastFailedClaimAt = %v, want %v", row.LastFailedClaimAt, later)
	}
	if !row.LastSuccessfulClaimAt.Equal(t0) {
		t.Error("a refused claim must not advance the successful-claim clock")
	}
	if !row.IsDormant(t0.Add(91 * 24 * time.Hour)) {
		t.Error("a row hammered by refused claims must still become dormant on schedule")
	}
	if row.Tenant != "tenant-1" {
		t.Errorf("Tenant = %q — a refused claim must not re-point the tenant", row.Tenant)
	}
}
