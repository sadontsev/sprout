package apns

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client sends pushes to APNs. It holds one signer per environment, because
// modern APNs keys are environment-scoped: the gateway retry has to swap the
// host and the signing key together or it never converges.
type Client struct {
	HTTP     *http.Client
	BundleID string

	signers map[Environment]*Signer
	// hosts overrides the gateway per environment. Production leaves it nil;
	// tests point both environments at an httptest server.
	hosts map[Environment]string
}

// NewClient builds a client. Both signers are required: a deployment missing one
// cannot perform the gateway retry, and would turn a mislabelled environment into
// a permanent, silent delivery failure.
func NewClient(bundleID string, sandbox, production *Signer) (*Client, error) {
	if bundleID == "" {
		return nil, errors.New("apns: bundle id is required")
	}
	if sandbox == nil || production == nil {
		return nil, errors.New("apns: a signer is required for each environment")
	}
	return &Client{
		HTTP:     &http.Client{Timeout: 10 * time.Second},
		BundleID: bundleID,
		signers:  map[Environment]*Signer{Sandbox: sandbox, Production: production},
		hosts:    map[Environment]string{},
	}, nil
}

// SetHostForTest points one environment at an arbitrary base URL.
func (c *Client) SetHostForTest(env Environment, baseURL string) { c.hosts[env] = baseURL }

// Push is one request. Payload is opaque: Canopy never inspects or constructs
// Live Activity content.
type Push struct {
	Token       string
	Environment Environment
	Type        PushType
	Priority    int
	Payload     []byte
	// CollapseID, when set, is passed through as apns-collapse-id.
	CollapseID string
}

// Send delivers p, retrying once on the other gateway if APNs reports
// BadDeviceToken. The returned Result reports whether the retry corrected the
// environment, so the caller can persist the correction instead of hitting the
// same mislabel forever.
func (c *Client) Send(ctx context.Context, p Push, now time.Time) (Result, Environment) {
	if len(p.Payload) > MaxPayloadBytes {
		return Result{
			Outcome: Refused,
			Err:     fmt.Errorf("apns: payload is %d bytes, limit is %d", len(p.Payload), MaxPayloadBytes),
		}, p.Environment
	}
	if _, err := p.Type.Topic(c.BundleID); err != nil {
		return Result{Outcome: Refused, Err: err}, p.Environment
	}

	res := c.send(ctx, p, p.Environment, now)
	if res.Outcome == Delivered && res.APNsStatus == 400 && res.APNsReason == "BadDeviceToken" {
		other := p.Environment.Other()
		if retry := c.send(ctx, p, other, now); retry.Outcome == Delivered && retry.APNsStatus == 200 {
			return retry, other
		}
	}
	return res, p.Environment
}

func (c *Client) send(ctx context.Context, p Push, env Environment, now time.Time) Result {
	signer, ok := c.signers[env]
	if !ok {
		return Result{Outcome: Refused, Err: fmt.Errorf("apns: no signing key for %s", env)}
	}
	token, err := signer.Token(now)
	if err != nil {
		return Result{Outcome: Refused, Err: err}
	}
	topic, err := p.Type.Topic(c.BundleID)
	if err != nil {
		return Result{Outcome: Refused, Err: err}
	}

	base := c.hosts[env]
	if base == "" {
		base = "https://" + env.Host()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		base+"/3/device/"+p.Token, bytes.NewReader(p.Payload))
	if err != nil {
		return Result{Outcome: Refused, Err: err}
	}
	req.Header.Set("authorization", "bearer "+token)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", p.Type.APNSPushTypeHeader())
	req.Header.Set("apns-priority", fmt.Sprint(ClampPriority(p.Priority)))
	req.Header.Set("content-type", "application/json")
	if p.CollapseID != "" {
		req.Header.Set("apns-collapse-id", p.CollapseID)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		// Never reached APNs, or the answer never arrived. This is not a
		// statement about the token.
		return Result{Outcome: Transport, Err: err}
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var payload struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(body, &payload)

	return Result{
		Outcome:    Delivered,
		APNsStatus: resp.StatusCode,
		APNsReason: payload.Reason,
	}
}
