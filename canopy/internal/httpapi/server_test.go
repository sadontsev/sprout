package httpapi

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/apns"
	"github.com/sadontsev/sprout/canopy/internal/binding"
	"github.com/sadontsev/sprout/canopy/internal/challenge"
	"github.com/sadontsev/sprout/canopy/internal/keystore"
	"github.com/sadontsev/sprout/canopy/internal/pairing"
	"github.com/sadontsev/sprout/canopy/internal/store"
	"github.com/sadontsev/sprout/canopy/internal/tenant"
	"github.com/sadontsev/sprout/canopy/internal/vouch"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

// allowAttest stands in for the real App Attest verifier, which needs fixtures
// captured from a physical device.
//
// `err` lets a test choose WHICH failure the verifier reports. It used to return only nil or
// errNoVerifier, which meant keystore.ErrReattestRequired could never occur in any test — and
// deleting the handler branch that translates it left the suite green. That branch is the
// difference between an install recovering by itself and one asserting forever against a key the
// relay has never seen.
type allowAttest struct {
	fail bool
	err  error
}

func (a allowAttest) result() error {
	if a.err != nil {
		return a.err
	}
	if a.fail {
		return errNoVerifier
	}
	return nil
}

func (a allowAttest) VerifyAttestation([]byte, string, []byte, time.Time) error {
	return a.result()
}
func (a allowAttest) VerifyAssertion([]byte, string, []byte, time.Time) error {
	return a.result()
}

type harness struct {
	t      *testing.T
	srv    *httptest.Server
	server *Server
	apns   *fakeGateway
	device *ecdsa.PrivateKey
	creds  tenant.Credentials
}

// fakeGateway records pushes and answers however the test wants.
type fakeGateway struct {
	sent  []string // apns-push-type of each request
	tos   []string // path of each request
	reply func(*http.Request) (int, string)
}

func newHarness(t *testing.T) *harness {
	t.Helper()

	st, err := store.Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	gw := &fakeGateway{reply: func(*http.Request) (int, string) { return 200, "" }}
	gwSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gw.sent = append(gw.sent, r.Header.Get("apns-push-type"))
		gw.tos = append(gw.tos, r.URL.Path)
		status, reason := gw.reply(r)
		w.WriteHeader(status)
		if reason != "" {
			_, _ = w.Write([]byte(`{"reason":"` + reason + `"}`))
		}
	}))
	t.Cleanup(gwSrv.Close)

	mkSigner := func(kid string) *apns.Signer {
		key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		der, _ := x509.MarshalPKCS8PrivateKey(key)
		s, err := apns.NewSigner(kid, "TEAMID", pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
		if err != nil {
			t.Fatalf("NewSigner: %v", err)
		}
		return s
	}
	client, err := apns.NewClient("com.example.sprout", mkSigner("SAND"), mkSigner("PROD"))
	if err != nil {
		t.Fatalf("apns.NewClient: %v", err)
	}
	client.SetHostForTest(apns.Sandbox, gwSrv.URL)
	client.SetHostForTest(apns.Production, gwSrv.URL)

	tenants := &tenant.Service{Store: st}
	server := &Server{
		Store:     st,
		Tenants:   tenants,
		Challenge: &challenge.Service{Store: st},
		Vouch:     &vouch.Service{Store: st, APNs: client},
		APNs:      client,
		Attest:    allowAttest{},
		Now:       func() time.Time { return t0 },
	}
	srv := httptest.NewServer(server.Handler())
	t.Cleanup(srv.Close)

	creds, err := tenants.Enroll("", "", t0)
	if err != nil {
		t.Fatalf("Enroll: %v", err)
	}
	device, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)

	return &harness{t: t, srv: srv, server: server, apns: gw, device: device, creds: creds}
}

func (h *harness) do(method, path string, body any, bearer string) (*http.Response, map[string]any) {
	h.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			h.t.Fatalf("encode: %v", err)
		}
	}
	req, err := http.NewRequest(method, h.srv.URL+path, &buf)
	if err != nil {
		h.t.Fatalf("new request: %v", err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatalf("do: %v", err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return resp, out
}

// claimFor builds a fully-signed claim. Passing a different declaredToken from
// the one inside the signed bytes is how the sign-and-swap test is expressed.
func (h *harness) claimFor(token, declaredToken, kind, vouchNonce, challengeStr string) map[string]any {
	h.t.Helper()
	pub := pairing.EncodePublicKey(&h.device.PublicKey)

	signed := map[string]string{
		"challenge":          challengeStr,
		"token":              token,
		"pairing_public_key": pub,
		"device_id":          "dev-1",
		"binding_kind":       kind,
		"apns_environment":   "production",
		"vouch_nonce":        vouchNonce,
	}
	clientData, _ := json.Marshal(signed)
	digest := sha256.Sum256(clientData)
	sig, _ := ecdsa.SignASN1(rand.Reader, h.device, digest[:])

	return map[string]any{
		"token":              declaredToken,
		"client_data":        base64.RawURLEncoding.EncodeToString(clientData),
		"challenge":          challengeStr,
		"vouch_nonce":        vouchNonce,
		"pairing_public_key": pub,
		"pairing_signature":  base64.RawURLEncoding.EncodeToString(sig),
		"device_id":          "dev-1",
		"binding_kind":       kind,
		"apns_environment":   "production",
		"attest_key_id":      "attest-1",
		"assertion":          base64.RawURLEncoding.EncodeToString([]byte("assertion-bytes")),
	}
}

func (h *harness) challenge(purpose string) string {
	h.t.Helper()
	resp, body := h.do("POST", "/v1/challenges", map[string]string{"purpose": purpose}, h.creds.Bearer())
	if resp.StatusCode != http.StatusCreated {
		h.t.Fatalf("challenge: status %d body %v", resp.StatusCode, body)
	}
	return body["challenge"].(string)
}

// vouchNonceFor mints a vouch and digs the nonce out of the silent push, which
// is the only place it appears.
func (h *harness) vouchNonceFor(token string) string {
	h.t.Helper()
	var captured string
	h.apns.reply = func(r *http.Request) (int, string) {
		raw, _ := io.ReadAll(r.Body)
		var body struct {
			VouchNonce string `json:"vouch_nonce"`
		}
		_ = json.Unmarshal(raw, &body)
		if body.VouchNonce != "" {
			captured = body.VouchNonce
		}
		return 200, ""
	}
	resp, _ := h.do("POST", "/v1/vouch", map[string]string{"token": token}, h.creds.Bearer())
	if resp.StatusCode != http.StatusAccepted {
		h.t.Fatalf("vouch: status %d", resp.StatusCode)
	}
	h.apns.reply = func(*http.Request) (int, string) { return 200, "" }
	return captured
}

// --- tests ---

func TestHealthIsOpenAndBare(t *testing.T) {
	h := newHarness(t)
	resp, body := h.do("GET", "/v1/health", nil, "")

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if body["ok"] != true {
		t.Errorf("body = %v, want ok", body)
	}
	for _, leaky := range []string{"tenants", "bindings", "registrations", "count", "tokens"} {
		if _, found := body[leaky]; found {
			t.Errorf("health must reveal nothing about tenants, found %q", leaky)
		}
	}
}

func TestEveryOtherEndpointRequiresAuth(t *testing.T) {
	h := newHarness(t)
	for _, ep := range []struct{ method, path string }{
		{"POST", "/v1/challenges"},
		{"POST", "/v1/vouch"},
		{"POST", "/v1/claims"},
		{"POST", "/v1/push"},
		{"POST", "/v1/bindings/release"},
		{"DELETE", "/v1/bindings"},
	} {
		resp, _ := h.do(ep.method, ep.path, map[string]string{"token": "x"}, "")
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s %s unauthenticated = %d, want 401", ep.method, ep.path, resp.StatusCode)
		}
	}
}

func TestEnrollThenUseTheCredential(t *testing.T) {
	h := newHarness(t)
	resp, body := h.do("POST", "/v1/enroll", map[string]string{}, "")
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("status = %d body %v", resp.StatusCode, body)
	}
	for _, k := range []string{"tenant_id", "tenant_secret", "recovery_code"} {
		if body[k] == "" || body[k] == nil {
			t.Errorf("enroll response missing %q", k)
		}
	}
	bearer := body["tenant_id"].(string) + "." + body["tenant_secret"].(string)
	if resp, _ := h.do("POST", "/v1/challenges", map[string]string{"purpose": "assertion"}, bearer); resp.StatusCode != http.StatusCreated {
		t.Errorf("new credential could not issue a challenge: %d", resp.StatusCode)
	}
}

func TestDeviceTokenRequiresAVouchThenBinds(t *testing.T) {
	h := newHarness(t)

	// Without a vouch the claim is refused.
	c := h.claimFor("tok-A", "tok-A", "device", "", h.challenge("assertion"))
	resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer())
	if resp.StatusCode != http.StatusForbidden || body["error"] != "vouch_required" {
		t.Fatalf("status %d body %v, want 403 vouch_required", resp.StatusCode, body)
	}

	// With one, it binds.
	nonce := h.vouchNonceFor("tok-A")
	if nonce == "" {
		t.Fatal("no nonce reached the silent push")
	}
	c = h.claimFor("tok-A", "tok-A", "device", nonce, h.challenge("assertion"))
	resp, body = h.do("POST", "/v1/claims", c, h.creds.Bearer())
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("status %d body %v, want 204", resp.StatusCode, body)
	}
}

func TestSignAndSwapIsRejected(t *testing.T) {
	h := newHarness(t)

	// A relay holds a genuine, correctly-signed claim for its own token and
	// tries to have Canopy act on a victim's token instead. This is the exact
	// attack the design's "a compromised Trellis cannot forge a different
	// claim" property exists to stop.
	c := h.claimFor("tok-MINE", "tok-VICTIM", "start", "", h.challenge("assertion"))
	resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer())

	if resp.StatusCode != http.StatusForbidden || body["error"] != "client_data_mismatch" {
		t.Fatalf("status %d body %v, want 403 client_data_mismatch", resp.StatusCode, body)
	}
	if row, _ := h.server.Store.GetBinding(hashOf("tok-VICTIM")); row != nil {
		t.Fatal("the victim's token must not have been bound")
	}
	if row, _ := h.server.Store.GetBinding(hashOf("tok-MINE")); row != nil {
		t.Fatal("nor the attacker's own: a rejected claim writes nothing")
	}
}

func TestChallengeIsSingleUseAcrossRequests(t *testing.T) {
	h := newHarness(t)
	ch := h.challenge("assertion")

	c := h.claimFor("tok-A", "tok-A", "start", "", ch)
	if resp, _ := h.do("POST", "/v1/claims", c, h.creds.Bearer()); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("first claim status %d", resp.StatusCode)
	}
	resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer())
	if resp.StatusCode != http.StatusForbidden || body["error"] != "challenge_invalid" {
		t.Fatalf("replayed claim: status %d body %v, want 403 challenge_invalid", resp.StatusCode, body)
	}
}

func TestClaimsFailClosedWithoutAnAttestVerifier(t *testing.T) {
	h := newHarness(t)
	h.server.Attest = DenyAttest{}

	c := h.claimFor("tok-A", "tok-A", "start", "", h.challenge("assertion"))
	resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer())
	if resp.StatusCode != http.StatusForbidden || body["error"] != "attestation_invalid" {
		t.Fatalf("status %d body %v — an unconfigured verifier must refuse, never accept", resp.StatusCode, body)
	}
}

func TestExactlyOneProofIsRequired(t *testing.T) {
	h := newHarness(t)

	both := h.claimFor("tok-A", "tok-A", "start", "", h.challenge("assertion"))
	both["attestation"] = base64.RawURLEncoding.EncodeToString([]byte("also-this"))
	if resp, _ := h.do("POST", "/v1/claims", both, h.creds.Bearer()); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("both proofs = %d, want 400", resp.StatusCode)
	}

	neither := h.claimFor("tok-A", "tok-A", "start", "", h.challenge("assertion"))
	delete(neither, "assertion")
	if resp, _ := h.do("POST", "/v1/claims", neither, h.creds.Bearer()); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("no proof = %d, want 400", resp.StatusCode)
	}
}

func bindStart(t *testing.T, h *harness, token string) {
	t.Helper()
	c := h.claimFor(token, token, "start", "", h.challenge("assertion"))
	if resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer()); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("bind %s: status %d body %v", token, resp.StatusCode, body)
	}
}

func TestPushRequiresABoundLiveToken(t *testing.T) {
	h := newHarness(t)

	push := map[string]any{"token": "tok-A", "push_type": "liveactivity", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}
	resp, body := h.do("POST", "/v1/push", push, h.creds.Bearer())
	if resp.StatusCode != http.StatusForbidden || body["error"] != "not_bound" {
		t.Fatalf("unbound push: status %d body %v, want 403 not_bound", resp.StatusCode, body)
	}

	bindStart(t, h, "tok-A")
	resp, body = h.do("POST", "/v1/push", push, h.creds.Bearer())
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("bound push: status %d body %v, want 200", resp.StatusCode, body)
	}
	if body["apns_status"] != float64(200) {
		t.Errorf("apns_status = %v, want 200", body["apns_status"])
	}
}

func TestPushFromAnotherTenantIsNotOwner(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")

	other, err := h.server.Tenants.Enroll("", "", t0)
	if err != nil {
		t.Fatalf("Enroll: %v", err)
	}
	push := map[string]any{"token": "tok-A", "push_type": "liveactivity", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}
	resp, body := h.do("POST", "/v1/push", push, other.Bearer())

	if resp.StatusCode != http.StatusForbidden || body["error"] != "not_owner" {
		t.Fatalf("status %d body %v, want 403 not_owner — distinct from not_bound", resp.StatusCode, body)
	}
}

func TestTransportFailureIsNotAnAPNsStatus(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")
	// Point the gateway at a dead port so the request cannot complete.
	h.server.APNs.SetHostForTest(apns.Production, "http://127.0.0.1:1")

	push := map[string]any{"token": "tok-A", "push_type": "liveactivity", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}
	resp, body := h.do("POST", "/v1/push", push, h.creds.Bearer())

	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502: a failed request says nothing about the token", resp.StatusCode)
	}
	if _, present := body["apns_status"]; present {
		t.Error("a transport failure must not carry an apns_status the client could act on")
	}
	if row, _ := h.server.Store.GetBinding(hashOf("tok-A")); row == nil {
		t.Error("a transport failure must never delete a binding")
	}
}

func TestDeadTokenDropsTheBinding(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")
	h.apns.reply = func(*http.Request) (int, string) { return 410, "Unregistered" }

	push := map[string]any{"token": "tok-A", "push_type": "liveactivity", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}
	resp, body := h.do("POST", "/v1/push", push, h.creds.Bearer())
	if resp.StatusCode != http.StatusOK || body["apns_status"] != float64(410) {
		t.Fatalf("status %d body %v, want 200 carrying APNs 410", resp.StatusCode, body)
	}
	if row, _ := h.server.Store.GetBinding(hashOf("tok-A")); row != nil {
		t.Error("a 410 means the token is genuinely dead; the row must go")
	}
}

func TestReleaseThenReclaimThenPushSucceeds(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")

	if resp, _ := h.do("POST", "/v1/bindings/release", map[string]string{"token": "tok-A"}, h.creds.Bearer()); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("release: status %d", resp.StatusCode)
	}

	push := map[string]any{"token": "tok-A", "push_type": "liveactivity", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}
	if resp, body := h.do("POST", "/v1/push", push, h.creds.Bearer()); resp.StatusCode != http.StatusForbidden || body["error"] != "not_bound" {
		t.Fatalf("push to a released token: status %d body %v, want 403 not_bound", resp.StatusCode, body)
	}

	// Re-claiming must make it pushable again. An earlier revision of the
	// design set the released flag and had no rule clear it, which livelocked
	// this exact sequence between a successful claim and a refused push.
	bindStart(t, h, "tok-A")
	if resp, body := h.do("POST", "/v1/push", push, h.creds.Bearer()); resp.StatusCode != http.StatusOK {
		t.Fatalf("push after re-claim: status %d body %v, want 200", resp.StatusCode, body)
	}
}

func TestDeleteReturnsTheTokenToUnseen(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")

	if resp, _ := h.do("DELETE", "/v1/bindings", map[string]string{"token": "tok-A"}, h.creds.Bearer()); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete: status %d", resp.StatusCode)
	}
	if row, _ := h.server.Store.GetBinding(hashOf("tok-A")); row != nil {
		t.Fatal("delete must return the token to UNSEEN — this is the reset-pairing recovery path")
	}
	bindStart(t, h, "tok-A") // and it binds fresh
}

func TestOnlyTheBoundTenantMayReleaseOrDelete(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")
	other, _ := h.server.Tenants.Enroll("", "", t0)

	for _, ep := range []struct{ method, path string }{
		{"POST", "/v1/bindings/release"},
		{"DELETE", "/v1/bindings"},
	} {
		resp, body := h.do(ep.method, ep.path, map[string]string{"token": "tok-A"}, other.Bearer())
		if resp.StatusCode != http.StatusForbidden || body["error"] != "not_owner" {
			t.Errorf("%s by a stranger: status %d body %v, want 403 not_owner", ep.path, resp.StatusCode, body)
		}
	}
	if row, _ := h.server.Store.GetBinding(hashOf("tok-A")); row == nil {
		t.Fatal("the binding must survive a stranger's attempt")
	}
}

func TestUnknownPushTypeNeverReachesAPNs(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")
	before := len(h.apns.sent)

	push := map[string]any{"token": "tok-A", "push_type": "tenant-chosen", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}
	resp, _ := h.do("POST", "/v1/push", push, h.creds.Bearer())
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
	if len(h.apns.sent) != before {
		t.Error("a push type with no topic must never reach APNs")
	}
}

func TestVouchAlwaysAnswers202(t *testing.T) {
	h := newHarness(t)
	// A dead token: APNs refuses, but the caller must not be able to tell.
	h.apns.reply = func(*http.Request) (int, string) { return 410, "Unregistered" }

	resp, _ := h.do("POST", "/v1/vouch", map[string]string{"token": "tok-DEAD"}, h.creds.Bearer())
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("status = %d, want 202 — otherwise this endpoint is a token-liveness oracle", resp.StatusCode)
	}
}

func TestUnknownChallengePurposeIsRejected(t *testing.T) {
	h := newHarness(t)
	resp, _ := h.do("POST", "/v1/challenges", map[string]string{"purpose": "whatever"}, h.creds.Bearer())
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", resp.StatusCode)
	}
}

func TestBindingCapRefusesNewTokensButNotReclaims(t *testing.T) {
	h := newHarness(t)
	h.server.BindingCap = 1

	bindStart(t, h, "tok-A")

	c := h.claimFor("tok-B", "tok-B", "start", "", h.challenge("assertion"))
	resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer())
	if resp.StatusCode != http.StatusTooManyRequests || body["error"] != "binding_limit" {
		t.Fatalf("over-cap claim: status %d body %v, want 429 binding_limit", resp.StatusCode, body)
	}

	// Re-claiming a token the tenant already holds must not be refused for
	// capacity, or a tenant at its cap can never renew what it owns.
	bindStart(t, h, "tok-A")
}

func hashOf(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hexOf(sum[:])
}

func hexOf(b []byte) string {
	const hextable = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, v := range b {
		out[i*2] = hextable[v>>4]
		out[i*2+1] = hextable[v&0x0f]
	}
	return string(out)
}

// TestABindingCannotCarryAPushTypeItsKindDoesNotOwn is the regression test for a reproduced
// tenant-isolation break.
//
// Canopy cannot tell a device token from a push-to-start token by value — only the claimant's own
// binding_kind says which it is. R0 binds start tokens with NO vouch, because start tokens
// genuinely cannot receive the silent push a vouch rides on. So an attacker who holds a victim's
// DEVICE token declares it a "start" token, binds it unvouched, and then pushes an `alert` — whose
// topic is the bare bundle id, the correct topic for a device token — and APNs delivers an
// attacker-authored banner to the victim's phone.
//
// NeedsVouch answers "what did the claimant CALL this token?" when the question is "can this token
// receive the push that proves reachability?". The label is now worth only the capability it names.
func TestABindingCannotCarryAPushTypeItsKindDoesNotOwn(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A") // the victim's device token, declared "start" by the attacker

	// An alert resolves to the bare bundle id — the device-token topic. This is the push that
	// reached the victim's lock screen before the gate existed.
	push := map[string]any{"token": "tok-A", "push_type": "alert", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}
	resp, body := h.do("POST", "/v1/push", push, h.creds.Bearer())

	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d body %v, want 403; a start binding must not be able to send an alert",
			resp.StatusCode, body)
	}
	if body["error"] != "push_type_not_permitted" {
		t.Errorf("error = %v, want push_type_not_permitted", body["error"])
	}
}

func TestEachKindCarriesOnlyItsOwnPushTypes(t *testing.T) {
	// The whole table, so a later edit cannot quietly widen one kind.
	cases := []struct {
		kind      binding.Kind
		pushType  string
		permitted bool
	}{
		{binding.KindDevice, "alert", true},
		{binding.KindDevice, "background", true}, // the vouch itself rides on this
		{binding.KindDevice, "liveactivity", false},
		{binding.KindStart, "liveactivity", true},
		{binding.KindStart, "alert", false}, // the reproduced attack
		{binding.KindStart, "background", false},
		{binding.KindActivity, "liveactivity", true},
		{binding.KindActivity, "alert", false},
		{binding.KindActivity, "background", false},
	}
	for _, c := range cases {
		if got := c.kind.Permits(c.pushType); got != c.permitted {
			t.Errorf("%s.Permits(%q) = %v, want %v", c.kind, c.pushType, got, c.permitted)
		}
	}
}

// TestAForeignPushDoesNotSpendTheOwnersRateBudget covers a starvation path.
//
// The per-token bucket is keyed by token, not by tenant. Charged before the ownership check, any
// enrolled tenant holding a leaked copy of a victim's token could drain it with requests that all
// returned 403 — six a minute starves the real owner into 429, freezing their card, and because
// the lease is only renewed by a delivered push the binding stops being refreshed as well. The
// victim sees only their own requests failing.
func TestAForeignPushDoesNotSpendTheOwnersRateBudget(t *testing.T) {
	h := newHarness(t)
	bindStart(t, h, "tok-A")

	other, err := h.server.Tenants.Enroll("", "", t0)
	if err != nil {
		t.Fatalf("Enroll: %v", err)
	}
	push := map[string]any{"token": "tok-A", "push_type": "liveactivity", "priority": 10, "payload": json.RawMessage(`{"aps":{}}`)}

	// Spend well past the per-token budget from the wrong tenant.
	for i := 0; i < 20; i++ {
		resp, body := h.do("POST", "/v1/push", push, other.Bearer())
		if resp.StatusCode != http.StatusForbidden || body["error"] != "not_owner" {
			t.Fatalf("attempt %d: status %d body %v, want 403 not_owner", i, resp.StatusCode, body)
		}
	}

	// The owner must still be able to push.
	resp, body := h.do("POST", "/v1/push", push, h.creds.Bearer())
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("owner push: status %d body %v, want 200 — a refused request must cost the refuser",
			resp.StatusCode, body)
	}
}

// TestReattestRequiredReachesTheClientVerbatim covers the branch that lets an install recover.
//
// keystore returns ErrReattestRequired when Canopy holds no public key for the key id a claim
// asserts with — the honest cause is a Canopy restore predating the key, not an attack. The handler
// must say so by name: Trellis forwards the reason verbatim and the app acts only on the exact
// string "reattest_required", discarding its key so the next claim carries a fresh attestation.
//
// Collapsed to the generic "attestation_invalid", the app retries an assertion against a key the
// relay has never seen, forever. The branch existed with no test at all: deleting it left the suite
// green, because the verifier stub could only ever produce one kind of error.
func TestReattestRequiredReachesTheClientVerbatim(t *testing.T) {
	h := newHarness(t)
	h.server.Attest = allowAttest{err: keystore.ErrReattestRequired}

	c := h.claimFor("tok-A", "tok-A", "start", "", h.challenge("assertion"))
	resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer())

	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d body %v, want 403", resp.StatusCode, body)
	}
	if body["error"] != "reattest_required" {
		t.Fatalf("error = %v, want reattest_required; the app matches on that exact string and "+
			"anything else leaves it asserting against a key the relay does not have", body["error"])
	}
}

func TestAGenuinelyInvalidAttestationIsStillReportedAsSuch(t *testing.T) {
	// The other side of the same branch: a real verification failure must NOT be softened into an
	// invitation to re-attest, which would let a forged proof ask for a fresh start.
	h := newHarness(t)
	h.server.Attest = allowAttest{fail: true}

	c := h.claimFor("tok-A", "tok-A", "start", "", h.challenge("assertion"))
	resp, body := h.do("POST", "/v1/claims", c, h.creds.Bearer())

	if resp.StatusCode != http.StatusForbidden || body["error"] == "reattest_required" {
		t.Fatalf("status %d body %v, want 403 with a non-reattest reason", resp.StatusCode, body)
	}
}
