package fraud

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeKeys records what the sweep did, so the tests assert on decisions rather than on SQL.
type fakeKeys struct {
	due     []KeyRecord
	dueErr  error
	limit   int
	risks   map[string]recordedRisk
	defers  map[string]time.Time
	putErr  error
	putSeen int
}

type recordedRisk struct {
	metric    int
	hasMetric bool
	receipt   []byte
	notBefore time.Time
}

func newFakeKeys(due ...KeyRecord) *fakeKeys {
	return &fakeKeys{
		due:    due,
		risks:  map[string]recordedRisk{},
		defers: map[string]time.Time{},
	}
}

func (f *fakeKeys) AttestKeysDueForRedemption(now time.Time, limit int) ([]KeyRecord, error) {
	f.limit = limit
	return f.due, f.dueErr
}

func (f *fakeKeys) PutAttestRisk(keyID string, metric int, hasMetric bool, receipt []byte, notBefore, now time.Time) error {
	f.putSeen++
	if f.putErr != nil {
		return f.putErr
	}
	f.risks[keyID] = recordedRisk{metric, hasMetric, receipt, notBefore}
	return nil
}

func (f *fakeKeys) DeferAttestRedemption(keyID string, until, now time.Time) error {
	f.defers[keyID] = until
	return nil
}

// appleServing stands in for Apple, answering every redemption with the same receipt.
func appleServing(t *testing.T, receipt []byte) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(base64.StdEncoding.EncodeToString(receipt)))
	}))
}

func sweeperFor(t *testing.T, keys Keys, url string) *Sweeper {
	t.Helper()
	c, err := NewClient(url, "K", "I", testKeyPEM(t))
	if err != nil {
		t.Fatal(err)
	}
	return &Sweeper{Keys: keys, Client: c}
}

var testNow = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

func TestAnUnconfiguredSweepDoesNothingAndSucceeds(t *testing.T) {
	// The supported way to run Canopy without a DeviceCheck key. It must not error, must not
	// touch the store, and must not stop the process — the metric refines a bound that already
	// holds, so its absence degrades the signal and nothing else.
	keys := newFakeKeys(KeyRecord{KeyID: "k1"})
	s := &Sweeper{Keys: keys, Client: nil}

	res, err := s.Run(context.Background(), testNow)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Considered != 0 || len(keys.risks) != 0 || len(keys.defers) != 0 {
		t.Errorf("an unconfigured sweep must not touch anything, got %+v", res)
	}
}

func TestASuccessfulRedemptionRecordsTheMetricAndTheRefreshedReceipt(t *testing.T) {
	receipt := redeemedReceipt(t, 4)
	srv := appleServing(t, receipt)
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Environment: "production", Receipt: []byte("stored")})
	res, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if res.Redeemed != 1 || res.Deferred != 0 {
		t.Errorf("result = %+v, want one redeemed", res)
	}
	got := keys.risks["k1"]
	if !got.hasMetric || got.metric != 4 {
		t.Errorf("metric = %d (has %v), want 4", got.metric, got.hasMetric)
	}
	if string(got.receipt) == "stored" {
		t.Error("the refreshed receipt must replace the stored one; keeping the original makes " +
			"every later redemption fail")
	}
	want := time.Date(2026, 8, 12, 9, 0, 0, 0, time.UTC)
	if !got.notBefore.Equal(want) {
		t.Errorf("notBefore = %v, want Apple's stated %v", got.notBefore, want)
	}
}

func TestACrossingDeviceAlerts(t *testing.T) {
	srv := appleServing(t, redeemedReceipt(t, SuspiciousKeyCount+1))
	defer srv.Close()

	var alerted []string
	s := sweeperFor(t, newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")}), srv.URL)
	s.Alert = func(keyID string, a Assessment) { alerted = append(alerted, keyID) }

	res, err := s.Run(context.Background(), testNow)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Suspicious != 1 {
		t.Errorf("Suspicious = %d, want 1", res.Suspicious)
	}
	if len(alerted) != 1 || alerted[0] != "k1" {
		t.Errorf("alerted = %v, want [k1]", alerted)
	}
}

func TestAnHonestDeviceDoesNotAlert(t *testing.T) {
	srv := appleServing(t, redeemedReceipt(t, 1))
	defer srv.Close()

	var alerted int
	s := sweeperFor(t, newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")}), srv.URL)
	s.Alert = func(string, Assessment) { alerted++ }

	if _, err := s.Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if alerted != 0 {
		t.Errorf("alerted %d times for a single-key device", alerted)
	}
}

func TestTheSweepPassesEachKeysOwnEnvironmentThrough(t *testing.T) {
	// The recurring shape this repo names explicitly: Canopy's own environment and the environment
	// a key attested in are two different questions. A development receipt sent to the production
	// host answers 400 with nothing that says why, so the per-key value has to reach the client.
	srv := appleServing(t, redeemedReceipt(t, 1))
	defer srv.Close()

	keys := newFakeKeys(
		KeyRecord{KeyID: "dev", Environment: "development", Receipt: []byte("r")},
		KeyRecord{KeyID: "prod", Environment: "production", Receipt: []byte("r")},
	)
	s := sweeperFor(t, keys, srv.URL)
	// Record what environment each redemption resolved to, without leaving the test process.
	var resolved []string
	s.Client.HTTP = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		resolved = append(resolved, r.URL.String())
		return http.DefaultTransport.RoundTrip(r)
	})}

	if _, err := s.Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if len(keys.risks) != 2 {
		t.Fatalf("both keys should have been assessed, got %v", keys.risks)
	}
	// With Host pinned to the test server both resolve there — that is the pin doing its job. The
	// environment-driven choice itself is asserted in TestHostResolutionPrefersAnExplicitPin.
	if len(resolved) != 2 {
		t.Errorf("expected two redemptions, got %v", resolved)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestHostResolutionPrefersAnExplicitPin(t *testing.T) {
	// Unpinned is the normal deployment: one Canopy serves TestFlight and development installs at
	// once, so the host has to follow each key rather than a process-wide setting.
	c := &Client{}
	if got := c.hostFor("development"); got != DevelopmentHost {
		t.Errorf("unpinned development -> %q, want %q", got, DevelopmentHost)
	}
	if got := c.hostFor("production"); got != ProductionHost {
		t.Errorf("unpinned production -> %q, want %q", got, ProductionHost)
	}

	pinned := &Client{Host: "https://example.test/redeem"}
	if got := pinned.hostFor("development"); got != "https://example.test/redeem" {
		t.Errorf("a pinned host must win, got %q", got)
	}
}

func TestThrottlingDefersWithoutRecordingAMetric(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	res, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if res.Deferred != 1 || res.Redeemed != 0 {
		t.Errorf("result = %+v, want one deferred", res)
	}
	if len(keys.risks) != 0 {
		t.Error("a throttled redemption produced no answer and must record none")
	}
	if got := keys.defers["k1"]; !got.Equal(testNow.Add(ThrottleBackoff)) {
		t.Errorf("deferred to %v, want %v", got, testNow.Add(ThrottleBackoff))
	}
}

func TestAFailingReceiptIsBackedOffRatherThanRetriedForever(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	if _, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}

	if got := keys.defers["k1"]; !got.Equal(testNow.Add(FailureBackoff)) {
		t.Errorf("deferred to %v, want %v — a permanently unreadable receipt retried every pass "+
			"crowds out the keys that would answer", got, testNow.Add(FailureBackoff))
	}
}

func TestOneBadKeyDoesNotStopThePass(t *testing.T) {
	// The point of the sweep is the keys that answer. A single unreadable receipt aborting the run
	// would let one broken row hide every other device's metric indefinitely.
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		if n == 1 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Write([]byte(base64.StdEncoding.EncodeToString(redeemedReceipt(t, 2))))
	}))
	defer srv.Close()

	keys := newFakeKeys(
		KeyRecord{KeyID: "broken", Receipt: []byte("r")},
		KeyRecord{KeyID: "fine", Receipt: []byte("r")},
	)
	res, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if res.Considered != 2 || res.Redeemed != 1 || res.Deferred != 1 {
		t.Errorf("result = %+v, want both considered with one of each outcome", res)
	}
	if _, ok := keys.risks["fine"]; !ok {
		t.Error("the healthy key must still have been assessed")
	}
}

func TestAReceiptFromAnotherAppIsRefused(t *testing.T) {
	// It parses cleanly and carries a real number — about a different app. Recording it would
	// attribute a stranger's key count to this device.
	srv := appleServing(t, redeemedReceipt(t, 99))
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	s := sweeperFor(t, keys, srv.URL)
	s.AppID = "OTHERTEAM.com.example.other"
	var alerted int
	s.Alert = func(string, Assessment) { alerted++ }

	res, err := s.Run(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys.risks) != 0 {
		t.Error("a foreign receipt must not be recorded")
	}
	if alerted != 0 {
		t.Error("a foreign receipt's count must not raise an alert about this device")
	}
	if res.Deferred != 1 {
		t.Errorf("result = %+v, want it deferred", res)
	}
}

func TestAMatchingAppIdIsAccepted(t *testing.T) {
	srv := appleServing(t, redeemedReceipt(t, 2))
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	s := sweeperFor(t, keys, srv.URL)
	s.AppID = "TEAMID1234.com.example.sprout"

	if _, err := s.Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if _, ok := keys.risks["k1"]; !ok {
		t.Error("a receipt for this very app must be recorded")
	}
}

func TestAnAttestReceiptIsRecordedWithoutAMetric(t *testing.T) {
	// Redeeming an ATTEST receipt is how the first metric is ever obtained, but Apple may answer
	// with one that still carries none. Recording a zero would mark the device clean forever.
	attest := buildReceipt(t, []receiptAttribute{
		strAttr(fieldReceiptType, TypeAttest),
		strAttr(fieldNotBefore, "2026-08-12T09:00:00Z"),
	})
	srv := appleServing(t, attest)
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	if _, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}

	got := keys.risks["k1"]
	if got.hasMetric {
		t.Error("an ATTEST receipt carries no metric; recording one would invent an answer")
	}
	if got.notBefore.IsZero() {
		t.Error("the refreshed receipt's not-before must still be honoured")
	}
}

func TestAMissingNotBeforeFallsBackRatherThanRetryingImmediately(t *testing.T) {
	// Without a fallback the key is due again on the very next pass, which guarantees a 429.
	receipt := buildReceipt(t, []receiptAttribute{
		strAttr(fieldReceiptType, TypeReceipt),
		numAttr(fieldRiskMetric, 3),
	})
	srv := appleServing(t, receipt)
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	if _, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}

	if got := keys.risks["k1"].notBefore; !got.Equal(testNow.Add(ThrottleBackoff)) {
		t.Errorf("notBefore = %v, want the fallback %v", got, testNow.Add(ThrottleBackoff))
	}
}

func TestAPastNotBeforeIsAlsoPushedForward(t *testing.T) {
	receipt := buildReceipt(t, []receiptAttribute{
		strAttr(fieldReceiptType, TypeReceipt),
		numAttr(fieldRiskMetric, 3),
		strAttr(fieldNotBefore, "2020-01-01T00:00:00Z"),
	})
	srv := appleServing(t, receipt)
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	if _, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}

	if got := keys.risks["k1"].notBefore; !got.After(testNow) {
		t.Errorf("notBefore = %v; a stale date must not make the key due on every pass", got)
	}
}

func TestTheBatchIsBounded(t *testing.T) {
	keys := newFakeKeys()
	s := sweeperFor(t, keys, "http://127.0.0.1:1")
	if _, err := s.Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if keys.limit != DefaultBatch {
		t.Errorf("limit = %d, want DefaultBatch %d", keys.limit, DefaultBatch)
	}

	s.Batch = 5
	if _, err := s.Run(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if keys.limit != 5 {
		t.Errorf("limit = %d, want the configured 5", keys.limit)
	}
}

func TestAFailureToListIsFatalToThePass(t *testing.T) {
	keys := newFakeKeys()
	keys.dueErr = errors.New("database is gone")
	s := sweeperFor(t, keys, "http://127.0.0.1:1")

	if _, err := s.Run(context.Background(), testNow); err == nil {
		t.Fatal("want the listing error surfaced; silently sweeping nothing reads as 'all clear'")
	}
}

func TestCancellationStopsMidPass(t *testing.T) {
	srv := appleServing(t, redeemedReceipt(t, 1))
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "a", Receipt: []byte("r")}, KeyRecord{KeyID: "b", Receipt: []byte("r")})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := sweeperFor(t, keys, srv.URL).Run(ctx, testNow); err == nil {
		t.Fatal("want the cancellation surfaced")
	}
}

func TestAStoreWriteFailureDoesNotCountAsRedeemed(t *testing.T) {
	srv := appleServing(t, redeemedReceipt(t, 2))
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "k1", Receipt: []byte("r")})
	keys.putErr = errors.New("disk full")

	res, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if res.Redeemed != 0 {
		t.Error("an assessment that was not persisted must not be reported as redeemed")
	}
}

func TestAnUnauthorizedTokenStopsThePassAndDefersNothing(t *testing.T) {
	// The real failure this was built wrong for. Apple checks the token BEFORE it reads the
	// receipt, so a key without the DeviceCheck service ticked answers 401 for every receipt
	// identically. Charging that to the receipts — deferring each for a day — turns a
	// two-minute configuration fix into a day of silence in which nothing looks wrong, and the
	// operator's next sweep reports "considered 0" as if all were healthy.
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	keys := newFakeKeys(
		KeyRecord{KeyID: "a", Receipt: []byte("r")},
		KeyRecord{KeyID: "b", Receipt: []byte("r")},
		KeyRecord{KeyID: "c", Receipt: []byte("r")},
	)
	_, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow)

	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized surfaced to the caller", err)
	}
	if len(keys.defers) != 0 {
		t.Errorf("deferred %v; an auth failure is not the receipts' fault and must leave them due",
			keys.defers)
	}
	if len(keys.risks) != 0 {
		t.Error("nothing was assessed, so nothing may be recorded")
	}
	if hits != 1 {
		t.Errorf("made %d requests; the pass must stop at the first 401 rather than replaying the "+
			"same rejection for every remaining key", hits)
	}
}

func TestAForbiddenIsTreatedTheSameAsUnauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	keys := newFakeKeys(KeyRecord{KeyID: "a", Receipt: []byte("r")})
	_, err := sweeperFor(t, keys, srv.URL).Run(context.Background(), testNow)

	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized", err)
	}
	if len(keys.defers) != 0 {
		t.Errorf("deferred %v, want none", keys.defers)
	}
}

func TestTheUnauthorizedErrorNamesTheLikelyCause(t *testing.T) {
	// Apple returns an EMPTY body on 401, so the message is the only diagnosis anyone gets.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, "K", "TEAMID1234", testKeyPEM(t))
	_, err := c.Redeem(context.Background(), []byte("r"), "production", testNow)
	if err == nil {
		t.Fatal("want an error")
	}
	// Both causes must be named. Propagation is listed first because it is the one that occurs on
	// the day someone sets this up, looks identical to a wrong key from the outside, and needs no
	// action at all — an operator told only to check the service will go and re-tick a box that
	// was already ticked.
	for _, want := range []string{"24h", "DeviceCheck service"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("err = %v; missing %q, and Apple's own body is empty", err, want)
		}
	}
}
