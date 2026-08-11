// Package appattest verifies Apple App Attest attestations and assertions.
//
// It implements Apple's published procedure in the published order. Two steps in
// it are the whole mechanism, and an earlier draft of this project's design
// omitted both:
//
//   - The credCert extension with OID 1.2.840.113635.100.8.2 carries a nonce that
//     Apple signed. Comparing it to SHA-256(authData || clientDataHash) is the
//     only thing tying Apple's certificate to *our* challenge and *our* claim.
//     Computing that value and never comparing it verifies nothing, and leaves
//     any well-formed attestation replayable with attacker-chosen client data.
//   - An assertion's signature must be verified against the public key stored at
//     attestation time. Without it, every remaining check runs on
//     attacker-supplied plaintext.
//
// Scope note: this package is pure. It holds no store and performs no lookups —
// the caller supplies the stored public key and counter — so the procedure can
// be tested exhaustively without a database.
package appattest

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"github.com/fxamacker/cbor/v2"
)

// Errors returned by this package. They are distinguishable so a caller can log
// which step failed without leaking that detail to the client.
var (
	ErrFormat          = errors.New("appattest: malformed attestation object")
	ErrChain           = errors.New("appattest: certificate chain does not verify")
	ErrNonce           = errors.New("appattest: credCert nonce does not match the challenge")
	ErrKeyID           = errors.New("appattest: key id does not match the attested public key")
	ErrAppID           = errors.New("appattest: rpIdHash does not match the app id")
	ErrCounter         = errors.New("appattest: counter is not acceptable")
	ErrEnvironment     = errors.New("appattest: aaguid environment is not permitted")
	ErrCredentialID    = errors.New("appattest: credentialId does not match the key id")
	ErrSignature       = errors.New("appattest: assertion signature does not verify")
	ErrKeyIDNotAllowed = errors.New("appattest: key id is not valid base64url")
)

// appAttestNonceOID is the credCert extension carrying Apple's signed nonce.
var appAttestNonceOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}

// Environment distinguishes Apple's development and production App Attest
// services. It is *not* the APNs environment: Apple explicitly allows a
// development build to attest against production, and the entitlement is ignored
// after distribution. Conflating the two was a real defect in this project's
// design, so they never share a field.
type Environment string

const (
	Development Environment = "development"
	Production  Environment = "production"
)

var (
	aaguidDevelopment = []byte("appattestdevelop")
	aaguidProduction  = append([]byte("appattest"), 0, 0, 0, 0, 0, 0, 0)
)

// Attested is what a verified attestation establishes.
type Attested struct {
	PublicKey   *ecdsa.PublicKey
	Counter     uint32
	Receipt     []byte
	Environment Environment
}

// Verifier checks proofs for one app.
type Verifier struct {
	// Roots must contain the Apple App Attest Root CA in production. Tests
	// supply their own root, which is why this is a field and not a constant.
	Roots *x509.CertPool
	// AppID is "<TEAM_ID>.<bundle id>".
	AppID string
	// AllowDevelopment permits the development aaguid. A production deployment
	// leaves this false.
	AllowDevelopment bool
}

type attestationObject struct {
	Fmt      string  `cbor:"fmt"`
	AttStmt  attStmt `cbor:"attStmt"`
	AuthData []byte  `cbor:"authData"`
}

type attStmt struct {
	X5C     [][]byte `cbor:"x5c"`
	Receipt []byte   `cbor:"receipt"`
}

type assertionObject struct {
	Signature         []byte `cbor:"signature"`
	AuthenticatorData []byte `cbor:"authenticatorData"`
}

// VerifyAttestation runs Apple's procedure over a first-use attestation.
func (v *Verifier) VerifyAttestation(obj []byte, keyID string, clientData []byte, now time.Time) (Attested, error) {
	// 1. Shape.
	var att attestationObject
	if err := cbor.Unmarshal(obj, &att); err != nil {
		return Attested{}, fmt.Errorf("%w: %v", ErrFormat, err)
	}
	if att.Fmt != "apple-appattest" || len(att.X5CCerts()) < 2 || len(att.AuthData) < 55 {
		return Attested{}, ErrFormat
	}

	// 2. Chain to the pinned root, with every certificate inside its validity
	// window at now. App Attest leaf certificates are short-lived, so an
	// unchecked window would let an old capture verify forever.
	certs := make([]*x509.Certificate, 0, len(att.X5CCerts()))
	for _, der := range att.X5CCerts() {
		c, err := x509.ParseCertificate(der)
		if err != nil {
			return Attested{}, fmt.Errorf("%w: %v", ErrFormat, err)
		}
		certs = append(certs, c)
	}
	credCert := certs[0]

	intermediates := x509.NewCertPool()
	for _, c := range certs[1:] {
		intermediates.AddCert(c)
	}
	if _, err := credCert.Verify(x509.VerifyOptions{
		Roots:         v.Roots,
		Intermediates: intermediates,
		CurrentTime:   now,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return Attested{}, fmt.Errorf("%w: %v", ErrChain, err)
	}

	// 3, 4. The nonce Apple should have signed.
	clientDataHash := sha256.Sum256(clientData)
	h := sha256.New()
	h.Write(att.AuthData)
	h.Write(clientDataHash[:])
	nonce := h.Sum(nil)

	// 5. The comparison that makes all of this mean something.
	signed, err := nonceFromCert(credCert)
	if err != nil {
		return Attested{}, err
	}
	if !equalBytes(signed, nonce) {
		return Attested{}, ErrNonce
	}

	// 6. The key id is the digest of the attested public key.
	pub, ok := credCert.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return Attested{}, ErrFormat
	}
	want, err := base64.RawURLEncoding.DecodeString(keyID)
	if err != nil {
		if want, err = base64.StdEncoding.DecodeString(keyID); err != nil {
			return Attested{}, ErrKeyIDNotAllowed
		}
	}
	digest := sha256.Sum256(x963(pub))
	if !equalBytes(digest[:], want) {
		return Attested{}, ErrKeyID
	}

	// 7. This app, not some other app on the team.
	appIDHash := sha256.Sum256([]byte(v.AppID))
	if !equalBytes(att.AuthData[:32], appIDHash[:]) {
		return Attested{}, ErrAppID
	}

	// 8. A fresh key has never signed anything.
	if counter := binary.BigEndian.Uint32(att.AuthData[33:37]); counter != 0 {
		return Attested{}, ErrCounter
	}

	// 9. Exactly sixteen bytes: a prefix comparison would also match a hostile
	// value beginning "appattest".
	aaguid := att.AuthData[37:53]
	var env Environment
	switch {
	case equalBytes(aaguid, aaguidProduction):
		env = Production
	case equalBytes(aaguid, aaguidDevelopment):
		if !v.AllowDevelopment {
			return Attested{}, ErrEnvironment
		}
		env = Development
	default:
		return Attested{}, ErrEnvironment
	}

	// 10. The credential the authenticator data describes is this key.
	credIDLen := int(binary.BigEndian.Uint16(att.AuthData[53:55]))
	if len(att.AuthData) < 55+credIDLen {
		return Attested{}, ErrFormat
	}
	if !equalBytes(att.AuthData[55:55+credIDLen], want) {
		return Attested{}, ErrCredentialID
	}

	return Attested{PublicKey: pub, Counter: 0, Receipt: att.AttStmt.Receipt, Environment: env}, nil
}

// VerifyAssertion checks a later assertion against the key stored at attestation
// time, returning the new counter the caller must persist.
func (v *Verifier) VerifyAssertion(obj []byte, pub *ecdsa.PublicKey, storedCounter uint32, clientData []byte) (uint32, error) {
	var as assertionObject
	if err := cbor.Unmarshal(obj, &as); err != nil {
		return 0, fmt.Errorf("%w: %v", ErrFormat, err)
	}
	// An assertion's authenticator data is 37 bytes and carries no aaguid or
	// credentialId, so the attestation's checks 9 and 10 do not apply here.
	if len(as.AuthenticatorData) < 37 {
		return 0, ErrFormat
	}

	clientDataHash := sha256.Sum256(clientData)
	h := sha256.New()
	h.Write(as.AuthenticatorData)
	h.Write(clientDataHash[:])
	nonce := h.Sum(nil)

	// The nonce is the MESSAGE, not the digest. Apple's wording — "verify that the assertion's
	// signature is valid for nonce" — reads either way, and the wrong reading cost a debugging
	// round on real hardware: `generateAssertion` signs through the message-based algorithm, which
	// hashes its input, so the value actually signed is SHA-256(nonce).
	//
	// This is the one thing self-made fixtures could never have caught. The generator signed the
	// nonce as a digest and the verifier checked it the same way, so both were wrong in the same
	// direction and agreed perfectly.
	digest := sha256.Sum256(nonce)
	if !ecdsa.VerifyASN1(pub, digest[:], as.Signature) {
		return 0, ErrSignature
	}

	appIDHash := sha256.Sum256([]byte(v.AppID))
	if !equalBytes(as.AuthenticatorData[:32], appIDHash[:]) {
		return 0, ErrAppID
	}

	counter := binary.BigEndian.Uint32(as.AuthenticatorData[33:37])
	if counter <= storedCounter {
		return 0, ErrCounter
	}
	return counter, nil
}

// X5CCerts exposes the certificate chain.
func (a attestationObject) X5CCerts() [][]byte { return a.AttStmt.X5C }

// nonceFromCert extracts the octet string inside the App Attest extension.
func nonceFromCert(c *x509.Certificate) ([]byte, error) {
	for _, ext := range c.Extensions {
		if !ext.Id.Equal(appAttestNonceOID) {
			continue
		}
		var container struct {
			Nonce []byte `asn1:"tag:1,explicit"`
		}
		if _, err := asn1.Unmarshal(ext.Value, &container); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrFormat, err)
		}
		return container.Nonce, nil
	}
	return nil, ErrNonce
}

// x963 renders a P-256 public key as the uncompressed point Apple digests to
// form the key id.
func x963(pub *ecdsa.PublicKey) []byte {
	out := make([]byte, 65)
	out[0] = 4
	pub.X.FillBytes(out[1:33])
	pub.Y.FillBytes(out[33:])
	return out
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
