// Package httpapi is Canopy's HTTP surface.
//
// Two shapes here are deliberate and were both defects in earlier drafts of the
// design:
//
//   - A Canopy status is not an APNs status. /v1/push answers 200 only when APNs
//     actually answered, and carries Apple's status in the body; every Canopy-side
//     failure gets a distinct HTTP status that the client must not feed into its
//     token hygiene.
//   - /v1/health reveals nothing. It is the one open endpoint, so it says only
//     that the process is up.
package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/mvks5/canopy/internal/apns"
	"github.com/mvks5/canopy/internal/binding"
	"github.com/mvks5/canopy/internal/challenge"
	"github.com/mvks5/canopy/internal/claims"
	"github.com/mvks5/canopy/internal/hashing"
	"github.com/mvks5/canopy/internal/pairing"
	"github.com/mvks5/canopy/internal/store"
	"github.com/mvks5/canopy/internal/tenant"
	"github.com/mvks5/canopy/internal/vouch"
)

// AttestVerifier checks Apple App Attest proofs. It is an interface because the
// real implementation needs attestation fixtures captured from a physical
// device; until it lands, the zero value fails closed (see DenyAttest).
type AttestVerifier interface {
	// VerifyAttestation checks a first-use attestation for keyID over
	// clientData, and reports whether it is genuine.
	VerifyAttestation(attestation []byte, keyID string, clientData []byte, now time.Time) error
	// VerifyAssertion checks a later assertion by keyID over clientData.
	VerifyAssertion(assertion []byte, keyID string, clientData []byte, now time.Time) error
}

// DenyAttest refuses every proof. It is the default so that a deployment which
// forgets to wire a real verifier rejects claims rather than accepting
// unverified ones — the failure mode has to be "no push", never "anyone binds".
type DenyAttest struct{}

var errNoVerifier = errors.New("app attest verification is not configured")

func (DenyAttest) VerifyAttestation([]byte, string, []byte, time.Time) error { return errNoVerifier }
func (DenyAttest) VerifyAssertion([]byte, string, []byte, time.Time) error   { return errNoVerifier }

// Clock supplies the current time, injectable for tests.
type Clock func() time.Time

// Server holds Canopy's dependencies.
type Server struct {
	Store     *store.Store
	Tenants   *tenant.Service
	Challenge *challenge.Service
	Vouch     *vouch.Service
	APNs      *apns.Client
	Attest    AttestVerifier
	Now       Clock
	Log       *slog.Logger

	// BindingCap is the maximum live bindings one tenant may hold.
	BindingCap int

	// Limits. A nil limiter allows everything, which keeps tests readable.
	EnrollPerIP  *Limiter
	ClaimsPerIP  *Limiter
	PushPerToken *Limiter
	PerTenant    *Limiter
}

// DefaultBindingCap is the per-tenant live-binding limit.
const DefaultBindingCap = 500

// Handler returns the mux serving Canopy's API.
func (s *Server) Handler() http.Handler {
	if s.Attest == nil {
		s.Attest = DenyAttest{}
	}
	if s.Now == nil {
		s.Now = time.Now
	}
	if s.Log == nil {
		s.Log = slog.Default()
	}
	if s.BindingCap == 0 {
		s.BindingCap = DefaultBindingCap
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.health)
	mux.HandleFunc("POST /v1/enroll", s.enroll)
	mux.HandleFunc("POST /v1/challenges", s.authed(s.challenges))
	mux.HandleFunc("POST /v1/vouch", s.authed(s.vouch))
	mux.HandleFunc("POST /v1/claims", s.authed(s.claims))
	mux.HandleFunc("POST /v1/push", s.authed(s.push))
	mux.HandleFunc("POST /v1/bindings/release", s.authed(s.release))
	mux.HandleFunc("DELETE /v1/bindings", s.authed(s.deleteBinding))
	return mux
}

// --- plumbing ---

func (s *Server) authed(h func(w http.ResponseWriter, r *http.Request, tenantID string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := s.Tenants.Authenticate(r.Header.Get("Authorization"))
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "unauthenticated")
			return
		}
		if !s.PerTenant.Allow(id, s.Now()) {
			writeErr(w, http.StatusTooManyRequests, "rate_limited")
			return
		}
		h(w, r, id)
	}
}

func decode(r *http.Request, dst any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	return dec.Decode(dst)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func writeErr(w http.ResponseWriter, status int, reason string) {
	writeJSON(w, status, map[string]string{"error": reason})
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// --- handlers ---

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	// Deliberately bare. This is the only unauthenticated endpoint, and a
	// health page that reports counts is an oracle for whether anyone is
	// printing.
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": Version})
}

// Version is reported by /v1/health.
const Version = "0.1.0"

func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	if !s.EnrollPerIP.Allow(clientIP(r), s.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	var body struct {
		InviteCode   string `json:"invite_code"`
		RecoveryCode string `json:"recovery_code"`
	}
	if err := decode(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed_body")
		return
	}

	c, err := s.Tenants.Enroll(body.InviteCode, body.RecoveryCode, s.Now())
	switch {
	case errors.Is(err, tenant.ErrInviteRequired):
		writeErr(w, http.StatusForbidden, "invite_required")
		return
	case errors.Is(err, tenant.ErrUnknownRecovery):
		writeErr(w, http.StatusForbidden, "unknown_recovery_code")
		return
	case errors.Is(err, tenant.ErrFull):
		writeErr(w, http.StatusServiceUnavailable, "enrollment_full")
		return
	case err != nil:
		s.Log.Error("enroll", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]string{
		"tenant_id":     c.ID,
		"tenant_secret": c.Secret,
		"recovery_code": c.Recovery,
	})
}

func (s *Server) challenges(w http.ResponseWriter, r *http.Request, tenantID string) {
	var body struct {
		Purpose string `json:"purpose"`
	}
	if err := decode(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed_body")
		return
	}

	issued, err := s.Challenge.Issue(tenantID, challenge.Purpose(body.Purpose), s.Now())
	if errors.Is(err, challenge.ErrBadPurpose) {
		writeErr(w, http.StatusBadRequest, "unknown_purpose")
		return
	}
	if err != nil {
		s.Log.Error("issue challenge", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"challenge":  issued.Challenge,
		"expires_at": issued.ExpiresAt.UTC().Format(time.RFC3339),
	})
}

func (s *Server) vouch(w http.ResponseWriter, r *http.Request, tenantID string) {
	var body struct {
		Token       string `json:"token"`
		Environment string `json:"apns_environment"`
	}
	if err := decode(r, &body); err != nil || body.Token == "" {
		writeErr(w, http.StatusBadRequest, "malformed_body")
		return
	}

	env := apns.Production
	if body.Environment == string(apns.Sandbox) {
		env = apns.Sandbox
	}

	err := s.Vouch.Mint(r.Context(), body.Token, tenantID, env, s.Now())
	if errors.Is(err, vouch.ErrRateLimited) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if err != nil {
		s.Log.Error("mint vouch", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}
	// 202 regardless of what APNs did with the push. This endpoint is the one
	// that pushes to a token nobody has yet proven they own; distinguishing a
	// live token from a dead one here would make it a liveness oracle.
	w.WriteHeader(http.StatusAccepted)
}

type claimBody struct {
	Token            string `json:"token"`
	ClientData       string `json:"client_data"` // base64, verified verbatim
	Challenge        string `json:"challenge"`
	VouchNonce       string `json:"vouch_nonce"`
	PairingPublicKey string `json:"pairing_public_key"`
	PairingSignature string `json:"pairing_signature"`
	DeviceID         string `json:"device_id"`
	BindingKind      string `json:"binding_kind"`
	APNSEnvironment  string `json:"apns_environment"`
	AttestKeyID      string `json:"attest_key_id"`
	Attestation      string `json:"attestation"`
	Assertion        string `json:"assertion"`
}

func (s *Server) claims(w http.ResponseWriter, r *http.Request, tenantID string) {
	if !s.ClaimsPerIP.Allow(clientIP(r), s.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	var body claimBody
	if err := decode(r, &body); err != nil || body.Token == "" {
		writeErr(w, http.StatusBadRequest, "malformed_body")
		return
	}
	now := s.Now()

	kind := binding.Kind(body.BindingKind)
	if kind != binding.KindActivity && kind != binding.KindStart && kind != binding.KindDevice {
		writeErr(w, http.StatusBadRequest, "unknown_binding_kind")
		return
	}
	if (body.Attestation == "") == (body.Assertion == "") {
		writeErr(w, http.StatusBadRequest, "exactly_one_proof_required")
		return
	}

	clientData, err := decodeB64(body.ClientData)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "malformed_client_data")
		return
	}

	// Cheap checks before any signature work: the challenge must exist, be
	// unexpired, and have been issued to *this* tenant for *this* purpose.
	purpose := challenge.Assertion
	if body.Attestation != "" {
		purpose = challenge.Attestation
	}
	ok, err := s.Challenge.Consume(body.Challenge, tenantID, purpose, now)
	if err != nil {
		s.Log.Error("consume challenge", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}
	if !ok {
		writeErr(w, http.StatusForbidden, "challenge_invalid")
		return
	}

	// The claim's fields must match the bytes that were signed, or the
	// signature guarantees nothing about what we are about to act on.
	if !clientDataMatches(clientData, body) {
		writeErr(w, http.StatusForbidden, "client_data_mismatch")
		return
	}

	pairingOK := pairing.Verify(body.PairingPublicKey, clientData, body.PairingSignature)

	attestOK := true
	if body.Attestation != "" {
		raw, decErr := decodeB64(body.Attestation)
		attestOK = decErr == nil &&
			s.Attest.VerifyAttestation(raw, body.AttestKeyID, clientData, now) == nil
	} else {
		raw, decErr := decodeB64(body.Assertion)
		attestOK = decErr == nil &&
			s.Attest.VerifyAssertion(raw, body.AttestKeyID, clientData, now) == nil
	}

	vouchOK := false
	if kind.NeedsVouch() && body.VouchNonce != "" {
		vouchOK, err = s.Vouch.Verify(body.Token, body.VouchNonce, tenantID, now)
		if err != nil {
			s.Log.Error("verify vouch", "err", err)
			writeErr(w, http.StatusInternalServerError, "internal")
			return
		}
	}

	tokenHash := hashing.Digest(body.Token)

	// The cap counts only live bindings, and only for a token this tenant does
	// not already hold — re-claiming something you already have must never be
	// refused for capacity.
	if existing, _ := s.Store.GetBinding(tokenHash); existing == nil {
		n, err := s.Store.LiveCount(tenantID, now)
		if err != nil {
			s.Log.Error("live count", "err", err)
			writeErr(w, http.StatusInternalServerError, "internal")
			return
		}
		if n >= s.BindingCap {
			writeErr(w, http.StatusTooManyRequests, "binding_limit")
			return
		}
	}

	d, err := claims.Apply(s.Store, binding.Claim{
		TokenHash:        tokenHash,
		Kind:             kind,
		Tenant:           tenantID,
		DeviceID:         body.DeviceID,
		AttestKeyID:      body.AttestKeyID,
		PairingPublicKey: body.PairingPublicKey,
		APNSEnvironment:  body.APNSEnvironment,
		AttestProofValid: attestOK,
		PairingSigValid:  pairingOK,
		VouchOK:          vouchOK,
	}, now)
	if err != nil {
		s.Log.Error("apply claim", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}

	if !d.Accepted {
		writeErr(w, http.StatusForbidden, string(d.Reason))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) push(w http.ResponseWriter, r *http.Request, tenantID string) {
	var body struct {
		Token      string          `json:"token"`
		PushType   string          `json:"push_type"`
		Priority   int             `json:"priority"`
		Payload    json.RawMessage `json:"payload"`
		CollapseID string          `json:"collapse_id"`
	}
	if err := decode(r, &body); err != nil || body.Token == "" {
		writeErr(w, http.StatusBadRequest, "malformed_body")
		return
	}
	now := s.Now()
	tokenHash := hashing.Digest(body.Token)

	if !s.PushPerToken.Allow(tokenHash, now) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited")
		return
	}

	row, err := s.Store.GetBinding(tokenHash)
	if err != nil {
		s.Log.Error("get binding", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}
	switch {
	case row == nil, !row.IsLive(now):
		// Routine housekeeping — a released or expired row. It means
		// "re-claim", not "you were evicted", and the client must not treat it
		// as a suspension condition.
		writeErr(w, http.StatusForbidden, "not_bound")
		return
	case row.Tenant != tenantID:
		writeErr(w, http.StatusForbidden, "not_owner")
		return
	}

	pt := apns.PushType(body.PushType)
	if _, err := pt.Topic(s.APNs.BundleID); err != nil {
		writeErr(w, http.StatusBadRequest, "unknown_push_type")
		return
	}

	env := apns.Production
	if row.APNSEnvironment == string(apns.Sandbox) {
		env = apns.Sandbox
	}

	res, corrected := s.APNs.Send(r.Context(), apns.Push{
		Token:       body.Token,
		Environment: env,
		Type:        pt,
		Priority:    body.Priority,
		Payload:     body.Payload,
		CollapseID:  body.CollapseID,
	}, now)

	if corrected != env {
		if err := s.Store.SetAPNSEnvironment(tokenHash, string(corrected)); err != nil {
			s.Log.Error("correct environment", "err", err)
		}
	}

	switch res.Outcome {
	case apns.Delivered:
		if res.TokenIsDead() {
			if err := s.Store.DropBinding(tokenHash); err != nil {
				s.Log.Error("drop dead binding", "err", err)
			}
		} else if res.APNsStatus == 200 {
			if err := s.Store.MarkDelivered(tokenHash, now, now.Add(row.Kind.Lease())); err != nil {
				s.Log.Error("mark delivered", "err", err)
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"apns_status": res.APNsStatus,
			"apns_reason": res.APNsReason,
		})
	case apns.Transport:
		// Never reached APNs. 502 tells the client to retry and touch nothing;
		// it must not be read as a statement about the token.
		writeErr(w, http.StatusBadGateway, "transport")
	default:
		writeErr(w, http.StatusBadRequest, "refused")
	}
}

func (s *Server) release(w http.ResponseWriter, r *http.Request, tenantID string) {
	s.mutateBinding(w, r, tenantID, func(tokenHash string, now time.Time) (bool, error) {
		return s.Store.ReleaseBinding(tokenHash, tenantID, now)
	})
}

func (s *Server) deleteBinding(w http.ResponseWriter, r *http.Request, tenantID string) {
	s.mutateBinding(w, r, tenantID, func(tokenHash string, _ time.Time) (bool, error) {
		return s.Store.DeleteBinding(tokenHash, tenantID)
	})
}

func (s *Server) mutateBinding(w http.ResponseWriter, r *http.Request, _ string, do func(string, time.Time) (bool, error)) {
	var body struct {
		Token string `json:"token"`
	}
	if err := decode(r, &body); err != nil || body.Token == "" {
		writeErr(w, http.StatusBadRequest, "malformed_body")
		return
	}
	ok, err := do(hashing.Digest(body.Token), s.Now())
	if err != nil {
		s.Log.Error("mutate binding", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}
	if !ok {
		writeErr(w, http.StatusForbidden, "not_owner")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
