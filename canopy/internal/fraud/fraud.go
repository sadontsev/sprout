// Package fraud reads Apple's App Attest fraud-assessment metric.
//
// This bounds the residual the threat model concedes. Everything else in Canopy establishes that a
// claim came from a genuine, unmodified build of this app on real Apple hardware — but a jailbroken
// device running a hooked copy still attests, and no signature distinguishes it. What Apple will
// tell us, and only Apple, is *how many keys one device has attested*: the shape of a single
// handset minting identities. That answer is reached by redeeming the receipt captured at
// attestation time.
//
// The receipt is why this could be deferred without cost. Canopy has stored one for every attested
// key since the first claim, and Apple issues them only at attestation — so switching this on later
// reads history rather than starting a clock.
//
// Redemption authenticates with a key from Certificates, Identifiers & Profiles that has the
// **DeviceCheck** service enabled — NOT an App Store Connect API key, and not the APNs key, though
// all three arrive as `AuthKey_<id>.p8` and are indistinguishable on disk. The JWT differs too: it
// is issued by the TEAM ID with no audience, where an App Store Connect token carries an issuer
// UUID and `aud: appstoreconnect-v1`. Signing with the wrong one answers 401 with no hint which of
// the three it was.
//
// A deployment without such a key does not run this at all: the metric refines a bound that already
// holds, so its absence must degrade the signal, never the service.
package fraud

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Redemption hosts. A receipt minted in the development attestation environment can only be
// redeemed against the development host: the two environments do not cross here any more than they
// do for the aaguid, and crossing them answers 400 rather than anything diagnostic.
const (
	ProductionHost  = "https://data.appattest.apple.com/v1/attestationData"
	DevelopmentHost = "https://data-development.appattest.apple.com/v1/attestationData"
)

var (
	// ErrNotConfigured means no DeviceCheck key is present. It is a deployment choice, not a
	// failure, and callers must not log it as one.
	ErrNotConfigured = errors.New("fraud: no DeviceCheck key configured")
	// ErrRedeem wraps every transport- and status-level failure of redemption.
	ErrRedeem = errors.New("fraud: could not redeem the receipt")
	// ErrThrottled is Apple refusing because the receipt was redeemed too recently. Distinct
	// because the answer is to wait for NotBefore, not to retry or to alert.
	ErrThrottled = errors.New("fraud: redemption throttled")
	// ErrMalformed means the bytes are not a receipt Canopy can read.
	ErrMalformed = errors.New("fraud: receipt is not in the expected form")
	// ErrUnauthorized is Apple rejecting the token itself. It says nothing about any receipt, so it
	// must not be charged against one: the honest cause is a key without the DeviceCheck service
	// ticked, and backing off the receipts would hide the real fault behind a day of silence.
	ErrUnauthorized = errors.New("fraud: Apple rejected the DeviceCheck token")
)

// Receipt types. Apple issues an ATTEST receipt at attestation; redeeming one yields a RECEIPT,
// and only a RECEIPT carries the risk metric. So the metric is unavailable until the first
// redemption — an ATTEST receipt reporting no metric is correct, not broken.
const (
	TypeAttest  = "ATTEST"
	TypeReceipt = "RECEIPT"
)

// Field type codes inside the receipt payload. The fields are identified by these integers, NOT by
// any human-readable label — scanning the bytes for the words Apple's documentation uses finds
// nothing and reports every device as clean, which is why this parses the structure properly.
const (
	fieldAppID       = 2
	fieldReceiptType = 6
	fieldCreation    = 12
	fieldRiskMetric  = 17
	fieldNotBefore   = 19
	fieldExpiration  = 21
)

// Assessment is what one redeemed receipt says.
type Assessment struct {
	// Type is ATTEST or RECEIPT.
	Type string
	// AppID is the app the receipt was issued to. Checked by the caller against its own, because a
	// receipt from another app would otherwise contribute a meaningless metric.
	AppID string
	// Keys is Apple's risk metric: how many keys this device has attested for this app.
	Keys int
	// HasKeys distinguishes "the metric says zero" from "there is no metric" — an ATTEST receipt
	// carries none, and collapsing the two would render every unredeemed key permanently innocent.
	HasKeys bool
	// Receipt is the refreshed receipt, which supersedes the stored one for the next redemption.
	Receipt []byte
	// NotBefore is when this receipt may next be redeemed. Apple throttles on it, so a caller that
	// ignores it gets ErrThrottled instead of an answer.
	NotBefore  time.Time
	Expiration time.Time
	CreatedAt  time.Time
}

// SuspiciousKeyCount is where a key count becomes worth an operator's attention.
//
// Deliberately generous. An honest install attests once and re-attests after a reinstall, a device
// restore, or a Canopy restore that predates the key — a household that tinkers reaches several
// over a year without doing anything wrong, and a tight threshold would fire loudest at exactly
// those users. What this looks for is one handset minting identities, which does not resemble that.
const SuspiciousKeyCount = 25

// Suspicious reports whether this assessment warrants an alert. False when there is no metric:
// absence of evidence is not evidence, and treating it as a hit would alert on every key that has
// never been redeemed.
func (a Assessment) Suspicious() bool { return a.HasKeys && a.Keys >= SuspiciousKeyCount }

// Client redeems receipts with Apple.
type Client struct {
	HTTP *http.Client
	// Host pins every redemption to one URL. Empty — the normal deployment — means each receipt
	// goes to the host matching the environment its key attested in, which is the only correct
	// choice when one Canopy serves both TestFlight and development installs.
	Host  string
	KeyID string
	// TeamID is the 10-character team identifier, and it is the JWT's `iss`. An App Store Connect
	// issuer UUID here fails as 401.
	TeamID string
	key    *ecdsa.PrivateKey
}

// NewClient parses a DeviceCheck .p8 key. It returns ErrNotConfigured — not an error worth stopping
// for — when the deployment has supplied nothing.
//
// host is normally empty; see Client.Host.
func NewClient(host, keyID, teamID string, keyPEM []byte) (*Client, error) {
	if keyID == "" || teamID == "" || len(keyPEM) == 0 {
		return nil, ErrNotConfigured
	}
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return nil, errors.New("fraud: DeviceCheck key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("fraud: parsing DeviceCheck key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("fraud: DeviceCheck key is %T, want ECDSA", parsed)
	}
	return &Client{
		HTTP:   &http.Client{Timeout: 20 * time.Second},
		Host:   host,
		KeyID:  keyID,
		TeamID: teamID,
		key:    key,
	}, nil
}

// HostFor picks the redemption host matching the environment a key attested in. The values are the
// ones internal/appattest records, so a typo here surfaces as a 400 from Apple rather than silently
// asking the wrong environment.
//
// Unknown environments resolve to production deliberately: the development host is the weaker
// check, and defaulting to it would let a mislabelled key be assessed against the wrong population.
func HostFor(environment string) string {
	if environment == "development" {
		return DevelopmentHost
	}
	return ProductionHost
}

// hostFor resolves where one receipt goes: an explicit pin if the deployment set one, otherwise the
// host matching the key's own attestation environment.
func (c *Client) hostFor(environment string) string {
	if c.Host != "" {
		return c.Host
	}
	return HostFor(environment)
}

// Redeem exchanges a stored receipt for an assessment.
//
// environment is the environment the KEY attested in — not the environment Canopy is running as,
// and not the APNs environment of any binding. Three nearby questions with three different answers;
// this one selects the redemption host.
func (c *Client) Redeem(ctx context.Context, receipt []byte, environment string, now time.Time) (Assessment, error) {
	if c == nil {
		return Assessment{}, ErrNotConfigured
	}
	token, err := c.token(now)
	if err != nil {
		return Assessment{}, err
	}

	body := []byte(base64.StdEncoding.EncodeToString(receipt))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.hostFor(environment), bytes.NewReader(body))
	if err != nil {
		return Assessment{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	// Apple's documented content type for this endpoint. text/plain answers 400.
	req.Header.Set("Content-Type", "application/octet-stream")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return Assessment{}, fmt.Errorf("%w: %v", ErrRedeem, err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusTooManyRequests:
		return Assessment{}, ErrThrottled
	case http.StatusUnauthorized, http.StatusForbidden:
		// Apple sends an EMPTY body here, so there is nothing to quote and nothing that names the
		// cause. In practice it is a key that lacks the DeviceCheck service — the endpoint checks
		// the token before it looks at the receipt, which is why every receipt fails identically.
		return Assessment{}, fmt.Errorf("%w (status %d): check the key has the DeviceCheck service enabled",
			ErrUnauthorized, resp.StatusCode)
	default:
		return Assessment{}, fmt.Errorf("%w: status %d: %s", ErrRedeem, resp.StatusCode,
			strings.TrimSpace(string(raw)))
	}

	refreshed, err := base64.StdEncoding.DecodeString(string(bytes.TrimSpace(raw)))
	if err != nil {
		return Assessment{}, fmt.Errorf("%w: response is not base64", ErrRedeem)
	}
	return Parse(refreshed)
}

// token mints the ES256 JWT the DeviceCheck endpoints expect.
//
// `iss` is the TEAM ID and there is no `aud`. This is not the App Store Connect token shape — that
// one carries an issuer UUID and `aud: appstoreconnect-v1`, and sending it here answers 401 without
// saying which field was wrong.
func (c *Client) token(now time.Time) (string, error) {
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": c.KeyID, "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"iss": c.TeamID,
		"iat": now.Unix(),
		"exp": now.Add(10 * time.Minute).Unix(),
	})
	if err != nil {
		return "", err
	}
	signing := b64(header) + "." + b64(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	// JOSE wants the fixed-width R||S pair, not the ASN.1 sequence ecdsa.SignASN1 produces. Apple
	// rejects the latter as an invalid token, with no hint that the encoding is the problem.
	size := (c.key.Curve.Params().BitSize + 7) / 8
	sig := make([]byte, 2*size)
	r.FillBytes(sig[:size])
	s.FillBytes(sig[size:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// --- receipt parsing ---

// A receipt is CMS SignedData whose encapsulated content is a set of typed attributes.
//
// Canopy does NOT verify the receipt's own signature chain here, and that is deliberate rather than
// an omission: these bytes came back over TLS from Apple, in a response to a request authenticated
// with the operator's own App Store Connect key. The signature would re-establish a provenance the
// transport already gives, and verifying it would mean carrying a CMS verifier and Apple's receipt
// root for no additional property. The bytes are never trusted from any other source.
type contentInfo struct {
	ContentType asn1.ObjectIdentifier
	Content     signedData `asn1:"explicit,tag:0"`
}

type signedData struct {
	Version          int
	DigestAlgorithms asn1.RawValue
	EncapContentInfo encapContentInfo
	Certificates     asn1.RawValue `asn1:"optional,tag:0"`
	CRLs             asn1.RawValue `asn1:"optional,tag:1"`
	SignerInfos      asn1.RawValue
}

type encapContentInfo struct {
	EContentType asn1.ObjectIdentifier
	EContent     []byte `asn1:"explicit,optional,tag:0"`
}

type receiptAttribute struct {
	Type    int
	Version int
	Value   []byte
}

// Parse reads the fields Canopy acts on out of a receipt.
func Parse(receipt []byte) (Assessment, error) {
	out := Assessment{Receipt: receipt}

	var ci contentInfo
	if _, err := asn1.Unmarshal(receipt, &ci); err != nil {
		return out, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	payload := ci.Content.EncapContentInfo.EContent
	if len(payload) == 0 {
		return out, fmt.Errorf("%w: no encapsulated content", ErrMalformed)
	}

	var set asn1.RawValue
	if _, err := asn1.Unmarshal(payload, &set); err != nil {
		return out, fmt.Errorf("%w: %v", ErrMalformed, err)
	}

	rest := set.Bytes
	for len(rest) > 0 {
		var attr receiptAttribute
		var err error
		rest, err = asn1.Unmarshal(rest, &attr)
		if err != nil {
			return out, fmt.Errorf("%w: attribute: %v", ErrMalformed, err)
		}
		switch attr.Type {
		case fieldAppID:
			out.AppID = text(attr.Value)
		case fieldReceiptType:
			out.Type = text(attr.Value)
		case fieldRiskMetric:
			n, err := number(attr.Value)
			if err != nil {
				// Loud on purpose. A metric that is present but unreadable must not be reported as
				// "no metric", which reads as innocent forever.
				return out, fmt.Errorf("%w: risk metric: %v", ErrMalformed, err)
			}
			out.Keys, out.HasKeys = n, true
		case fieldNotBefore:
			out.NotBefore = timestamp(attr.Value)
		case fieldExpiration:
			out.Expiration = timestamp(attr.Value)
		case fieldCreation:
			out.CreatedAt = timestamp(attr.Value)
		}
	}
	if out.Type == "" {
		return out, fmt.Errorf("%w: no receipt type field", ErrMalformed)
	}
	return out, nil
}

// text reads a string field. The attribute's value IS an OCTET STRING whose content is the UTF-8
// bytes directly, so the raw content is the answer; the DER attempt afterwards is tolerance for a
// nested string, not the expected shape.
func text(raw []byte) string {
	if s := strings.TrimSpace(string(raw)); isPrintable(s) {
		return s
	}
	var s string
	if _, err := asn1.Unmarshal(raw, &s); err == nil {
		return s
	}
	return strings.TrimSpace(string(raw))
}

func isPrintable(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !unicode.IsPrint(r) {
			return false
		}
	}
	return true
}

// number reads the risk metric. Apple encodes it as a DECIMAL STRING, not a DER integer — the
// integer attempt afterwards is tolerance only. Anything unreadable is an error rather than a zero,
// because a zero here reads as "this device is clean".
func number(raw []byte) (int, error) {
	if n, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil {
		return n, nil
	}
	var n int
	if _, err := asn1.Unmarshal(raw, &n); err == nil {
		return n, nil
	}
	return 0, fmt.Errorf("neither a decimal string nor a DER integer (%d bytes)", len(raw))
}

// timestamp reads an RFC 3339 date field. A zero time means "not stated", which every caller
// already has to handle for an ATTEST receipt.
func timestamp(raw []byte) time.Time {
	t, err := time.Parse(time.RFC3339, text(raw))
	if err != nil {
		return time.Time{}
	}
	return t.UTC()
}
