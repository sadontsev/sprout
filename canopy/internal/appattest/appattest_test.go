package appattest

import (
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"testing"
	"time"
)

const testAppID = "TEAMID6789.com.example.sprout"

var (
	tNow       = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)
	clientData = []byte(`{"challenge":"abc","token":"tok-A"}`)
)

func newVerifier(ca *fixtureCA) *Verifier {
	return &Verifier{Roots: ca.pool, AppID: testAppID}
}

func TestVerifyAttestationAcceptsAWellFormedProof(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})

	got, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow)
	if err != nil {
		t.Fatalf("VerifyAttestation: %v", err)
	}
	if got.PublicKey == nil {
		t.Error("a verified attestation must yield the public key later assertions verify against")
	}
	if got.Counter != 0 {
		t.Errorf("Counter = %d, want 0", got.Counter)
	}
	if string(got.Receipt) != "receipt-bytes" {
		t.Error("the receipt must be captured: it can only be obtained at attestation time, " +
			"and it is the input to Apple's fraud-assessment metric")
	}
	if got.Environment != Production {
		t.Errorf("Environment = %q, want production", got.Environment)
	}
}

// The load-bearing test. The nonce Apple signs into credCert is what ties the
// certificate to our challenge and our claim; an implementation that computes it
// and never compares it accepts any well-formed attestation with attacker-chosen
// client data.
func TestAttestationIsBoundToTheClientData(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})

	other := []byte(`{"challenge":"abc","token":"tok-VICTIM"}`)
	_, err := newVerifier(ca).VerifyAttestation(obj, keyID, other, tNow)
	if !errors.Is(err, ErrNonce) {
		t.Fatalf("err = %v, want ErrNonce: an attestation must not verify over different client data", err)
	}
}

func TestAttestationWithAForgedNonceIsRejected(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{
		nonce: make([]byte, 32), // a nonce the device chose, not one derived from our challenge
	})

	if _, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrNonce) {
		t.Fatalf("err = %v, want ErrNonce", err)
	}
}

func TestChainMustReachThePinnedRoot(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{skipRootCA: true})

	if _, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrChain) {
		t.Fatalf("err = %v, want ErrChain: a chain to an unpinned CA proves nothing", err)
	}
}

func TestCertificateValidityWindowIsChecked(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{
		notBefore: tNow.Add(-48 * time.Hour),
		notAfter:  tNow.Add(-24 * time.Hour),
	})

	if _, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrChain) {
		t.Fatalf("err = %v, want ErrChain: App Attest leaves are short-lived, so an "+
			"unchecked window would let an old capture verify forever", err)
	}
}

func TestKeyIDMustDigestTheAttestedKey(t *testing.T) {
	ca := newCA(t, tNow)
	obj, _, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})

	// A key id belonging to some other key.
	other, _, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	_ = other
	_, wrongID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})

	if _, err := newVerifier(ca).VerifyAttestation(obj, wrongID, clientData, tNow); !errors.Is(err, ErrKeyID) {
		t.Fatalf("err = %v, want ErrKeyID", err)
	}
}

func TestAppIDHashMustMatch(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{
		appID: "OTHERTEAM.com.someone.else",
	})

	if _, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrAppID) {
		t.Fatalf("err = %v, want ErrAppID: an app re-signed under another team must fail here", err)
	}
}

func TestFreshKeyCounterMustBeZero(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{counter: 7})

	if _, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrCounter) {
		t.Fatalf("err = %v, want ErrCounter", err)
	}
}

// The aaguid is compared as exactly sixteen bytes. The only input that
// distinguishes an exact comparison from a prefix comparison is a value that
// starts with "appattest" and continues with something other than zeros — so
// that is the case worth having.
func TestAAGUIDIsComparedExactlyNotByPrefix(t *testing.T) {
	ca := newCA(t, tNow)
	hostile := append([]byte("appattest"), 1, 2, 3, 4, 5, 6, 7)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{aaguid: hostile})

	if _, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrEnvironment) {
		t.Fatalf("err = %v, want ErrEnvironment: a prefix comparison would have accepted this", err)
	}
}

func TestDevelopmentAAGUIDIsGatedByConfiguration(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{aaguid: aaguidDevelopment})

	prod := newVerifier(ca)
	if _, err := prod.VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrEnvironment) {
		t.Fatalf("err = %v, want ErrEnvironment when development is not permitted", err)
	}

	dev := newVerifier(ca)
	dev.AllowDevelopment = true
	got, err := dev.VerifyAttestation(obj, keyID, clientData, tNow)
	if err != nil {
		t.Fatalf("development attestation: %v", err)
	}
	if got.Environment != Development {
		t.Errorf("Environment = %q, want development — it is recorded per key and never "+
			"derived from the APNs environment", got.Environment)
	}
}

func TestCredentialIDMustMatchTheKeyID(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{
		credID: []byte("some-other-credential-id-32bytes"),
	})

	if _, err := newVerifier(ca).VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrCredentialID) {
		t.Fatalf("err = %v, want ErrCredentialID", err)
	}
}

func TestMalformedObjectsAreRejected(t *testing.T) {
	ca := newCA(t, tNow)
	v := newVerifier(ca)

	if _, err := v.VerifyAttestation([]byte("not cbor"), "k", clientData, tNow); !errors.Is(err, ErrFormat) {
		t.Errorf("non-CBOR: err = %v, want ErrFormat", err)
	}

	obj, keyID, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{fmtOverride: "webauthn"})
	if _, err := v.VerifyAttestation(obj, keyID, clientData, tNow); !errors.Is(err, ErrFormat) {
		t.Errorf("wrong fmt: err = %v, want ErrFormat", err)
	}
}

// --- assertions ---

func TestAssertionVerifiesAgainstTheStoredKey(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, deviceKey := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	v := newVerifier(ca)
	attested, err := v.VerifyAttestation(obj, keyID, clientData, tNow)
	if err != nil {
		t.Fatalf("attest: %v", err)
	}

	as := buildAssertion(t, deviceKey, clientData, testAppID, 1, false)
	counter, err := v.VerifyAssertion(as, attested.PublicKey, 0, clientData)
	if err != nil {
		t.Fatalf("VerifyAssertion: %v", err)
	}
	if counter != 1 {
		t.Errorf("counter = %d, want 1", counter)
	}
}

// Without this check every other check runs on attacker-supplied plaintext.
func TestAssertionSignatureIsVerified(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, deviceKey := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	v := newVerifier(ca)
	attested, _ := v.VerifyAttestation(obj, keyID, clientData, tNow)

	corrupt := buildAssertion(t, deviceKey, clientData, testAppID, 1, true)
	if _, err := v.VerifyAssertion(corrupt, attested.PublicKey, 0, clientData); !errors.Is(err, ErrSignature) {
		t.Fatalf("err = %v, want ErrSignature", err)
	}
}

func TestAssertionBySomeOtherKeyIsRejected(t *testing.T) {
	ca := newCA(t, tNow)
	objA, keyA, _ := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	_, _, keyB := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	v := newVerifier(ca)
	attestedA, _ := v.VerifyAttestation(objA, keyA, clientData, tNow)

	as := buildAssertion(t, keyB, clientData, testAppID, 1, false)
	if _, err := v.VerifyAssertion(as, attestedA.PublicKey, 0, clientData); !errors.Is(err, ErrSignature) {
		t.Fatalf("err = %v, want ErrSignature", err)
	}
}

func TestAssertionIsBoundToItsClientData(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, deviceKey := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	v := newVerifier(ca)
	attested, _ := v.VerifyAttestation(obj, keyID, clientData, tNow)

	as := buildAssertion(t, deviceKey, clientData, testAppID, 1, false)
	other := []byte(`{"challenge":"abc","token":"tok-VICTIM"}`)
	if _, err := v.VerifyAssertion(as, attested.PublicKey, 0, other); !errors.Is(err, ErrSignature) {
		t.Fatalf("err = %v, want ErrSignature: swapping the token inside the signed bytes must fail", err)
	}
}

func TestAssertionCounterMustStrictlyIncrease(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, deviceKey := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	v := newVerifier(ca)
	attested, _ := v.VerifyAttestation(obj, keyID, clientData, tNow)

	for _, counter := range []uint32{0, 5} {
		as := buildAssertion(t, deviceKey, clientData, testAppID, counter, false)
		if _, err := v.VerifyAssertion(as, attested.PublicKey, 5, clientData); err == nil {
			t.Errorf("counter %d against stored 5 must be rejected", counter)
		}
	}

	as := buildAssertion(t, deviceKey, clientData, testAppID, 6, false)
	if _, err := v.VerifyAssertion(as, attested.PublicKey, 5, clientData); err != nil {
		t.Errorf("counter 6 against stored 5 must be accepted: %v", err)
	}
}

func TestAssertionAppIDIsChecked(t *testing.T) {
	ca := newCA(t, tNow)
	obj, keyID, deviceKey := buildAttestation(t, ca, clientData, tNow, fixtureOpts{})
	v := newVerifier(ca)
	attested, _ := v.VerifyAttestation(obj, keyID, clientData, tNow)

	as := buildAssertion(t, deviceKey, clientData, "OTHERTEAM.com.someone.else", 1, false)
	if _, err := v.VerifyAssertion(as, attested.PublicKey, 0, clientData); !errors.Is(err, ErrSignature) && !errors.Is(err, ErrAppID) {
		t.Fatalf("err = %v, want a rejection", err)
	}
}

// Pins the one structure most likely to drift from Apple's real encoding. The
// extension is a DER SEQUENCE wrapping a context-[1] wrapping an OCTET STRING;
// this asserts the bytes directly rather than round-tripping through the parser,
// so encoder and decoder cannot agree on a wrong shape.
func TestExtensionHasAppleDocumentedDERShape(t *testing.T) {
	nonce := make([]byte, 32)
	for i := range nonce {
		nonce[i] = byte(i)
	}
	der := encodeNonceExtension(t, nonce)

	if der[0] != 0x30 {
		t.Fatalf("outer tag = %#x, want 0x30 (SEQUENCE)", der[0])
	}
	if der[2] != 0xA1 {
		t.Fatalf("inner tag = %#x, want 0xA1 (context-specific 1, constructed)", der[2])
	}
	if der[4] != 0x04 {
		t.Fatalf("innermost tag = %#x, want 0x04 (OCTET STRING)", der[4])
	}
	if int(der[5]) != len(nonce) {
		t.Fatalf("octet string length = %d, want %d", der[5], len(nonce))
	}

	// And the parser agrees with the hand-built bytes.
	cert := &x509.Certificate{Extensions: []pkix.Extension{{Id: appAttestNonceOID, Value: der}}}
	got, err := nonceFromCert(cert)
	if err != nil {
		t.Fatalf("nonceFromCert: %v", err)
	}
	if string(got) != string(nonce) {
		t.Error("the parser must recover exactly the nonce that was encoded")
	}
}
