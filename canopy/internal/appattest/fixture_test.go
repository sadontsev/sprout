package appattest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"math/big"
	"testing"
	"time"

	"github.com/fxamacker/cbor/v2"
)

// This file builds attestation objects in Apple's documented shape so the
// verification procedure can be exercised — including every rejection path —
// without a physical device.
//
// What these fixtures DO validate: the ordered procedure, the credCert nonce
// comparison, chain and validity-window checking, the key-id digest, the app-id
// hash, the counter rules, the exact-16-byte aaguid comparison, credentialId
// agreement, and assertion signature verification.
//
// What they do NOT validate: wire compatibility with Apple. Fixtures produced
// and parsed by the same code would agree even if both were wrong about the
// real encoding. Confirming that requires one genuine attestation captured from
// a real device (rollout step 0), and TestExtensionHasAppleDocumentedDERShape
// below pins the one structure most likely to drift.

type fixtureCA struct {
	rootKey  *ecdsa.PrivateKey
	rootCert *x509.Certificate
	interKey *ecdsa.PrivateKey
	interDER []byte
	interCrt *x509.Certificate
	pool     *x509.CertPool
}

func newCA(t *testing.T, now time.Time) *fixtureCA {
	t.Helper()

	rootKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	rootTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test App Attest Root CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(10 * 365 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey)
	if err != nil {
		t.Fatalf("root: %v", err)
	}
	rootCert, _ := x509.ParseCertificate(rootDER)

	interKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	interTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "Test App Attest CA 1"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(5 * 365 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	interDER, err := x509.CreateCertificate(rand.Reader, interTmpl, rootCert, &interKey.PublicKey, rootKey)
	if err != nil {
		t.Fatalf("intermediate: %v", err)
	}
	interCrt, _ := x509.ParseCertificate(interDER)

	pool := x509.NewCertPool()
	pool.AddCert(rootCert)

	return &fixtureCA{rootKey, rootCert, interKey, interDER, interCrt, pool}
}

// encodeNonceExtension builds the credCert extension by hand rather than via the
// parser's own struct, so encoder and decoder cannot agree on a wrong shape.
// Apple: a DER SEQUENCE containing a single context-[1] wrapping an OCTET STRING.
func encodeNonceExtension(t *testing.T, nonce []byte) []byte {
	t.Helper()
	octet, err := asn1.Marshal(nonce) // OCTET STRING
	if err != nil {
		t.Fatalf("marshal octet string: %v", err)
	}
	inner := append([]byte{0xA1, byte(len(octet))}, octet...) // [1] constructed
	return append([]byte{0x30, byte(len(inner))}, inner...)   // SEQUENCE
}

type fixtureOpts struct {
	appID       string
	aaguid      []byte
	counter     uint32
	credID      []byte // defaults to the real key id
	nonce       []byte // defaults to the correct nonce
	notBefore   time.Time
	notAfter    time.Time
	skipRootCA  bool // sign the leaf with an unrelated CA
	fmtOverride string
}

// buildAttestation returns (cborObject, keyID, deviceKey).
func buildAttestation(t *testing.T, ca *fixtureCA, clientData []byte, now time.Time, opt fixtureOpts) ([]byte, string, *ecdsa.PrivateKey) {
	t.Helper()

	deviceKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pubX963 := x963(&deviceKey.PublicKey)
	keyIDRaw := sha256.Sum256(pubX963)
	keyID := base64.RawURLEncoding.EncodeToString(keyIDRaw[:])

	appID := opt.appID
	if appID == "" {
		appID = testAppID
	}
	aaguid := opt.aaguid
	if aaguid == nil {
		aaguid = aaguidProduction
	}
	credID := opt.credID
	if credID == nil {
		credID = keyIDRaw[:]
	}

	// authData: rpIdHash(32) | flags(1) | counter(4) | aaguid(16) | credIdLen(2) | credId
	appIDHash := sha256.Sum256([]byte(appID))
	authData := make([]byte, 0, 55+len(credID))
	authData = append(authData, appIDHash[:]...)
	authData = append(authData, 0x40) // attested-credential-data flag
	var ctr [4]byte
	binary.BigEndian.PutUint32(ctr[:], opt.counter)
	authData = append(authData, ctr[:]...)
	authData = append(authData, aaguid...)
	var l [2]byte
	binary.BigEndian.PutUint16(l[:], uint16(len(credID)))
	authData = append(authData, l[:]...)
	authData = append(authData, credID...)

	nonce := opt.nonce
	if nonce == nil {
		clientDataHash := sha256.Sum256(clientData)
		h := sha256.New()
		h.Write(authData)
		h.Write(clientDataHash[:])
		nonce = h.Sum(nil)
	}

	notBefore, notAfter := opt.notBefore, opt.notAfter
	if notBefore.IsZero() {
		notBefore = now.Add(-time.Minute)
	}
	if notAfter.IsZero() {
		notAfter = now.Add(24 * time.Hour)
	}

	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(3),
		Subject:      pkix.Name{CommonName: "Test App Attest Leaf"},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		ExtraExtensions: []pkix.Extension{{
			Id:    appAttestNonceOID,
			Value: encodeNonceExtension(t, nonce),
		}},
	}

	parent, parentKey := ca.interCrt, ca.interKey
	if opt.skipRootCA {
		rogue := newCA(t, now)
		parent, parentKey = rogue.interCrt, rogue.interKey
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, parent, &deviceKey.PublicKey, parentKey)
	if err != nil {
		t.Fatalf("leaf: %v", err)
	}

	format := opt.fmtOverride
	if format == "" {
		format = "apple-appattest"
	}
	obj, err := cbor.Marshal(attestationObject{
		Fmt:      format,
		AttStmt:  attStmt{X5C: [][]byte{leafDER, ca.interDER}, Receipt: []byte("receipt-bytes")},
		AuthData: authData,
	})
	if err != nil {
		t.Fatalf("cbor: %v", err)
	}
	return obj, keyID, deviceKey
}

// buildAssertion returns a CBOR assertion object signed by key.
func buildAssertion(t *testing.T, key *ecdsa.PrivateKey, clientData []byte, appID string, counter uint32, corrupt bool) []byte {
	t.Helper()

	appIDHash := sha256.Sum256([]byte(appID))
	authData := make([]byte, 0, 37)
	authData = append(authData, appIDHash[:]...)
	authData = append(authData, 0x00)
	var ctr [4]byte
	binary.BigEndian.PutUint32(ctr[:], counter)
	authData = append(authData, ctr[:]...)

	clientDataHash := sha256.Sum256(clientData)
	h := sha256.New()
	h.Write(authData)
	h.Write(clientDataHash[:])
	nonce := h.Sum(nil)

	// Signed the way Apple signs it: over SHA-256(nonce), because generateAssertion uses the
	// message-based algorithm which hashes its input. The fixture originally signed the nonce
	// directly and the verifier checked it that way, so the pair agreed while both were wrong —
	// which is exactly the blind spot a self-generated fixture has, and only a real device found.
	digest := sha256.Sum256(nonce)
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if corrupt {
		sig[len(sig)-1] ^= 0xff
	}

	obj, err := cbor.Marshal(assertionObject{Signature: sig, AuthenticatorData: authData})
	if err != nil {
		t.Fatalf("cbor: %v", err)
	}
	return obj
}
