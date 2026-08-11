package httpapi

import (
	"encoding/base64"
	"encoding/json"
)

// decodeB64 accepts either base64 alphabet, padded or not. Clients differ, and a
// padding mismatch that surfaced as "bad signature" would be indistinguishable
// from an attack in the logs.
func decodeB64(s string) ([]byte, error) {
	if b, err := base64.RawURLEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.URLEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.StdEncoding.DecodeString(s)
}

// signedClientData is the subset of client_data Canopy re-reads. Unknown fields
// are tolerated so the app can add some without breaking verification.
type signedClientData struct {
	Challenge        string `json:"challenge"`
	Token            string `json:"token"`
	PairingPublicKey string `json:"pairing_public_key"`
	DeviceID         string `json:"device_id"`
	BindingKind      string `json:"binding_kind"`
	APNSEnvironment  string `json:"apns_environment"`
	VouchNonce       string `json:"vouch_nonce"`
}

// clientDataMatches checks that the request's top-level fields agree with the
// bytes that were actually signed.
//
// This is the hinge of the whole relay design. The signature proves the device
// authored *those bytes*; without comparing them to the fields Canopy is about
// to act on, a relay could sign-and-swap — present a genuine signature over its
// own claim while asking Canopy to bind somebody else's token. Canopy compares
// the parsed values and never re-serialises: making the check depend on two
// JSON encoders agreeing byte-for-byte forever would fail exactly like an
// attack, on every claim, at some future refactor.
func clientDataMatches(raw []byte, body claimBody) bool {
	var signed signedClientData
	if err := json.Unmarshal(raw, &signed); err != nil {
		return false
	}
	return signed.Challenge == body.Challenge &&
		signed.Token == body.Token &&
		signed.PairingPublicKey == body.PairingPublicKey &&
		signed.DeviceID == body.DeviceID &&
		signed.BindingKind == body.BindingKind &&
		signed.APNSEnvironment == body.APNSEnvironment &&
		signed.VouchNonce == body.VouchNonce
}
