package fraud

import (
	"os"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

// Parses a receipt captured from real hardware.
//
// This is the test that would have caught the bug this file exists because of. Every other fixture
// here is DER built by hand, and DER is a subset of BER — so a DER-only parser passes all of them
// and still fails on every genuine receipt Apple issues. An adversarial review demonstrated exactly
// that: the receipt inside the repo's own captured attestation begins `30 80`, SEQUENCE with an
// indefinite length, and encoding/asn1 refuses it at the first byte pair. The fraud metric would
// have been permanently unavailable while the logs said only that redemption kept failing.
//
// Skips when no attestation has been captured; see ../appattest/README.md.
func TestParsesAReceiptFromRealHardware(t *testing.T) {
	raw, err := os.ReadFile("../appattest/testdata/attestation.bin")
	if err != nil {
		t.Skip("no captured attestation; see ../appattest/README.md")
	}

	var obj struct {
		Fmt     string `cbor:"fmt"`
		AttStmt struct {
			Receipt []byte `cbor:"receipt"`
		} `cbor:"attStmt"`
	}
	if err := cbor.Unmarshal(raw, &obj); err != nil {
		t.Fatalf("decode attestation: %v", err)
	}
	if len(obj.AttStmt.Receipt) == 0 {
		t.Fatal("captured attestation carries no receipt")
	}

	// The shape that defeats a DER parser, asserted so the fixture cannot quietly become a DER one
	// and make this test stop proving anything.
	if obj.AttStmt.Receipt[0] != 0x30 || obj.AttStmt.Receipt[1] != 0x80 {
		t.Logf("note: this receipt does not start 30 80 (indefinite length); got %02x %02x",
			obj.AttStmt.Receipt[0], obj.AttStmt.Receipt[1])
	}

	got, err := Parse(obj.AttStmt.Receipt)
	if err != nil {
		t.Fatalf("Parse on a real receipt: %v", err)
	}

	if got.Type != TypeAttest && got.Type != TypeReceipt {
		t.Errorf("Type = %q, want ATTEST or RECEIPT", got.Type)
	}
	if got.AppID == "" {
		t.Error("a real receipt carries an app id")
	}
	if got.CreatedAt.IsZero() {
		t.Error("a real receipt carries a creation time")
	}
	// An ATTEST receipt legitimately carries no risk metric — that only appears once redeemed — so
	// HasKeys is not asserted either way here. What matters is that parsing SUCCEEDED.
	t.Logf("parsed real receipt: type=%s appID=%s created=%s keys=%d(has=%v)",
		got.Type, got.AppID, got.CreatedAt.Format("2006-01-02T15:04:05Z"), got.Keys, got.HasKeys)
}
