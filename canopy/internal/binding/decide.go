package binding

import "time"

// Decide applies spec §5's rules to one claim. Rules are evaluated in order and
// the first match wins; the guards are not independently exclusive, and the
// ordering is what resolves them. Tests assert which rule fired for that reason.
//
// Preconditions (both proofs valid, kind agrees with the row) are checked before
// any rule, so no rule has to restate them.
func Decide(c Claim, row *Row, now time.Time) Decision {
	if !c.AttestProofValid {
		return Decision{Reason: ReasonAttestationInvalid}
	}
	if !c.PairingSigValid {
		return Decision{Reason: ReasonPairingSignatureInvalid}
	}
	if row != nil && c.Kind != row.Kind {
		// binding_kind selects the lease and retention horizons, so a claim
		// must never be allowed to relabel a row.
		return Decision{Reason: ReasonKindMismatch}
	}

	switch {
	case row == nil:
		// R0. An unseen device token must first prove it is reachable on the
		// claiming device. Start and activity tokens cannot receive the silent
		// push that proves it, so they bind first-come — a stated residual,
		// not an oversight.
		if c.Kind.NeedsVouch() && !c.VouchOK {
			return Decision{Rule: RuleR0, Reason: ReasonVouchRequired}
		}
		return accept(RuleR0, c, &Row{
			TokenHash:       c.TokenHash,
			Kind:            c.Kind,
			APNSEnvironment: c.APNSEnvironment,
			CreatedAt:       now,
		}, now)

	case c.PairingPublicKey == row.PairingPublicKey:
		// R1, the primary path and the durable one. The attest key legitimately
		// changes on every reinstall while the pairing key does not, so this
		// rule adopts whatever attest key the claim carries.
		return accept(RuleR1, c, row, now)

	case c.AttestKeyID == row.AttestKeyID:
		// R2, the Keychain-lost-but-app-not-reinstalled case. The surviving
		// App Attest key authorises storing a new pairing key.
		return accept(RuleR2, c, row, now)

	default:
		return Decision{Rule: RuleR3, Reason: ReasonPairingMismatch}
	}
}

// accept applies the writes every accepting rule shares. Stating them once is
// deliberate: an earlier revision stated them per-rule and lost the ReleasedAt
// clear from one of them, which livelocked released-then-reclaimed tokens
// between a successful claim and a refused push.
func accept(r Rule, c Claim, row *Row, now time.Time) Decision {
	next := *row
	next.Tenant = c.Tenant
	next.DeviceID = c.DeviceID
	next.AttestKeyID = c.AttestKeyID
	next.PairingPublicKey = c.PairingPublicKey
	next.LeaseExpiry = now.Add(c.Kind.Lease())
	next.LastSuccessfulClaimAt = now
	next.ReleasedAt = nil
	return Decision{Rule: r, Accepted: true, Row: &next}
}
