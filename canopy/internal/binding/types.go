// Package binding implements Canopy's token-binding decision rules.
//
// Everything here is pure: no I/O, no wall clock, no crypto. Signature and
// attestation verification happen upstream and arrive as booleans, because the
// rules are the part of this design that has historically been wrong and they
// are only exhaustively testable when nothing else is in the way.
package binding

import "time"

// Kind is the binding_kind of a token. It is immutable after the first bind:
// it selects the lease and retention horizons, so letting a claim rewrite it
// would let an attacker relabel a device row as activity and collapse its
// retention.
type Kind string

const (
	KindActivity Kind = "activity"
	KindStart    Kind = "start"
	KindDevice   Kind = "device"
)

// Lease and retention horizons, per spec §6.
const (
	LeaseActivity     = 72 * time.Hour
	LeaseStartDevice  = 30 * 24 * time.Hour
	RetainActivity    = 7 * 24 * time.Hour
	RetainStartDevice = 90 * 24 * time.Hour
	Dormancy          = 90 * 24 * time.Hour
)

// Lease returns how long a fresh or renewed binding of this kind stays live.
func (k Kind) Lease() time.Duration {
	if k == KindActivity {
		return LeaseActivity
	}
	return LeaseStartDevice
}

// RetainAfterLease returns how long the row survives past lease expiry before
// hard deletion.
func (k Kind) RetainAfterLease() time.Duration {
	if k == KindActivity {
		return RetainActivity
	}
	return RetainStartDevice
}

// DormancyApplies reports whether a token of this kind can ever be re-bound by
// the dormancy path. Activity tokens die with their card long before 90 days,
// so the question never arises for them.
func (k Kind) DormancyApplies() bool { return k != KindActivity }

// NeedsVouch reports whether an unseen token of this kind must prove it is
// reachable on the claiming device before it may be bound. Only device tokens
// can receive the silent push that proves it; start and activity tokens cannot,
// which is a stated residual in spec §4 rather than a gap to paper over.
func (k Kind) NeedsVouch() bool { return k == KindDevice }

// Permits reports whether a binding of this kind may carry an APNs push of this
// type. Values match apns.PushType; they are strings here so this package stays
// free of the APNs client.
//
// THIS IS THE GATE THAT MAKES binding_kind SAFE TO TAKE FROM THE CLAIMANT.
//
// Canopy cannot tell a device token from a push-to-start token by looking at it
// — only the claimant's own binding_kind says which it is. NeedsVouch therefore
// answers "what did the claimant CALL this token?" when the security question
// is "can this token receive the silent push that would prove reachability?".
// Those are synonyms only while the claimant is honest, which is exactly the
// assumption the vouch exists to remove.
//
// An adversarial review reproduced the consequence end to end: claim a victim's
// DEVICE token while declaring binding_kind "start", and R0 binds it with no
// vouch because start tokens legitimately cannot be vouched. Push `alert` to it
// and APNs resolves the topic to the bare bundle id — the correct topic for a
// device token — and delivers an attacker-authored banner to the victim's
// phone.
//
// The label is now only as powerful as the capability it names. A row bound as
// `start` may send Live Activity pushes and nothing else, so declaring a device
// token to be a start token buys an attacker a binding that can only carry a
// push APNs will not deliver to that token. The lie stops paying.
func (k Kind) Permits(pushType string) bool {
	switch k {
	case KindDevice:
		// Alert banners, and the silent push the vouch itself rides on.
		return pushType == "alert" || pushType == "background"
	case KindStart, KindActivity:
		// Push-to-start and content-state updates. Both are Live Activity
		// pushes and both resolve to the .push-type.liveactivity topic.
		return pushType == "liveactivity"
	default:
		return false
	}
}

// Rule identifies which rule of spec §5 decided a claim. Tests assert on this
// rather than on the resulting row: a suite that checks each rule in isolation
// cannot catch two rules matching one input, which is how three revisions of
// overlapping guards survived review.
type Rule string

const (
	RuleR0 Rule = "R0" // unseen token, bind first-come (vouched if device)
	RuleR1 Rule = "R1" // pairing key matches the row
	RuleR2 Rule = "R2" // pairing key differs, attest key matches the row
	RuleR3 Rule = "R3" // nothing matched
)

// Reason is the refusal code returned to Trellis. Each is emitted by exactly
// one check so the client can say something true.
type Reason string

const (
	ReasonNone                    Reason = ""
	ReasonAttestationInvalid      Reason = "attestation_invalid"
	ReasonPairingSignatureInvalid Reason = "pairing_signature_invalid"
	ReasonKindMismatch            Reason = "kind_mismatch"
	ReasonVouchRequired           Reason = "vouch_required"
	ReasonPairingMismatch         Reason = "pairing_mismatch"
)

// Claim is one already-verified claim. AttestProofValid and PairingSigValid are
// the outcome of the crypto layer; VouchOK is the outcome of the vouch layer.
type Claim struct {
	TokenHash        string
	Kind             Kind
	Tenant           string
	DeviceID         string
	AttestKeyID      string
	PairingPublicKey string
	APNSEnvironment  string

	AttestProofValid bool
	PairingSigValid  bool

	// VouchOK reports that this exact token was vouched by this exact tenant
	// with an unexpired, unconsumed nonce. It is per token and per tenant: a
	// standing per-install exemption was revision 7's cross-user takeover.
	VouchOK bool
}

// Row is the stored binding, or nil when the token is UNSEEN.
type Row struct {
	TokenHash             string
	Kind                  Kind
	Tenant                string
	DeviceID              string
	AttestKeyID           string
	PairingPublicKey      string
	APNSEnvironment       string
	LeaseExpiry           time.Time
	LastDeliveryAt        time.Time
	LastSuccessfulClaimAt time.Time
	LastFailedClaimAt     time.Time
	ReleasedAt            *time.Time
	CreatedAt             time.Time
}

// Decision is what the store must persist. Accepted decisions always renew the
// lease, clear ReleasedAt, stamp LastSuccessfulClaimAt, and re-point Tenant and
// DeviceID — stated once, in Decide, because stating it per-rule is how an
// earlier revision lost the ReleasedAt clear.
type Decision struct {
	Rule     Rule
	Accepted bool
	Reason   Reason
	Row      *Row // the row to write when Accepted; nil otherwise
}
