//go:build manual

// A live diagnostic for "the fraud sweep logs 401 and I cannot tell whose fault it is".
//
// Not part of the suite: it talks to Apple, needs a real .p8, and is run by hand.
//
//	go test -tags manual -run TestKeyProbe -v ./internal/fraud/ \
//	  -args -key ~/keys/AuthKey_XXXXXXXXXX.p8 -kid XXXXXXXXXX -team YYYYYYYYYY
//
// # Why this exists
//
// Every endpoint involved answers a 401 that carries no diagnosis:
//
//   - `attestationData` returns a BARE 401 with an empty body to any request at all, including one
//     with no Authorization header. It cannot distinguish anything.
//   - `validate_device_token` returns "Unable to verify authorization token" — and returns the very
//     same string for a deliberately WRONG key id, so it will not tell you whether Apple knows your
//     key. (It does at least separate a missing token, which is a 400.)
//
// So a 401 alone leaves four live suspects: the JWT is malformed, the team id is wrong, the key
// lacks the DeviceCheck service, or the key has not propagated yet (Apple states up to 24 hours).
//
// # What makes it conclusive
//
// The CONTROL. Run this against a key you already know works — the APNs key — and APNs answers
// `400 BadDeviceToken`, which means authentication PASSED and it merely disliked the fake device
// token. That single result clears the JWT construction, the ES256 R||S encoding, the team id and
// the clock in one shot, because the same code minted it.
//
// With the control passing, a 401 for the other key cannot be blamed on this code:
//
//	APNs 400 BadDeviceToken       -> the key is live and propagated (and is an APNs key)
//	APNs 403 InvalidProviderToken -> APNs does not accept it; consistent with a DeviceCheck-only
//	                                 key, and also with one that has not propagated
//	DeviceCheck 400               -> the DeviceCheck token was ACCEPTED; the key is good
//	DeviceCheck 401               -> not propagated yet, or DeviceCheck is not ticked on the key
//
// If the control passes and DeviceCheck still 401s more than 24 hours after the key was created,
// stop waiting: create a new key with the DeviceCheck service ticked.
package fraud

import (
	"bytes"
	"flag"
	"io"
	"net/http"
	"os"
	"testing"
	"time"
)

var (
	keyPath = flag.String("key", "", "path to the .p8 to probe")
	keyID   = flag.String("kid", "", "its key id")
	teamID  = flag.String("team", "", "the 10-character team id")
	topic   = flag.String("topic", "com.mvks5.bambu", "bundle id, for the APNs control")
)

func TestKeyProbe(t *testing.T) {
	pem, err := os.ReadFile(*keyPath)
	if err != nil {
		t.Fatalf("read %s: %v", *keyPath, err)
	}
	c, err := NewClient("", *keyID, *teamID, pem)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	tok, err := c.token(time.Now())
	if err != nil {
		t.Fatalf("token: %v", err)
	}

	dcStatus := probeDeviceCheck(t, tok)
	apnsStatus := probeAPNs(t, tok, *topic)

	switch {
	case dcStatus == 400:
		t.Logf("VERDICT: DeviceCheck ACCEPTED the token. Key %s is good.", *keyID)
	case apnsStatus == 400:
		t.Errorf("VERDICT: this key authenticates to APNs, so it is live and propagated — "+
			"therefore the DeviceCheck 401 means the DEVICECHECK SERVICE IS NOT ENABLED on key %s. "+
			"Create a new key with it ticked.", *keyID)
	default:
		t.Errorf("VERDICT: Apple accepts this key nowhere. Either it has not propagated (wait out "+
			"the 24 hours from creation), or key %s does not exist for team %s. Re-run the same "+
			"command against your APNs key: if THAT returns 400 BadDeviceToken, this code and the "+
			"team id are fine and the fault is the key itself.", *keyID, *teamID)
	}
}

func probeDeviceCheck(t *testing.T, token string) int {
	t.Helper()
	body := []byte(`{"device_token":"QUFB","transaction_id":"probe","timestamp":1786500000000}`)
	req, _ := http.NewRequest("POST",
		"https://api.devicecheck.apple.com/v1/validate_device_token", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	return report(t, "DeviceCheck validate_device_token", req)
}

func probeAPNs(t *testing.T, token, bundleID string) int {
	t.Helper()
	// Syntactically valid, certainly nonexistent: auth is checked before the token is looked up.
	device := "00000000000000000000000000000000000000000000000000000000000000ff"
	req, _ := http.NewRequest("POST", "https://api.push.apple.com/3/device/"+device,
		bytes.NewReader([]byte(`{"aps":{"alert":"probe"}}`)))
	req.Header.Set("authorization", "bearer "+token)
	req.Header.Set("apns-topic", bundleID)
	req.Header.Set("apns-push-type", "alert")
	return report(t, "APNs control", req)
}

func report(t *testing.T, label string, req *http.Request) int {
	t.Helper()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s: %v", label, err)
	}
	defer resp.Body.Close()
	payload, _ := io.ReadAll(resp.Body)
	t.Logf("%-34s -> HTTP %d %q", label, resp.StatusCode, string(payload))
	return resp.StatusCode
}
