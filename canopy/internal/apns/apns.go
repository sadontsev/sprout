// Package apns talks to Apple Push Notification service on Canopy's behalf.
//
// Two rules from the design are enforced here rather than by callers, because
// both were real defects in earlier drafts:
//
//   - A tenant can never choose a topic. Topics come from a hardcoded table
//     keyed by push type; they are the only strings this service will sign for.
//   - A Canopy-side failure is not an APNs status. Result keeps them in separate
//     fields so a transport error cannot be mistaken for BadDeviceToken and
//     delete a healthy registration.
package apns

import "fmt"

// Environment selects which APNs gateway — and which signing key — to use.
// Modern APNs keys are environment-scoped, so the two always move together.
type Environment string

const (
	Sandbox    Environment = "sandbox"
	Production Environment = "production"
)

// Host is the APNs gateway for this environment.
func (e Environment) Host() string {
	if e == Sandbox {
		return "api.sandbox.push.apple.com"
	}
	return "api.push.apple.com"
}

// Other returns the opposite environment. A claim can carry a mislabelled
// environment — the app derives it from an entitlement, and a development-signed
// Release build is an easy way to get it wrong — so a BadDeviceToken triggers one
// retry against Other, swapping host *and* signing key. Signing a production JWT
// against the sandbox host returns InvalidProviderToken, not BadDeviceToken, and
// would never converge.
func (e Environment) Other() Environment {
	if e == Sandbox {
		return Production
	}
	return Sandbox
}

// PushType is the kind of push being sent.
type PushType string

const (
	// LiveActivity updates or starts a Live Activity card.
	LiveActivity PushType = "liveactivity"
	// Alert is an ordinary user-visible banner.
	Alert PushType = "alert"
	// Background is a silent push. Canopy uses it only to vouch a device token:
	// it carries a nonce that only the install actually holding the token can
	// echo back.
	Background PushType = "background"
)

// Topic returns the APNs topic for this push type against bundleID. The mapping
// is total and hardcoded: there is no path by which a caller-supplied string
// reaches the apns-topic header.
func (p PushType) Topic(bundleID string) (string, error) {
	switch p {
	case LiveActivity:
		return bundleID + ".push-type.liveactivity", nil
	case Alert, Background:
		return bundleID, nil
	default:
		return "", fmt.Errorf("apns: unknown push type %q", p)
	}
}

// APNSPushTypeHeader is the value for the apns-push-type header.
func (p PushType) APNSPushTypeHeader() string { return string(p) }

// MaxPayloadBytes is APNs' hard limit. Canopy rejects an oversized payload
// rather than forwarding it, so the caller learns the cause instead of reading
// an opaque 413 from Apple.
const MaxPayloadBytes = 4096

// ClampPriority forces the APNs priority to one of the two values this service
// will ever send. Priority 10 spends the device's Live Activity budget and 5 is
// opportunistic; a caller that could pass anything else would be able to burn a
// user's budget from a bug.
func ClampPriority(p int) int {
	if p >= 10 {
		return 10
	}
	return 5
}

// Outcome says what happened to a push attempt, at the transport layer. It is
// deliberately separate from APNsStatus: "the request failed" and "APNs rejected
// this token" are different questions, and answering both with one number is how
// a Canopy-side 400 would delete a perfectly healthy registration.
type Outcome string

const (
	// Delivered means APNs answered. APNsStatus and APNsReason are meaningful;
	// the caller's existing token hygiene applies to them.
	Delivered Outcome = "delivered"
	// Transport means the request never got an answer from APNs. Retry; touch
	// no registration.
	Transport Outcome = "transport"
	// Refused means Canopy declined to send — oversized payload, unknown push
	// type, no signing key. Never a token-hygiene signal.
	Refused Outcome = "refused"
)

// Result is a push attempt's outcome.
type Result struct {
	Outcome    Outcome
	APNsStatus int    // only meaningful when Outcome == Delivered
	APNsReason string // APNs' "reason" field, verbatim, when it supplied one
	Err        error  // populated for Transport and Refused
}

// TokenIsDead reports whether APNs told us this token will never work again, so
// the caller may drop it. It is false for every non-Delivered outcome by
// construction — the one place the two-field discipline pays off.
func (r Result) TokenIsDead() bool {
	if r.Outcome != Delivered {
		return false
	}
	return r.APNsStatus == 410 ||
		(r.APNsStatus == 400 && r.APNsReason == "BadDeviceToken")
}
