// Package pairing verifies the device pairing-key signature on a claim.
//
// The pairing key is the durable half of a device's identity: an App Attest key
// dies with every reinstall, this one survives in the Keychain. It is a keypair
// rather than a shared secret precisely so that nothing secret has to transit
// the user's Trellis — a compromised one relays a signature it can neither
// reuse (the challenge inside the signed bytes is single-use) nor alter.
//
// Wire formats are chosen to match what iOS produces without re-encoding:
//
//   - the public key is base64url of the raw X9.63 uncompressed point
//     (0x04 || X || Y), which is what SecKeyCopyExternalRepresentation returns
//     for a P-256 key;
//   - the signature is base64url of the ASN.1 DER form, which is what
//     SecKeyCreateSignature with ecdsaSignatureMessageX962SHA256 returns.
package pairing

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"math/big"
)

// ErrBadPublicKey is returned when a public key is not a P-256 point.
var ErrBadPublicKey = errors.New("pairing: public key is not a valid P-256 point")

// ParsePublicKey decodes a base64url X9.63 uncompressed P-256 point.
func ParsePublicKey(b64 string) (*ecdsa.PublicKey, error) {
	raw, err := base64.RawURLEncoding.DecodeString(b64)
	if err != nil {
		// Tolerate padded input: clients differ, and this is not a security
		// boundary — an unparseable key simply fails to verify.
		raw, err = base64.StdEncoding.DecodeString(b64)
		if err != nil {
			return nil, ErrBadPublicKey
		}
	}
	// 1 tag byte + two 32-byte coordinates.
	if len(raw) != 65 || raw[0] != 4 {
		return nil, ErrBadPublicKey
	}
	x := new(big.Int).SetBytes(raw[1:33])
	y := new(big.Int).SetBytes(raw[33:])
	if !elliptic.P256().IsOnCurve(x, y) {
		return nil, ErrBadPublicKey
	}
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, nil
}

// EncodePublicKey renders a P-256 public key in the wire format above. Used by
// tests and by any tooling that needs to produce one.
func EncodePublicKey(pub *ecdsa.PublicKey) string {
	raw := make([]byte, 65)
	raw[0] = 4
	pub.X.FillBytes(raw[1:33])
	pub.Y.FillBytes(raw[33:])
	return base64.RawURLEncoding.EncodeToString(raw)
}

// Verify reports whether signatureB64 is a valid P-256/SHA-256 signature over
// clientData by publicKeyB64.
//
// It returns a bool rather than an error because the caller has exactly one
// thing to do with the answer, and an error type invites a caller to log the
// detail and proceed.
func Verify(publicKeyB64 string, clientData []byte, signatureB64 string) bool {
	pub, err := ParsePublicKey(publicKeyB64)
	if err != nil {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(signatureB64)
	if err != nil {
		sig, err = base64.StdEncoding.DecodeString(signatureB64)
		if err != nil {
			return false
		}
	}
	digest := sha256.Sum256(clientData)
	return ecdsa.VerifyASN1(pub, digest[:], sig)
}
