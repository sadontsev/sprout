package apns

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"strings"
	"testing"
	"time"
)

var tNow = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

// testKey returns a fresh P-256 key in the PEM/PKCS#8 form Apple ships a .p8 in.
func testKey(t *testing.T) ([]byte, *ecdsa.PublicKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("MarshalPKCS8PrivateKey: %v", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), &key.PublicKey
}

func TestTokenIsAVerifiableES256JWT(t *testing.T) {
	keyPEM, pub := testKey(t)
	s, err := NewSigner("KEYID12345", "TEAMID6789", keyPEM)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}

	tok, err := s.Token(tNow)
	if err != nil {
		t.Fatalf("Token: %v", err)
	}

	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("token has %d segments, want 3", len(parts))
	}

	var header struct{ Alg, Kid string }
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("header is not base64url: %v", err)
	}
	if err := json.Unmarshal(raw, &header); err != nil {
		t.Fatalf("header is not JSON: %v", err)
	}
	if header.Alg != "ES256" {
		t.Errorf("alg = %q, want ES256", header.Alg)
	}
	if header.Kid != "KEYID12345" {
		t.Errorf("kid = %q, want the key id", header.Kid)
	}

	var claims struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
	}
	raw, _ = base64.RawURLEncoding.DecodeString(parts[1])
	if err := json.Unmarshal(raw, &claims); err != nil {
		t.Fatalf("claims are not JSON: %v", err)
	}
	if claims.Iss != "TEAMID6789" {
		t.Errorf("iss = %q, want the team id", claims.Iss)
	}
	if claims.Iat != tNow.Unix() {
		t.Errorf("iat = %d, want %d", claims.Iat, tNow.Unix())
	}

	if !verifyForTest(pub, tok) {
		t.Error("token signature does not verify: APNs wants raw r||s, not ASN.1")
	}
}

func TestTokenIsCachedThenRefreshed(t *testing.T) {
	keyPEM, _ := testKey(t)
	s, _ := NewSigner("KEYID12345", "TEAMID6789", keyPEM)

	first, _ := s.Token(tNow)
	same, _ := s.Token(tNow.Add(TokenLifetime - time.Second))
	if first != same {
		t.Error("a token inside its lifetime must be reused: Apple refuses tokens minted more often than once per 20 minutes")
	}

	later, _ := s.Token(tNow.Add(TokenLifetime + time.Second))
	if later == first {
		t.Error("a token past its lifetime must be re-signed: Apple rejects tokens older than 60 minutes")
	}
}

func TestNewSignerRejectsBadInput(t *testing.T) {
	keyPEM, _ := testKey(t)

	if _, err := NewSigner("", "TEAM", keyPEM); err == nil {
		t.Error("empty key id must be rejected")
	}
	if _, err := NewSigner("KEY", "", keyPEM); err == nil {
		t.Error("empty team id must be rejected")
	}
	if _, err := NewSigner("KEY", "TEAM", []byte("not a pem file")); err == nil {
		t.Error("non-PEM input must be rejected")
	}
	if _, err := NewSigner("KEY", "TEAM", pem.EncodeToMemory(&pem.Block{
		Type: "PRIVATE KEY", Bytes: []byte("garbage"),
	})); err == nil {
		t.Error("PEM that is not a PKCS#8 key must be rejected")
	}
}
