package hashing

import (
	"strings"
	"testing"
)

func TestDigestIsStableLowercaseHexSHA256(t *testing.T) {
	// Known-answer: SHA-256("") — pins the algorithm and the encoding, so a
	// future refactor cannot silently change what a stored digest means.
	if got, want := Digest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"; got != want {
		t.Errorf("Digest(%q) = %q, want %q", "", got, want)
	}
	if got, want := Digest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"; got != want {
		t.Errorf("Digest(%q) = %q, want %q", "abc", got, want)
	}
}

func TestDigestIsDeterministicAndDistinguishing(t *testing.T) {
	// The two equal inputs are built DIFFERENTLY on purpose. Written as
	// `Digest("x") != Digest("x")` this is a tautology for a pure function — it cannot fail, and
	// staticcheck says so (SA4000). The property that actually matters is that a value
	// reconstructed later, from parts, digests the same as the one stored earlier; that is what
	// matching a stored digest depends on, and it is not something a literal-vs-itself can show.
	same := "token-" + strings.ToUpper("a")
	if Digest(same) != Digest("token-A") {
		t.Error("the same input must always digest the same, or a stored digest can never be matched again")
	}
	if Digest("token-A") == Digest("token-B") {
		t.Error("different inputs must digest differently")
	}
}

func TestEqual(t *testing.T) {
	a := Digest("token-A")
	if !Equal(a, Digest("token-A")) {
		t.Error("equal digests must compare equal")
	}
	if Equal(a, Digest("token-B")) {
		t.Error("different digests must not compare equal")
	}
	if Equal(a, "") || Equal("", a) {
		t.Error("an empty digest must never match a real one")
	}
	if Equal(a, a[:len(a)-1]) {
		t.Error("a truncated digest must not match")
	}
}
