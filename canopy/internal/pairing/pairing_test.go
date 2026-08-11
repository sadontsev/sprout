package pairing

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"testing"
)

func newKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	return k
}

func sign(t *testing.T, k *ecdsa.PrivateKey, clientData []byte) string {
	t.Helper()
	digest := sha256.Sum256(clientData)
	sig, err := ecdsa.SignASN1(rand.Reader, k, digest[:])
	if err != nil {
		t.Fatalf("SignASN1: %v", err)
	}
	return base64.RawURLEncoding.EncodeToString(sig)
}

func TestVerifyAcceptsAGenuineSignature(t *testing.T) {
	k := newKey(t)
	pub := EncodePublicKey(&k.PublicKey)
	clientData := []byte(`{"challenge":"abc","token":"tok-A"}`)

	if !Verify(pub, clientData, sign(t, k, clientData)) {
		t.Fatal("a signature by the matching key must verify")
	}
}

func TestVerifyRejectsTheWrongKey(t *testing.T) {
	signer := newKey(t)
	other := newKey(t)
	clientData := []byte(`{"challenge":"abc"}`)

	if Verify(EncodePublicKey(&other.PublicKey), clientData, sign(t, signer, clientData)) {
		t.Fatal("a signature must not verify against a different key")
	}
}

func TestVerifyRejectsAlteredClientData(t *testing.T) {
	k := newKey(t)
	pub := EncodePublicKey(&k.PublicKey)
	signed := []byte(`{"challenge":"abc","token":"tok-A"}`)
	sig := sign(t, k, signed)

	// This is the property the whole relay design rests on: a compromised
	// Trellis can pass a claim along, but it cannot change the token inside it.
	altered := []byte(`{"challenge":"abc","token":"tok-VICTIM"}`)
	if Verify(pub, altered, sig) {
		t.Fatal("a signature must not verify over different client data")
	}
}

func TestVerifyRejectsMalformedInput(t *testing.T) {
	k := newKey(t)
	pub := EncodePublicKey(&k.PublicKey)
	clientData := []byte(`{"challenge":"abc"}`)
	good := sign(t, k, clientData)

	cases := []struct {
		name string
		pub  string
		sig  string
	}{
		{"empty key", "", good},
		{"empty signature", pub, ""},
		{"key is not base64", "!!!not base64!!!", good},
		{"signature is not base64", pub, "!!!not base64!!!"},
		{"key is the wrong length", base64.RawURLEncoding.EncodeToString([]byte{4, 1, 2, 3}), good},
		{"signature is not DER", pub, base64.RawURLEncoding.EncodeToString([]byte("nonsense"))},
	}
	for _, tc := range cases {
		if Verify(tc.pub, clientData, tc.sig) {
			t.Errorf("%s: must not verify", tc.name)
		}
	}
}

func TestParsePublicKeyRejectsAPointOffTheCurve(t *testing.T) {
	k := newKey(t)
	raw, _ := base64.RawURLEncoding.DecodeString(EncodePublicKey(&k.PublicKey))
	raw[1] ^= 0xff // corrupt X so the point no longer satisfies the curve

	if _, err := ParsePublicKey(base64.RawURLEncoding.EncodeToString(raw)); err == nil {
		t.Fatal("a point off the curve must be rejected before any verification")
	}
}

func TestParsePublicKeyRequiresTheUncompressedTag(t *testing.T) {
	k := newKey(t)
	raw, _ := base64.RawURLEncoding.DecodeString(EncodePublicKey(&k.PublicKey))
	raw[0] = 2 // compressed-point tag, which this wire format does not use

	if _, err := ParsePublicKey(base64.RawURLEncoding.EncodeToString(raw)); err == nil {
		t.Fatal("only the X9.63 uncompressed form is accepted")
	}
}

func TestPublicKeyRoundTrips(t *testing.T) {
	k := newKey(t)
	got, err := ParsePublicKey(EncodePublicKey(&k.PublicKey))
	if err != nil {
		t.Fatalf("ParsePublicKey: %v", err)
	}
	if got.X.Cmp(k.PublicKey.X) != 0 || got.Y.Cmp(k.PublicKey.Y) != 0 {
		t.Error("the encoded key must decode to the same point")
	}
}

func TestStandardBase64IsAlsoAccepted(t *testing.T) {
	k := newKey(t)
	raw, _ := base64.RawURLEncoding.DecodeString(EncodePublicKey(&k.PublicKey))
	clientData := []byte(`{"challenge":"abc"}`)
	digest := sha256.Sum256(clientData)
	sigDER, _ := ecdsa.SignASN1(rand.Reader, k, digest[:])

	// Clients differ on padding and alphabet; this is not a security boundary,
	// so accept both rather than fail in a way that looks like a bad signature.
	if !Verify(base64.StdEncoding.EncodeToString(raw), clientData, base64.StdEncoding.EncodeToString(sigDER)) {
		t.Fatal("standard-alphabet base64 must also verify")
	}
}
