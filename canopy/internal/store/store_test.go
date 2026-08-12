package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/binding"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

func openTemp(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestPutAndGetBinding(t *testing.T) {
	s := openTemp(t)
	row := &binding.Row{
		TokenHash:             "tok-A",
		Kind:                  binding.KindDevice,
		Tenant:                "tenant-1",
		DeviceID:              "dev-1",
		PairingPublicKey:      "pair-1",
		AttestKeyID:           "attest-1",
		APNSEnvironment:       "production",
		LeaseExpiry:           t0.Add(binding.KindDevice.Lease()),
		LastSuccessfulClaimAt: t0,
		CreatedAt:             t0,
	}
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("PutBinding: %v", err)
	}

	got, err := s.GetBinding("tok-A")
	if err != nil {
		t.Fatalf("GetBinding: %v", err)
	}
	if got == nil {
		t.Fatal("GetBinding returned nil for a row that was just written")
	}
	if got.Tenant != "tenant-1" || got.PairingPublicKey != "pair-1" || got.Kind != binding.KindDevice {
		t.Errorf("round-trip mismatch: %+v", got)
	}
	if !got.LeaseExpiry.Equal(row.LeaseExpiry) {
		t.Errorf("LeaseExpiry = %v, want %v", got.LeaseExpiry, row.LeaseExpiry)
	}
	if got.ReleasedAt != nil {
		t.Error("ReleasedAt should round-trip as nil")
	}
}

func TestGetBindingMissingReturnsNilNotError(t *testing.T) {
	s := openTemp(t)
	got, err := s.GetBinding("nope")
	if err != nil {
		t.Fatalf("GetBinding on a missing token must not error: %v", err)
	}
	if got != nil {
		t.Fatal("want nil row for an unseen token — nil is how Decide learns the token is UNSEEN")
	}
}

func TestPutBindingUpserts(t *testing.T) {
	s := openTemp(t)
	row := &binding.Row{
		TokenHash: "tok-A", Kind: binding.KindDevice, Tenant: "tenant-1",
		DeviceID: "dev-1", PairingPublicKey: "pair-1", AttestKeyID: "attest-1",
		APNSEnvironment: "production", LeaseExpiry: t0.Add(time.Hour), CreatedAt: t0,
	}
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("first PutBinding: %v", err)
	}
	row.Tenant = "tenant-2"
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("second PutBinding: %v", err)
	}
	got, _ := s.GetBinding("tok-A")
	if got.Tenant != "tenant-2" {
		t.Errorf("Tenant = %q, want tenant-2 — PutBinding must upsert", got.Tenant)
	}
}

func TestReleasedAtRoundTrips(t *testing.T) {
	s := openTemp(t)
	released := t0.Add(time.Minute)
	row := &binding.Row{
		TokenHash: "tok-A", Kind: binding.KindDevice, Tenant: "tenant-1",
		DeviceID: "dev-1", PairingPublicKey: "pair-1", AttestKeyID: "attest-1",
		APNSEnvironment: "production", LeaseExpiry: t0.Add(time.Hour),
		ReleasedAt: &released, CreatedAt: t0,
	}
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("PutBinding: %v", err)
	}
	got, _ := s.GetBinding("tok-A")
	if got.ReleasedAt == nil || !got.ReleasedAt.Equal(released) {
		t.Errorf("ReleasedAt = %v, want %v", got.ReleasedAt, released)
	}
}

func TestLiveCountExcludesReleasedAndExpired(t *testing.T) {
	s := openTemp(t)
	released := t0
	rows := []*binding.Row{
		{TokenHash: "live", LeaseExpiry: t0.Add(time.Hour)},
		{TokenHash: "expired", LeaseExpiry: t0.Add(-time.Hour)},
		{TokenHash: "released", LeaseExpiry: t0.Add(time.Hour), ReleasedAt: &released},
	}
	for _, r := range rows {
		r.Kind = binding.KindDevice
		r.Tenant = "tenant-1"
		r.DeviceID = "dev-1"
		r.PairingPublicKey = "pair-1"
		r.AttestKeyID = "attest-1"
		r.APNSEnvironment = "production"
		r.CreatedAt = t0
		if err := s.PutBinding(r); err != nil {
			t.Fatalf("PutBinding(%s): %v", r.TokenHash, err)
		}
	}
	n, err := s.LiveCount("tenant-1", t0)
	if err != nil {
		t.Fatalf("LiveCount: %v", err)
	}
	if n != 1 {
		t.Errorf("LiveCount = %d, want 1 — only unreleased rows inside their lease count against the cap", n)
	}
}
