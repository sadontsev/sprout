package appattest

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"strings"
	"testing"
	"time"
)

// Verifies a genuine device attestation. This is the only assumption in the design that rested on
// a reading of Apple's documentation rather than on evidence: the synthetic fixtures prove every
// rejection path, but fixtures produced and parsed by the same codebase would agree even if both
// were wrong about the real wire format.
func TestRealDeviceAttestation(t *testing.T) {
	obj, err := os.ReadFile("testdata/attestation.bin")
	if err != nil {
		t.Skip("no captured attestation")
	}
	keyID, _ := os.ReadFile("testdata/attestation.keyid")
	clientData, _ := os.ReadFile("testdata/attestation.clientdata")

	// The app id is team.bundle, and the team id identifies a real Apple developer account. This
	// repository is public and states that nothing identifying is committed, so it lives in a
	// gitignored file beside the rest of the fixture rather than in source.
	//
	// Missing it FAILS rather than skips. The attestation is present — so this is a checkout that
	// captured a fixture and lost one piece of it, and skipping would report a green suite for the
	// one test that verifies the design against reality.
	appID, err := os.ReadFile("testdata/attestation.appid")
	if err != nil {
		t.Fatalf("testdata/attestation.appid is missing while attestation.bin is present. "+
			"It holds <TEAMID>.<bundle id> for the capture, is gitignored, and cannot be derived "+
			"from the attestation (only its SHA-256 appears there): %v", err)
	}

	rootPEM, err := os.ReadFile("testdata/apple-app-attest-root.pem")
	if err != nil {
		t.Fatalf("root CA: %v", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(rootPEM) {
		block, _ := pem.Decode(rootPEM)
		t.Fatalf("could not load Apple root (first block type %v)", block)
	}

	v := &Verifier{
		Roots:            roots,
		AppID:            strings.TrimSpace(string(appID)),
		AllowDevelopment: true,
	}

	// Pinned to when the attestation was captured: App Attest leaf certificates are short-lived
	// (this one is valid for three days), so a real fixture must be verified against the clock it
	// was made under, or the test rots into a chain failure that reads like a parser bug.
	captured := time.Date(2026, 8, 11, 14, 34, 0, 0, time.UTC)

	got, err := v.VerifyAttestation(obj, string(keyID), clientData, captured)
	if err != nil {
		t.Fatalf("verification failed: %v", err)
	}

	t.Logf("VERIFIED against Apple's real root")
	t.Logf("  environment: %s", got.Environment)
	t.Logf("  counter:     %d", got.Counter)
	t.Logf("  receipt:     %d bytes", len(got.Receipt))
	t.Logf("  public key:  %d-bit %s", got.PublicKey.Curve.Params().BitSize, got.PublicKey.Curve.Params().Name)

	if got.Receipt == nil {
		t.Error("no receipt captured; Apple issues one only at attestation time and it is the input to the fraud metric")
	}
	if got.Environment != Development {
		t.Errorf("environment = %q, want development for a locally-installed build", got.Environment)
	}
}
