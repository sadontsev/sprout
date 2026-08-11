// Package hashing is the one definition of how Canopy hashes the secrets it
// must recognise but must not store.
//
// Push tokens, vouch nonces and tenant secrets all arrive raw per request and
// are compared against a stored digest. Having a single function for it means
// there is no way for two call sites to disagree about the encoding — a
// mismatch there fails silently, in the worst possible way: the check simply
// never matches, and the feature quietly stops working.
package hashing

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
)

// Digest returns the lowercase hex SHA-256 of s.
func Digest(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// Equal compares two digests in constant time.
func Equal(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
