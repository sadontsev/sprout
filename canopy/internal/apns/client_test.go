package apns

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeAPNs records what it was sent and answers per-environment.
type fakeAPNs struct {
	mu       sync.Mutex
	requests []recorded
	reply    func(env Environment, r *http.Request) (int, string)
}

type recorded struct {
	env      Environment
	path     string
	topic    string
	pushType string
	priority string
	auth     string
	body     string
}

func newFake(t *testing.T, reply func(env Environment, r *http.Request) (int, string)) (*fakeAPNs, *Client) {
	t.Helper()
	f := &fakeAPNs{reply: reply}

	handler := func(env Environment) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			buf := make([]byte, r.ContentLength)
			_, _ = r.Body.Read(buf)
			f.mu.Lock()
			f.requests = append(f.requests, recorded{
				env:      env,
				path:     r.URL.Path,
				topic:    r.Header.Get("apns-topic"),
				pushType: r.Header.Get("apns-push-type"),
				priority: r.Header.Get("apns-priority"),
				auth:     r.Header.Get("authorization"),
				body:     string(buf),
			})
			f.mu.Unlock()

			status, reason := f.reply(env, r)
			w.WriteHeader(status)
			if reason != "" {
				_, _ = w.Write([]byte(`{"reason":"` + reason + `"}`))
			}
		}
	}

	sandboxSrv := httptest.NewServer(handler(Sandbox))
	prodSrv := httptest.NewServer(handler(Production))
	t.Cleanup(sandboxSrv.Close)
	t.Cleanup(prodSrv.Close)

	sandKey, _ := testKey(t)
	prodKey, _ := testKey(t)
	sandSigner, _ := NewSigner("SANDKEY", "TEAM", sandKey)
	prodSigner, _ := NewSigner("PRODKEY", "TEAM", prodKey)

	c, err := NewClient(bundleID, sandSigner, prodSigner)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	c.SetHostForTest(Sandbox, sandboxSrv.URL)
	c.SetHostForTest(Production, prodSrv.URL)
	return f, c
}

func livePush() Push {
	return Push{
		Token:       "abc123",
		Environment: Production,
		Type:        LiveActivity,
		Priority:    10,
		Payload:     []byte(`{"aps":{"event":"update"}}`),
	}
}

func TestSendSetsTheHeadersAPNsRequires(t *testing.T) {
	f, c := newFake(t, func(Environment, *http.Request) (int, string) { return 200, "" })

	res, env := c.Send(context.Background(), livePush(), tNow)
	if res.Outcome != Delivered || res.APNsStatus != 200 {
		t.Fatalf("Result = %+v, want delivered 200", res)
	}
	if env != Production {
		t.Errorf("environment = %s, want production", env)
	}

	got := f.requests[0]
	if got.path != "/3/device/abc123" {
		t.Errorf("path = %q", got.path)
	}
	if got.topic != "com.mvks5.bambu.push-type.liveactivity" {
		t.Errorf("apns-topic = %q", got.topic)
	}
	if got.pushType != "liveactivity" {
		t.Errorf("apns-push-type = %q", got.pushType)
	}
	if got.priority != "10" {
		t.Errorf("apns-priority = %q", got.priority)
	}
	if !strings.HasPrefix(got.auth, "bearer ") {
		t.Errorf("authorization = %q, want a bearer provider token", got.auth)
	}
}

func TestPriorityIsClampedOnTheWire(t *testing.T) {
	f, c := newFake(t, func(Environment, *http.Request) (int, string) { return 200, "" })

	p := livePush()
	p.Priority = 7 // a caller bug, or a hostile tenant
	c.Send(context.Background(), p, tNow)

	if got := f.requests[0].priority; got != "5" {
		t.Errorf("apns-priority = %q, want 5 — an unclamped priority would let a caller burn the device's Live Activity budget", got)
	}
}

func TestBadDeviceTokenRetriesTheOtherGatewayAndReportsTheCorrection(t *testing.T) {
	f, c := newFake(t, func(env Environment, _ *http.Request) (int, string) {
		if env == Production {
			return 400, "BadDeviceToken"
		}
		return 200, ""
	})

	res, env := c.Send(context.Background(), livePush(), tNow)
	if res.Outcome != Delivered || res.APNsStatus != 200 {
		t.Fatalf("Result = %+v, want the sandbox retry to succeed", res)
	}
	if env != Sandbox {
		t.Errorf("corrected environment = %s, want sandbox — the caller must be able to persist the correction", env)
	}

	if len(f.requests) != 2 {
		t.Fatalf("made %d requests, want 2", len(f.requests))
	}
	if f.requests[0].env != Production || f.requests[1].env != Sandbox {
		t.Error("the retry must go to the other gateway")
	}
	if f.requests[0].auth == f.requests[1].auth {
		t.Error("the retry must swap the signing key as well as the host: a production JWT " +
			"against the sandbox gateway returns InvalidProviderToken and never converges")
	}
}

func TestBadDeviceTokenOnBothGatewaysReportsTheOriginalResult(t *testing.T) {
	_, c := newFake(t, func(Environment, *http.Request) (int, string) {
		return 400, "BadDeviceToken"
	})

	res, env := c.Send(context.Background(), livePush(), tNow)
	if !res.TokenIsDead() {
		t.Errorf("Result = %+v, want a dead token once both gateways refuse", res)
	}
	if env != Production {
		t.Errorf("environment = %s, want the original when the retry fails too", env)
	}
}

func TestOversizedPayloadIsRefusedWithoutContactingAPNs(t *testing.T) {
	f, c := newFake(t, func(Environment, *http.Request) (int, string) { return 200, "" })

	p := livePush()
	p.Payload = make([]byte, MaxPayloadBytes+1)
	res, _ := c.Send(context.Background(), p, tNow)

	if res.Outcome != Refused {
		t.Errorf("Outcome = %s, want refused", res.Outcome)
	}
	if res.TokenIsDead() {
		t.Error("a refusal must never read as a dead token")
	}
	if len(f.requests) != 0 {
		t.Error("an oversized payload must not be forwarded")
	}
}

func TestUnknownPushTypeIsRefusedWithoutContactingAPNs(t *testing.T) {
	f, c := newFake(t, func(Environment, *http.Request) (int, string) { return 200, "" })

	p := livePush()
	p.Type = PushType("tenant-supplied")
	res, _ := c.Send(context.Background(), p, tNow)

	if res.Outcome != Refused {
		t.Errorf("Outcome = %s, want refused", res.Outcome)
	}
	if len(f.requests) != 0 {
		t.Error("a push type with no topic must never reach APNs")
	}
}

func TestTransportFailureIsNotAnAPNsStatus(t *testing.T) {
	sandKey, _ := testKey(t)
	prodKey, _ := testKey(t)
	ss, _ := NewSigner("SANDKEY", "TEAM", sandKey)
	ps, _ := NewSigner("PRODKEY", "TEAM", prodKey)
	c, _ := NewClient(bundleID, ss, ps)
	// A port nothing is listening on: the request cannot complete.
	c.SetHostForTest(Production, "http://127.0.0.1:1")

	res, _ := c.Send(context.Background(), livePush(), tNow)
	if res.Outcome != Transport {
		t.Fatalf("Outcome = %s, want transport", res.Outcome)
	}
	if res.APNsStatus != 0 {
		t.Errorf("APNsStatus = %d, want 0 — a failed request says nothing about the token", res.APNsStatus)
	}
	if res.TokenIsDead() {
		t.Error("a transport failure must never delete a registration")
	}
}

func TestNewClientRequiresBothSigners(t *testing.T) {
	keyPEM, _ := testKey(t)
	s, _ := NewSigner("K", "T", keyPEM)

	if _, err := NewClient(bundleID, nil, s); err == nil {
		t.Error("a missing sandbox signer must be rejected: the gateway retry needs both")
	}
	if _, err := NewClient(bundleID, s, nil); err == nil {
		t.Error("a missing production signer must be rejected")
	}
	if _, err := NewClient("", s, s); err == nil {
		t.Error("an empty bundle id must be rejected: it is what the topic table is built from")
	}
}
