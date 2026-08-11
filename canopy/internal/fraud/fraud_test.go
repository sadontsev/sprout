package fraud

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// --- fixtures ---

// buildReceipt assembles a CMS SignedData in the shape Apple issues, so the parser is exercised
// against the structure rather than against a convenience of its own. The signature is absent by
// design: Canopy does not verify it (see the note in fraud.go), so a fixture that carried one would
// assert a property nothing checks.
func buildReceipt(t *testing.T, attrs []receiptAttribute) []byte {
	t.Helper()

	var payload []byte
	for _, a := range attrs {
		der, err := asn1.Marshal(a)
		if err != nil {
			t.Fatalf("marshal attribute %d: %v", a.Type, err)
		}
		payload = append(payload, der...)
	}
	// SET OF, the way Apple encapsulates it.
	set, err := asn1.Marshal(asn1.RawValue{Class: 0, Tag: 17, IsCompound: true, Bytes: payload})
	if err != nil {
		t.Fatalf("marshal set: %v", err)
	}

	ci := contentInfo{
		ContentType: asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 2},
		Content: signedData{
			Version:          1,
			DigestAlgorithms: asn1.RawValue{Class: 0, Tag: 17, IsCompound: true},
			EncapContentInfo: encapContentInfo{
				EContentType: asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 1},
				EContent:     set,
			},
			SignerInfos: asn1.RawValue{Class: 0, Tag: 17, IsCompound: true},
		},
	}
	der, err := asn1.Marshal(ci)
	if err != nil {
		t.Fatalf("marshal contentInfo: %v", err)
	}
	return der
}

func strAttr(typ int, s string) receiptAttribute {
	der, _ := asn1.Marshal(s)
	return receiptAttribute{Type: typ, Version: 1, Value: der}
}

func intAttr(typ, n int) receiptAttribute {
	der, _ := asn1.Marshal(n)
	return receiptAttribute{Type: typ, Version: 1, Value: der}
}

func rawAttr(typ int, b []byte) receiptAttribute {
	return receiptAttribute{Type: typ, Version: 1, Value: b}
}

func redeemedReceipt(t *testing.T, keys int) []byte {
	t.Helper()
	return buildReceipt(t, []receiptAttribute{
		strAttr(fieldAppID, "TEAMID1234.com.mvks5.bambu"),
		strAttr(fieldReceiptType, TypeReceipt),
		strAttr(fieldCreation, "2026-08-11T09:00:00Z"),
		intAttr(fieldRiskMetric, keys),
		strAttr(fieldNotBefore, "2026-08-12T09:00:00Z"),
		strAttr(fieldExpiration, "2026-11-09T09:00:00Z"),
	})
}

// --- parsing ---

func TestParseReadsEveryFieldCanopyActsOn(t *testing.T) {
	got, err := Parse(redeemedReceipt(t, 3))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if got.Type != TypeReceipt {
		t.Errorf("Type = %q, want %q", got.Type, TypeReceipt)
	}
	if got.AppID != "TEAMID1234.com.mvks5.bambu" {
		t.Errorf("AppID = %q", got.AppID)
	}
	if !got.HasKeys || got.Keys != 3 {
		t.Errorf("Keys = %d (has %v), want 3", got.Keys, got.HasKeys)
	}
	want := time.Date(2026, 8, 12, 9, 0, 0, 0, time.UTC)
	if !got.NotBefore.Equal(want) {
		t.Errorf("NotBefore = %v, want %v", got.NotBefore, want)
	}
	if got.Expiration.IsZero() || got.CreatedAt.IsZero() {
		t.Error("expiration and creation must both be read")
	}
}

func TestAnAttestReceiptCarriesNoMetricAndThatIsNotZero(t *testing.T) {
	// The distinction the whole design rests on. Apple issues ATTEST at attestation and puts the
	// risk metric only in a redeemed RECEIPT — so a key that has never been redeemed has NO answer.
	// Reporting that as "0 keys" would mark every unredeemed device permanently innocent, which is
	// the same silent-false-negative shape as gating an affordance on a nearby predicate.
	receipt := buildReceipt(t, []receiptAttribute{
		strAttr(fieldAppID, "TEAMID1234.com.mvks5.bambu"),
		strAttr(fieldReceiptType, TypeAttest),
		strAttr(fieldCreation, "2026-08-11T09:00:00Z"),
	})

	got, err := Parse(receipt)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.HasKeys {
		t.Error("an ATTEST receipt has no risk metric; HasKeys must stay false")
	}
	if got.Keys != 0 {
		t.Errorf("Keys = %d, want the zero value alongside HasKeys=false", got.Keys)
	}
	if got.Suspicious() {
		t.Error("no metric must never read as suspicious")
	}
}

func TestTheMetricIsFoundByFieldCodeNotByLabel(t *testing.T) {
	// The bug this test exists to prevent: reading the receipt by scanning for the words Apple's
	// documentation uses ("Risk Metric") finds nothing, because the fields are identified by
	// integer type codes. Such a parser reports every device as clean and never errors.
	receipt := redeemedReceipt(t, 42)

	if strings.Contains(string(receipt), "Risk Metric") {
		t.Fatal("fixture accidentally contains the label; the test would prove nothing")
	}
	got, err := Parse(receipt)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.Keys != 42 {
		t.Errorf("Keys = %d, want 42 — the field must be located by its type code", got.Keys)
	}
}

func TestAnAsciiDecimalMetricIsAlsoAccepted(t *testing.T) {
	// Apple's own tooling has shown these values both as DER integers and as ASCII. Accepting both
	// costs nothing; guessing wrong costs a silent zero.
	receipt := buildReceipt(t, []receiptAttribute{
		strAttr(fieldReceiptType, TypeReceipt),
		rawAttr(fieldRiskMetric, []byte("17")),
	})

	got, err := Parse(receipt)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !got.HasKeys || got.Keys != 17 {
		t.Errorf("Keys = %d (has %v), want 17", got.Keys, got.HasKeys)
	}
}

func TestAnUnreadableMetricIsAnErrorNotAZero(t *testing.T) {
	receipt := buildReceipt(t, []receiptAttribute{
		strAttr(fieldReceiptType, TypeReceipt),
		rawAttr(fieldRiskMetric, []byte{0xff, 0xfe, 0xfd}),
	})

	if _, err := Parse(receipt); !errors.Is(err, ErrMalformed) {
		t.Fatalf("err = %v, want ErrMalformed — an unreadable metric must be loud", err)
	}
}

func TestAReceiptWithNoTypeFieldIsRejected(t *testing.T) {
	receipt := buildReceipt(t, []receiptAttribute{strAttr(fieldAppID, "x")})

	if _, err := Parse(receipt); !errors.Is(err, ErrMalformed) {
		t.Fatalf("err = %v, want ErrMalformed", err)
	}
}

func TestGarbageIsRejected(t *testing.T) {
	for name, in := range map[string][]byte{
		"empty":     {},
		"nonsense":  []byte("not a receipt at all"),
		"truncated": redeemedReceipt(t, 1)[:20],
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Parse(in); err == nil {
				t.Fatal("want an error")
			}
		})
	}
}

func TestUnknownFieldsAreIgnored(t *testing.T) {
	// Apple adds fields. A parser that failed on one it did not recognise would break on an Apple
	// change that has nothing to do with Canopy.
	receipt := buildReceipt(t, []receiptAttribute{
		strAttr(fieldReceiptType, TypeReceipt),
		intAttr(fieldRiskMetric, 2),
		strAttr(999, "something new"),
	})

	got, err := Parse(receipt)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.Keys != 2 {
		t.Errorf("Keys = %d, want 2", got.Keys)
	}
}

// --- the threshold ---

func TestSuspiciousOnlyFiresOnAPresentMetricAtOrAboveTheThreshold(t *testing.T) {
	cases := []struct {
		name string
		a    Assessment
		want bool
	}{
		{"no metric", Assessment{}, false},
		{"one key", Assessment{Keys: 1, HasKeys: true}, false},
		{"a household that tinkers", Assessment{Keys: SuspiciousKeyCount - 1, HasKeys: true}, false},
		{"at the threshold", Assessment{Keys: SuspiciousKeyCount, HasKeys: true}, true},
		{"far past it", Assessment{Keys: 500, HasKeys: true}, true},
		{"a big count with no metric flag", Assessment{Keys: 500}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.a.Suspicious(); got != c.want {
				t.Errorf("Suspicious() = %v, want %v", got, c.want)
			}
		})
	}
}

// --- host selection ---

func TestHostFollowsTheAttestationEnvironment(t *testing.T) {
	// A development receipt redeemed against production answers 400 with nothing diagnostic, so
	// this mapping is the difference between an answer and an unexplained failure.
	if got := HostFor("development"); got != DevelopmentHost {
		t.Errorf("development -> %q", got)
	}
	if got := HostFor("production"); got != ProductionHost {
		t.Errorf("production -> %q", got)
	}
	if got := HostFor(""); got != ProductionHost {
		t.Errorf("unknown environments must not silently reach the development host, got %q", got)
	}
}

// --- the client ---

func testKeyPEM(t *testing.T) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func TestAnUnconfiguredDeploymentIsNotAnError(t *testing.T) {
	for name, args := range map[string][3]string{
		"no key id":    {"", "issuer", "pem"},
		"no issuer":    {"kid", "", "pem"},
		"no key bytes": {"kid", "issuer", ""},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := NewClient("", args[0], args[1], []byte(args[2]))
			if !errors.Is(err, ErrNotConfigured) {
				t.Fatalf("err = %v, want ErrNotConfigured", err)
			}
		})
	}
}

func TestANilClientRedeemsToNotConfigured(t *testing.T) {
	// The sweep holds a nil client when unconfigured and calls it anyway; that must not panic.
	var c *Client
	if _, err := c.Redeem(context.Background(), []byte("x"), "production", time.Now()); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("err = %v, want ErrNotConfigured", err)
	}
}

func TestABadKeyIsRejected(t *testing.T) {
	if _, err := NewClient("", "kid", "issuer", []byte("-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----")); err == nil {
		t.Fatal("want an error for a key that is not parseable")
	}
	if _, err := NewClient("", "kid", "issuer", []byte("not pem at all")); err == nil {
		t.Fatal("want an error for bytes that are not PEM")
	}
}

func TestRedeemSendsTheReceiptBase64AndReturnsTheRefreshedOne(t *testing.T) {
	receipt := redeemedReceipt(t, 7)

	var gotAuth, gotBody, gotType string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotAuth, gotBody, gotType = r.Header.Get("Authorization"), string(b), r.Header.Get("Content-Type")
		w.Write([]byte(base64.StdEncoding.EncodeToString(receipt)))
	}))
	defer srv.Close()

	c, err := NewClient(srv.URL, "KEYID", "ISSUER", testKeyPEM(t))
	if err != nil {
		t.Fatal(err)
	}
	got, err := c.Redeem(context.Background(), []byte("stored-receipt"), "production", time.Now())
	if err != nil {
		t.Fatalf("Redeem: %v", err)
	}

	if gotBody != base64.StdEncoding.EncodeToString([]byte("stored-receipt")) {
		t.Errorf("body = %q; Apple expects the base64 receipt as the whole body", gotBody)
	}
	if gotType != "text/plain" {
		t.Errorf("Content-Type = %q, want text/plain", gotType)
	}
	if !strings.HasPrefix(gotAuth, "Bearer ") {
		t.Errorf("Authorization = %q", gotAuth)
	}
	if got.Keys != 7 {
		t.Errorf("Keys = %d, want 7", got.Keys)
	}
}

func TestTheBearerTokenIsAWellFormedES256JWT(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.Write([]byte(base64.StdEncoding.EncodeToString(redeemedReceipt(t, 1))))
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, "KEYID", "ISSUER", testKeyPEM(t))
	now := time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)
	if _, err := c.Redeem(context.Background(), []byte("r"), "production", now); err != nil {
		t.Fatal(err)
	}

	parts := strings.Split(strings.TrimPrefix(gotAuth, "Bearer "), ".")
	if len(parts) != 3 {
		t.Fatalf("token has %d parts, want 3", len(parts))
	}

	var header map[string]string
	decode(t, parts[0], &header)
	if header["alg"] != "ES256" || header["kid"] != "KEYID" {
		t.Errorf("header = %v", header)
	}

	var claims map[string]any
	decode(t, parts[1], &claims)
	if claims["iss"] != "ISSUER" {
		t.Errorf("iss = %v", claims["iss"])
	}
	if claims["aud"] != "appstoreconnect-v1" {
		t.Errorf("aud = %v, want appstoreconnect-v1", claims["aud"])
	}
	if claims["iat"].(float64) != float64(now.Unix()) {
		t.Errorf("iat = %v, want %d", claims["iat"], now.Unix())
	}

	// JOSE wants R||S, fixed width — 64 bytes for P-256. An ASN.1 signature here is the failure
	// Apple reports only as an unhelpful 401.
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("signature is not base64url: %v", err)
	}
	if len(sig) != 64 {
		t.Errorf("signature is %d bytes, want the 64-byte R||S pair, not ASN.1", len(sig))
	}
}

func decode(t *testing.T, part string, into any) {
	t.Helper()
	b, err := base64.RawURLEncoding.DecodeString(part)
	if err != nil {
		t.Fatalf("decode %q: %v", part, err)
	}
	if err := json.Unmarshal(b, into); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
}

func TestThrottlingIsItsOwnOutcome(t *testing.T) {
	// 429 means "come back after NotBefore", not "this device is a problem" and not "retry now".
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, "K", "I", testKeyPEM(t))
	_, err := c.Redeem(context.Background(), []byte("r"), "production", time.Now())
	if !errors.Is(err, ErrThrottled) {
		t.Fatalf("err = %v, want ErrThrottled", err)
	}
}

func TestOtherFailuresCarryTheStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("wrong environment"))
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, "K", "I", testKeyPEM(t))
	_, err := c.Redeem(context.Background(), []byte("r"), "production", time.Now())
	if !errors.Is(err, ErrRedeem) {
		t.Fatalf("err = %v, want ErrRedeem", err)
	}
	if !strings.Contains(err.Error(), "400") || !strings.Contains(err.Error(), "wrong environment") {
		t.Errorf("err = %v; the status and body are the only diagnosis available", err)
	}
}

func TestANonBase64ResponseIsRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("!!!not base64!!!"))
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, "K", "I", testKeyPEM(t))
	if _, err := c.Redeem(context.Background(), []byte("r"), "production", time.Now()); !errors.Is(err, ErrRedeem) {
		t.Fatalf("err = %v, want ErrRedeem", err)
	}
}

func TestAContextCancellationStopsRedemption(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, "K", "I", testKeyPEM(t))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.Redeem(ctx, []byte("r"), "production", time.Now()); err == nil {
		t.Fatal("want an error on a cancelled context")
	}
}
