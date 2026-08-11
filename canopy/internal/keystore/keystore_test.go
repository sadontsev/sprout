package keystore

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
	"errors"
	"math/big"
	"path/filepath"
	"testing"
	"time"

	"github.com/fxamacker/cbor/v2"

	"github.com/mvks5/canopy/internal/appattest"
	"github.com/mvks5/canopy/internal/store"
)

var (
	tNow       = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)
	clientData = []byte(`{"challenge":"abc","token":"tok-A"}`)
	appID      = "TEAMID6789.com.mvks5.bambu"
	nonceOID   = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}
)

// The fixture builder is duplicated in miniature here rather than exported from
// appattest: test scaffolding is not API, and a package that exports its own
// fixture generator invites production code to reach for it.
type ca struct {
	interKey *ecdsa.PrivateKey
	interDER []byte
	interCrt *x509.Certificate
	pool     *x509.CertPool
}

func newCA(t *testing.T) *ca {
	t.Helper()
	rootKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	rootTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Root"},
		NotBefore: tNow.Add(-time.Hour), NotAfter: tNow.Add(10000 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	rootDER, _ := x509.CreateCertificate(rand.Reader, rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey)
	rootCrt, _ := x509.ParseCertificate(rootDER)

	interKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	interTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "Inter"},
		NotBefore: tNow.Add(-time.Hour), NotAfter: tNow.Add(5000 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	interDER, _ := x509.CreateCertificate(rand.Reader, interTmpl, rootCrt, &interKey.PublicKey, rootKey)
	interCrt, _ := x509.ParseCertificate(interDER)

	pool := x509.NewCertPool()
	pool.AddCert(rootCrt)
	return &ca{interKey, interDER, interCrt, pool}
}

func x963(pub *ecdsa.PublicKey) []byte {
	out := make([]byte, 65)
	out[0] = 4
	pub.X.FillBytes(out[1:33])
	pub.Y.FillBytes(out[33:])
	return out
}

func buildAttestation(t *testing.T, c *ca) ([]byte, string, *ecdsa.PrivateKey) {
	t.Helper()
	dev, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	keyIDRaw := sha256.Sum256(x963(&dev.PublicKey))
	keyID := base64.RawURLEncoding.EncodeToString(keyIDRaw[:])

	appIDHash := sha256.Sum256([]byte(appID))
	authData := append([]byte{}, appIDHash[:]...)
	authData = append(authData, 0x40, 0, 0, 0, 0)
	authData = append(authData, append([]byte("appattest"), 0, 0, 0, 0, 0, 0, 0)...)
	var l [2]byte
	binary.BigEndian.PutUint16(l[:], uint16(len(keyIDRaw)))
	authData = append(authData, l[:]...)
	authData = append(authData, keyIDRaw[:]...)

	cdh := sha256.Sum256(clientData)
	h := sha256.New()
	h.Write(authData)
	h.Write(cdh[:])
	nonce := h.Sum(nil)

	octet, _ := asn1.Marshal(nonce)
	inner := append([]byte{0xA1, byte(len(octet))}, octet...)
	extVal := append([]byte{0x30, byte(len(inner))}, inner...)

	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "Leaf"},
		NotBefore: tNow.Add(-time.Minute), NotAfter: tNow.Add(24 * time.Hour),
		ExtraExtensions: []pkix.Extension{{Id: nonceOID, Value: extVal}},
	}
	leafDER, _ := x509.CreateCertificate(rand.Reader, leafTmpl, c.interCrt, &dev.PublicKey, c.interKey)

	obj, _ := cbor.Marshal(map[string]any{
		"fmt":      "apple-appattest",
		"attStmt":  map[string]any{"x5c": [][]byte{leafDER, c.interDER}, "receipt": []byte("rcpt")},
		"authData": authData,
	})
	return obj, keyID, dev
}

func buildAssertion(t *testing.T, key *ecdsa.PrivateKey, counter uint32) []byte {
	t.Helper()
	appIDHash := sha256.Sum256([]byte(appID))
	authData := append([]byte{}, appIDHash[:]...)
	authData = append(authData, 0x00)
	var ctr [4]byte
	binary.BigEndian.PutUint32(ctr[:], counter)
	authData = append(authData, ctr[:]...)

	cdh := sha256.Sum256(clientData)
	h := sha256.New()
	h.Write(authData)
	h.Write(cdh[:])
	sig, _ := ecdsa.SignASN1(rand.Reader, key, h.Sum(nil))

	obj, _ := cbor.Marshal(map[string]any{"signature": sig, "authenticatorData": authData})
	return obj
}

func newService(t *testing.T, c *ca) *Service {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return &Service{Store: st, Verifier: &appattest.Verifier{Roots: c.pool, AppID: appID}}
}

func TestAttestationPersistsTheKeyThenAssertionsVerify(t *testing.T) {
	c := newCA(t)
	svc := newService(t, c)
	obj, keyID, dev := buildAttestation(t, c)

	if err := svc.VerifyAttestation(obj, keyID, clientData, tNow); err != nil {
		t.Fatalf("VerifyAttestation: %v", err)
	}

	rec, err := svc.Store.GetAttestKey(keyID)
	if err != nil || rec == nil {
		t.Fatalf("the attested key must be persisted: %v", err)
	}
	if string(rec.Receipt) != "rcpt" {
		t.Error("the receipt must be stored: Apple issues one only at attestation time")
	}
	if rec.Environment != string(appattest.Production) {
		t.Errorf("environment = %q, want production", rec.Environment)
	}

	if err := svc.VerifyAssertion(buildAssertion(t, dev, 1), keyID, clientData, tNow); err != nil {
		t.Fatalf("VerifyAssertion: %v", err)
	}
}

func TestCounterAdvancesAndReplayIsRejected(t *testing.T) {
	c := newCA(t)
	svc := newService(t, c)
	obj, keyID, dev := buildAttestation(t, c)
	if err := svc.VerifyAttestation(obj, keyID, clientData, tNow); err != nil {
		t.Fatalf("attest: %v", err)
	}

	as := buildAssertion(t, dev, 1)
	if err := svc.VerifyAssertion(as, keyID, clientData, tNow); err != nil {
		t.Fatalf("first assertion: %v", err)
	}
	rec, _ := svc.Store.GetAttestKey(keyID)
	if rec.Counter != 1 {
		t.Errorf("stored counter = %d, want 1", rec.Counter)
	}

	// The same assertion again: the counter no longer strictly increases.
	if err := svc.VerifyAssertion(as, keyID, clientData, tNow); err == nil {
		t.Fatal("a replayed assertion must be rejected once its counter is spent")
	}

	if err := svc.VerifyAssertion(buildAssertion(t, dev, 2), keyID, clientData, tNow); err != nil {
		t.Errorf("a higher counter must be accepted: %v", err)
	}
}

func TestUnknownKeyAsksForReattestationRatherThanFailing(t *testing.T) {
	c := newCA(t)
	svc := newService(t, c)
	_, keyID, dev := buildAttestation(t, c)

	err := svc.VerifyAssertion(buildAssertion(t, dev, 1), keyID, clientData, tNow)
	if !errors.Is(err, ErrReattestRequired) {
		t.Fatalf("err = %v, want ErrReattestRequired — the honest cause is a Canopy "+
			"restore predating the key, and reporting it as invalid would leave the "+
			"install permanently unable to claim", err)
	}
}

func TestAssertionByAnotherKeyIsRejected(t *testing.T) {
	c := newCA(t)
	svc := newService(t, c)
	obj, keyID, _ := buildAttestation(t, c)
	_, _, otherDev := buildAttestation(t, c)
	if err := svc.VerifyAttestation(obj, keyID, clientData, tNow); err != nil {
		t.Fatalf("attest: %v", err)
	}

	if err := svc.VerifyAssertion(buildAssertion(t, otherDev, 1), keyID, clientData, tNow); err == nil {
		t.Fatal("an assertion by a different key must not verify against the stored one")
	}
}

func TestRejectedAssertionDoesNotAdvanceTheStoredCounter(t *testing.T) {
	c := newCA(t)
	svc := newService(t, c)
	obj, keyID, dev := buildAttestation(t, c)
	svc.VerifyAttestation(obj, keyID, clientData, tNow)
	svc.VerifyAssertion(buildAssertion(t, dev, 5), keyID, clientData, tNow)

	// A stale assertion must neither verify nor move the high-water mark, or a
	// rejection would erode the replay protection it exists to provide.
	_ = svc.VerifyAssertion(buildAssertion(t, dev, 2), keyID, clientData, tNow)
	rec, _ := svc.Store.GetAttestKey(keyID)
	if rec.Counter != 5 {
		t.Errorf("stored counter = %d, want 5", rec.Counter)
	}
}

func TestAttestKeysSurviveBindingDeletion(t *testing.T) {
	c := newCA(t)
	svc := newService(t, c)
	obj, keyID, dev := buildAttestation(t, c)
	svc.VerifyAttestation(obj, keyID, clientData, tNow)

	// Bindings come and go with every print card; the key must outlive them, or
	// the next assertion from a live install would ask for re-attestation.
	if err := svc.Store.DropBinding("some-token-hash"); err != nil {
		t.Fatalf("DropBinding: %v", err)
	}
	if err := svc.VerifyAssertion(buildAssertion(t, dev, 1), keyID, clientData, tNow); err != nil {
		t.Errorf("the attest key must survive binding churn: %v", err)
	}
}
