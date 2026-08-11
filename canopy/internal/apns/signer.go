package apns

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"sync"
	"time"
)

// TokenLifetime is how long a provider token is reused before being re-signed.
// Apple rejects tokens older than 60 minutes and refuses to mint them faster
// than once per 20; 40 minutes sits in the middle of that window.
const TokenLifetime = 40 * time.Minute

// Signer mints APNs provider tokens for one key. One key per environment: modern
// APNs keys are environment-scoped, so a signer is never shared across gateways.
type Signer struct {
	keyID  string
	teamID string
	key    *ecdsa.PrivateKey

	mu       sync.Mutex
	cached   string
	issuedAt time.Time
}

// NewSigner parses a PKCS#8 EC private key in PEM form — the shape of the .p8
// file downloaded from Apple.
func NewSigner(keyID, teamID string, keyPEM []byte) (*Signer, error) {
	if keyID == "" || teamID == "" {
		return nil, errors.New("apns: key id and team id are both required")
	}
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return nil, errors.New("apns: signing key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: parsing signing key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("apns: signing key is %T, want an ECDSA key", parsed)
	}
	return &Signer{keyID: keyID, teamID: teamID, key: key}, nil
}

// Token returns a provider token valid at now, minting a new one only when the
// cached token has aged past TokenLifetime.
func (s *Signer) Token(now time.Time) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cached != "" && now.Sub(s.issuedAt) < TokenLifetime {
		return s.cached, nil
	}

	header, err := json.Marshal(map[string]string{
		"alg": "ES256",
		"kid": s.keyID,
	})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"iss": s.teamID,
		"iat": now.Unix(),
	})
	if err != nil {
		return "", err
	}

	signingInput := b64(header) + "." + b64(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, sv, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		return "", err
	}

	// APNs wants the raw r||s form, each padded to the curve size — not the
	// ASN.1 encoding ecdsa.SignASN1 produces.
	size := (s.key.Curve.Params().BitSize + 7) / 8
	sig := make([]byte, 2*size)
	r.FillBytes(sig[:size])
	sv.FillBytes(sig[size:])

	s.cached = signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
	s.issuedAt = now
	return s.cached, nil
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// verifyForTest is used by the package's own tests to check a minted token
// against the public half. It lives here so the raw-signature encoding above has
// exactly one definition.
func verifyForTest(pub *ecdsa.PublicKey, token string) bool {
	var dot1, dot2 = -1, -1
	for i := 0; i < len(token); i++ {
		if token[i] == '.' {
			if dot1 < 0 {
				dot1 = i
			} else {
				dot2 = i
			}
		}
	}
	if dot1 < 0 || dot2 < 0 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(token[dot2+1:])
	if err != nil || len(sig)%2 != 0 {
		return false
	}
	digest := sha256.Sum256([]byte(token[:dot2]))
	half := len(sig) / 2
	return ecdsa.Verify(pub,
		digest[:],
		new(big.Int).SetBytes(sig[:half]),
		new(big.Int).SetBytes(sig[half:]))
}
