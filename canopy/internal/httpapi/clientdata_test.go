package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"testing"
)

// goldenClientData is the exact encoding the iOS client produces for the fields below. The
// identical literal is asserted in Sprout's XCTest suite (ClaimDataTests.testGoldenFixture).
//
// This is the contract that makes signature verification possible at all: Canopy hashes the bytes
// it receives, so a serialisation difference between the Swift producer and this verifier fails
// *every* claim, and fails it as attestation_invalid — indistinguishable from an attack in the
// logs, and undiagnosable from either side alone. If you change the encoding, change both suites
// in the same commit.
const goldenClientData = `{"apns_environment":"production","binding_kind":"device","challenge":"chal-1","device_id":"dev-1","pairing_public_key":"pub-1","token":"tok-1"}`

const goldenClientDataWithVouch = `{"apns_environment":"production","binding_kind":"device","challenge":"chal-1","device_id":"dev-1","pairing_public_key":"pub-1","token":"tok-1","vouch_nonce":"nonce-1"}`

func TestGoldenClientDataParsesToTheExpectedFields(t *testing.T) {
	var got signedClientData
	if err := json.Unmarshal([]byte(goldenClientData), &got); err != nil {
		t.Fatalf("the iOS client's canonical encoding must parse here: %v", err)
	}

	want := signedClientData{
		Challenge:        "chal-1",
		Token:            "tok-1",
		PairingPublicKey: "pub-1",
		DeviceID:         "dev-1",
		BindingKind:      "device",
		APNSEnvironment:  "production",
	}
	if got != want {
		t.Errorf("parsed %+v, want %+v", got, want)
	}
}

func TestGoldenClientDataMatchesAClaimBody(t *testing.T) {
	// The check that actually runs in production: the fields inside the signed bytes must equal
	// the request's top-level fields, or a relay could present a genuine signature over its own
	// claim while asking Canopy to act on somebody else's token.
	body := claimBody{
		Token:            "tok-1",
		Challenge:        "chal-1",
		PairingPublicKey: "pub-1",
		DeviceID:         "dev-1",
		BindingKind:      "device",
		APNSEnvironment:  "production",
	}
	if !clientDataMatches([]byte(goldenClientData), body) {
		t.Fatal("the golden encoding must satisfy the field-equality check")
	}
}

func TestGoldenClientDataWithVouchMatches(t *testing.T) {
	body := claimBody{
		Token:            "tok-1",
		Challenge:        "chal-1",
		PairingPublicKey: "pub-1",
		DeviceID:         "dev-1",
		BindingKind:      "device",
		APNSEnvironment:  "production",
		VouchNonce:       "nonce-1",
	}
	if !clientDataMatches([]byte(goldenClientDataWithVouch), body) {
		t.Fatal("a claim carrying a vouch nonce must match too")
	}
}

func TestAnAbsentVouchNonceIsNotAnEmptyOne(t *testing.T) {
	// The iOS client omits the field entirely for kinds that cannot be vouched. A body claiming a
	// nonce that the signed bytes do not carry must not match.
	body := claimBody{
		Token:            "tok-1",
		Challenge:        "chal-1",
		PairingPublicKey: "pub-1",
		DeviceID:         "dev-1",
		BindingKind:      "device",
		APNSEnvironment:  "production",
		VouchNonce:       "nonce-1",
	}
	if clientDataMatches([]byte(goldenClientData), body) {
		t.Fatal("a nonce present in the request but absent from the signed bytes must be refused")
	}
}

func TestClientDataToleratesUnknownFields(t *testing.T) {
	// The app must be able to add a field without every deployed relay rejecting it.
	extended := `{"apns_environment":"production","binding_kind":"device","challenge":"chal-1","device_id":"dev-1","future_field":"whatever","pairing_public_key":"pub-1","token":"tok-1"}`
	body := claimBody{
		Token:            "tok-1",
		Challenge:        "chal-1",
		PairingPublicKey: "pub-1",
		DeviceID:         "dev-1",
		BindingKind:      "device",
		APNSEnvironment:  "production",
	}
	if !clientDataMatches([]byte(extended), body) {
		t.Fatal("an unknown field must not break verification")
	}
}

func TestClientDataRejectsASwappedToken(t *testing.T) {
	// The sign-and-swap attack, at the unit level.
	body := claimBody{
		Token:            "tok-VICTIM",
		Challenge:        "chal-1",
		PairingPublicKey: "pub-1",
		DeviceID:         "dev-1",
		BindingKind:      "device",
		APNSEnvironment:  "production",
	}
	if clientDataMatches([]byte(goldenClientData), body) {
		t.Fatal("the token inside the signed bytes is what the signature covers; a different one in the request must be refused")
	}
}

func TestDecodeB64AcceptsEveryAlphabetTheClientMightSend(t *testing.T) {
	raw := []byte(goldenClientData)
	for name, encoded := range map[string]string{
		"raw url":    base64.RawURLEncoding.EncodeToString(raw),
		"padded url": base64.URLEncoding.EncodeToString(raw),
		"raw std":    base64.RawStdEncoding.EncodeToString(raw),
		"padded std": base64.StdEncoding.EncodeToString(raw),
	} {
		got, err := decodeB64(encoded)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if string(got) != goldenClientData {
			t.Errorf("%s: round trip changed the bytes", name)
		}
	}
}
