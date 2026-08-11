package binding

import (
	"testing"
	"time"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

// validClaim is a well-formed device claim from a vouched token. Individual
// tests mutate one field, so every case reads as "this input, this rule".
func validClaim() Claim {
	return Claim{
		TokenHash:        "tok-A",
		Kind:             KindDevice,
		Tenant:           "tenant-1",
		DeviceID:         "dev-1",
		AttestKeyID:      "attest-1",
		PairingPublicKey: "pair-1",
		APNSEnvironment:  "production",
		AttestProofValid: true,
		PairingSigValid:  true,
		VouchOK:          true,
	}
}

func boundRow() *Row {
	return &Row{
		TokenHash:             "tok-A",
		Kind:                  KindDevice,
		Tenant:                "tenant-1",
		DeviceID:              "dev-1",
		AttestKeyID:           "attest-1",
		PairingPublicKey:      "pair-1",
		APNSEnvironment:       "production",
		LeaseExpiry:           t0.Add(KindDevice.Lease()),
		LastDeliveryAt:        t0,
		LastSuccessfulClaimAt: t0,
		CreatedAt:             t0,
	}
}

func TestDecide(t *testing.T) {
	released := t0
	cases := []struct {
		name     string
		claim    func(c *Claim)
		row      *Row
		wantRule Rule
		wantOK   bool
		wantWhy  Reason
	}{
		{
			name:     "unseen device token with a vouch binds",
			row:      nil,
			wantRule: RuleR0, wantOK: true,
		},
		{
			name:     "unseen device token without a vouch is refused",
			claim:    func(c *Claim) { c.VouchOK = false },
			row:      nil,
			wantRule: RuleR0, wantOK: false, wantWhy: ReasonVouchRequired,
		},
		{
			name:     "unseen start token binds without a vouch",
			claim:    func(c *Claim) { c.Kind = KindStart; c.VouchOK = false },
			row:      nil,
			wantRule: RuleR0, wantOK: true,
		},
		{
			name:     "matching pairing key takes R1",
			row:      boundRow(),
			wantRule: RuleR1, wantOK: true,
		},
		{
			name:     "R1 fires even when the attest key changed, because reinstall rotates it",
			claim:    func(c *Claim) { c.AttestKeyID = "attest-2" },
			row:      boundRow(),
			wantRule: RuleR1, wantOK: true,
		},
		{
			name:     "new pairing key with the row's attest key takes R2",
			claim:    func(c *Claim) { c.PairingPublicKey = "pair-2" },
			row:      boundRow(),
			wantRule: RuleR2, wantOK: true,
		},
		{
			name:     "neither anchor matches is refused",
			claim:    func(c *Claim) { c.PairingPublicKey = "pair-2"; c.AttestKeyID = "attest-2" },
			row:      boundRow(),
			wantRule: RuleR3, wantOK: false, wantWhy: ReasonPairingMismatch,
		},
		{
			name:     "a vouch is never required against an existing row",
			claim:    func(c *Claim) { c.VouchOK = false },
			row:      boundRow(),
			wantRule: RuleR1, wantOK: true,
		},
		{
			name: "an expired lease is still anchored, not first-claimable",
			claim: func(c *Claim) {
				c.PairingPublicKey = "pair-attacker"
				c.AttestKeyID = "attest-attacker"
				c.Tenant = "tenant-2"
			},
			row: func() *Row {
				r := boundRow()
				r.LeaseExpiry = t0.Add(-time.Hour)
				return r
			}(),
			wantRule: RuleR3, wantOK: false, wantWhy: ReasonPairingMismatch,
		},
		{
			name: "a released row is still anchored, not first-claimable",
			claim: func(c *Claim) {
				c.PairingPublicKey = "pair-attacker"
				c.AttestKeyID = "attest-attacker"
				c.Tenant = "tenant-2"
			},
			row: func() *Row {
				r := boundRow()
				r.ReleasedAt = &released
				return r
			}(),
			wantRule: RuleR3, wantOK: false, wantWhy: ReasonPairingMismatch,
		},
		{
			name:   "a kind that disagrees with the row is refused before the rules",
			claim:  func(c *Claim) { c.Kind = KindActivity },
			row:    boundRow(),
			wantOK: false, wantWhy: ReasonKindMismatch,
		},
		{
			name:   "an invalid attest proof never reaches the rules",
			claim:  func(c *Claim) { c.AttestProofValid = false },
			row:    boundRow(),
			wantOK: false, wantWhy: ReasonAttestationInvalid,
		},
		{
			name:   "an invalid pairing signature never reaches the rules",
			claim:  func(c *Claim) { c.PairingSigValid = false },
			row:    boundRow(),
			wantOK: false, wantWhy: ReasonPairingSignatureInvalid,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := validClaim()
			if tc.claim != nil {
				tc.claim(&c)
			}
			got := Decide(c, tc.row, t0)
			if got.Accepted != tc.wantOK {
				t.Fatalf("Accepted = %v, want %v (reason %q)", got.Accepted, tc.wantOK, got.Reason)
			}
			if tc.wantRule != "" && got.Rule != tc.wantRule {
				t.Errorf("Rule = %q, want %q", got.Rule, tc.wantRule)
			}
			if got.Reason != tc.wantWhy {
				t.Errorf("Reason = %q, want %q", got.Reason, tc.wantWhy)
			}
		})
	}
}

func TestAcceptedDecisionAlwaysRepointsAndRenews(t *testing.T) {
	released := t0.Add(-time.Hour)
	row := boundRow()
	row.ReleasedAt = &released
	row.LeaseExpiry = t0.Add(-time.Hour)

	c := validClaim()
	c.Tenant = "tenant-2"
	c.DeviceID = "dev-2"

	got := Decide(c, row, t0)
	if !got.Accepted {
		t.Fatalf("want accepted, got %q", got.Reason)
	}
	if got.Row.ReleasedAt != nil {
		t.Error("an accepting rule must clear ReleasedAt: a successful claim re-asserts ownership")
	}
	if !got.Row.LeaseExpiry.Equal(t0.Add(KindDevice.Lease())) {
		t.Errorf("LeaseExpiry = %v, want %v", got.Row.LeaseExpiry, t0.Add(KindDevice.Lease()))
	}
	if got.Row.Tenant != "tenant-2" || got.Row.DeviceID != "dev-2" {
		t.Errorf("tenant/device = %q/%q, want tenant-2/dev-2", got.Row.Tenant, got.Row.DeviceID)
	}
	if !got.Row.LastSuccessfulClaimAt.Equal(t0) {
		t.Error("an accepting rule must stamp LastSuccessfulClaimAt")
	}
}

func TestRejectedClaimNeverAdvancesTheDormancyClock(t *testing.T) {
	row := boundRow()
	c := validClaim()
	c.PairingPublicKey = "pair-attacker"
	c.AttestKeyID = "attest-attacker"

	got := Decide(c, row, t0.Add(48*time.Hour))
	if got.Accepted {
		t.Fatal("expected refusal")
	}
	if got.Row != nil {
		t.Fatal("a refusal must not produce a row to write; the caller stamps LastFailedClaimAt")
	}
	// The point of the assertion: a phone retrying a failing claim every five
	// minutes must not hold its own row non-dormant forever, which is what
	// made an earlier revision's dormancy rule unreachable in production.
}

func TestR2RequiresTheRowsAttestKeyNotJustAnyValidProof(t *testing.T) {
	row := boundRow()
	c := validClaim()
	c.PairingPublicKey = "pair-attacker"
	c.AttestKeyID = "attest-stranger" // valid proof, but not this row's key

	got := Decide(c, row, t0)
	if got.Accepted {
		t.Fatal("R2 must key on the row's stored attest key id; any-valid-proof would let a stranger replace the pairing key")
	}
	if got.Rule != RuleR3 {
		t.Errorf("Rule = %q, want R3", got.Rule)
	}
}
