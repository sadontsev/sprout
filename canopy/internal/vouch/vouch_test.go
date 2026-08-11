package vouch

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/mvks5/canopy/internal/apns"
	"github.com/mvks5/canopy/internal/store"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

// captureSender records the pushes it is asked to send and can be told to fail,
// which is how the "never leaks the APNs outcome" property gets tested.
type captureSender struct {
	sent []apns.Push
	res  apns.Result
}

func (c *captureSender) Send(_ context.Context, p apns.Push, _ time.Time) (apns.Result, apns.Environment) {
	c.sent = append(c.sent, p)
	if c.res.Outcome == "" {
		return apns.Result{Outcome: apns.Delivered, APNsStatus: 200}, p.Environment
	}
	return c.res, p.Environment
}

// nonceOf extracts the nonce the service put on the wire, which is the only
// place a test can see it — by design it is never returned to the caller.
func nonceOf(t *testing.T, p apns.Push) string {
	t.Helper()
	var body struct {
		APS        map[string]any `json:"aps"`
		VouchNonce string         `json:"vouch_nonce"`
	}
	if err := json.Unmarshal(p.Payload, &body); err != nil {
		t.Fatalf("payload is not JSON: %v", err)
	}
	if body.APS["content-available"] != float64(1) {
		t.Errorf("aps = %v, want content-available 1 — a vouch must be silent", body.APS)
	}
	return body.VouchNonce
}

func newService(t *testing.T) (*Service, *captureSender) {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	sender := &captureSender{}
	return &Service{Store: s, APNs: sender}, sender
}

func TestMintSendsASilentPushAndVerifyAcceptsTheEchoedNonce(t *testing.T) {
	svc, sender := newService(t)

	if err := svc.Mint(context.Background(), "tok-A", "tenant-1", apns.Production, t0); err != nil {
		t.Fatalf("Mint: %v", err)
	}
	if len(sender.sent) != 1 {
		t.Fatalf("sent %d pushes, want 1", len(sender.sent))
	}
	p := sender.sent[0]
	if p.Type != apns.Background {
		t.Errorf("push type = %q, want background", p.Type)
	}
	if p.Token != "tok-A" {
		t.Errorf("push went to %q, want the token being vouched", p.Token)
	}

	nonce := nonceOf(t, p)
	if nonce == "" {
		t.Fatal("no nonce in the push payload")
	}

	ok, err := svc.Verify("tok-A", nonce, "tenant-1", t0.Add(time.Minute))
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !ok {
		t.Fatal("the echoed nonce must verify")
	}
}

func TestVouchIsSingleUse(t *testing.T) {
	svc, sender := newService(t)
	svc.Mint(context.Background(), "tok-A", "tenant-1", apns.Production, t0)
	nonce := nonceOf(t, sender.sent[0])

	if ok, _ := svc.Verify("tok-A", nonce, "tenant-1", t0); !ok {
		t.Fatal("first use must succeed")
	}
	if ok, _ := svc.Verify("tok-A", nonce, "tenant-1", t0); ok {
		t.Fatal("a replayed nonce must not verify: it would prove reachability once and authorise binding forever")
	}
}

func TestVouchIsScopedToTheTokenAndTheTenant(t *testing.T) {
	svc, sender := newService(t)
	svc.Mint(context.Background(), "tok-A", "tenant-1", apns.Production, t0)
	nonce := nonceOf(t, sender.sent[0])

	if ok, _ := svc.Verify("tok-B", nonce, "tenant-1", t0); ok {
		t.Error("a nonce for one token must not vouch another — this is the whole point of per-token vouching")
	}
	if ok, _ := svc.Verify("tok-A", nonce, "tenant-2", t0); ok {
		t.Error("a nonce issued to one tenant must not satisfy another tenant's claim")
	}
	// The real nonce still works: the failed attempts consumed nothing.
	if ok, _ := svc.Verify("tok-A", nonce, "tenant-1", t0); !ok {
		t.Error("mis-scoped attempts must not consume the vouch")
	}
}

func TestVouchExpires(t *testing.T) {
	svc, sender := newService(t)
	svc.Mint(context.Background(), "tok-A", "tenant-1", apns.Production, t0)
	nonce := nonceOf(t, sender.sent[0])

	if ok, _ := svc.Verify("tok-A", nonce, "tenant-1", t0.Add(TTL+time.Second)); ok {
		t.Error("a nonce past its TTL must not verify")
	}
}

func TestEmptyNonceNeverVerifies(t *testing.T) {
	svc, _ := newService(t)
	if ok, _ := svc.Verify("tok-A", "", "tenant-1", t0); ok {
		t.Error("an absent nonce must not verify")
	}
}

func TestMintIsRateLimitedGloballyPerToken(t *testing.T) {
	svc, sender := newService(t)

	// Different tenants, same victim token: the cap must still bite, or an
	// attacker enrolls more tenants and wakes the victim's app at will.
	for i := 0; i < MaxPerTokenPerHour; i++ {
		tenant := "tenant-" + string(rune('a'+i))
		if err := svc.Mint(context.Background(), "tok-A", tenant, apns.Production, t0); err != nil {
			t.Fatalf("Mint %d: %v", i, err)
		}
	}
	err := svc.Mint(context.Background(), "tok-A", "tenant-z", apns.Production, t0)
	if !errors.Is(err, ErrRateLimited) {
		t.Fatalf("err = %v, want ErrRateLimited once the per-token cap is reached", err)
	}
	if len(sender.sent) != MaxPerTokenPerHour {
		t.Errorf("sent %d pushes, want the cap %d — a refused mint must not push", len(sender.sent), MaxPerTokenPerHour)
	}

	// A different token is unaffected.
	if err := svc.Mint(context.Background(), "tok-B", "tenant-z", apns.Production, t0); err != nil {
		t.Errorf("a different token must not be rate limited: %v", err)
	}
	// And the window slides.
	if err := svc.Mint(context.Background(), "tok-A", "tenant-z", apns.Production, t0.Add(RateWindow+time.Minute)); err != nil {
		t.Errorf("the cap must be a sliding window: %v", err)
	}
}

func TestMintHidesTheAPNsOutcome(t *testing.T) {
	svc, sender := newService(t)
	sender.res = apns.Result{Outcome: apns.Delivered, APNsStatus: 410} // a dead token

	if err := svc.Mint(context.Background(), "tok-A", "tenant-1", apns.Production, t0); err != nil {
		t.Fatalf("Mint must not surface the APNs outcome, got %v — the caller answers 202 "+
			"either way so this endpoint cannot be used as a token-liveness oracle", err)
	}

	sender.res = apns.Result{Outcome: apns.Transport}
	if err := svc.Mint(context.Background(), "tok-A", "tenant-1", apns.Production, t0); err != nil {
		t.Fatalf("a transport failure must not surface either: %v", err)
	}
}

func TestPurgeExpiredVouches(t *testing.T) {
	svc, sender := newService(t)
	svc.Mint(context.Background(), "tok-A", "tenant-1", apns.Production, t0)
	nonce := nonceOf(t, sender.sent[0])

	if err := svc.Store.PurgeExpiredVouches(t0.Add(TTL + time.Second)); err != nil {
		t.Fatalf("PurgeExpiredVouches: %v", err)
	}
	if ok, _ := svc.Verify("tok-A", nonce, "tenant-1", t0); ok {
		t.Error("a purged vouch must be gone")
	}
}
