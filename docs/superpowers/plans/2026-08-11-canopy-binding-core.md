# Canopy Binding Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure decision core of Canopy — the binding state machine (R0–R3), the vouch gate, and the lease/dormancy/garbage-collection predicates — plus the SQLite store behind them, with table-driven tests that assert *which rule fired* on a single claim.

**Architecture:** Two packages with no I/O in the decision path. `internal/binding` is pure: it takes a already-verified claim plus the current row and returns a `Decision` describing which rule fired and what to write. `internal/store` owns SQLite and translates a `Decision` into a transaction. Crypto verification, APNs, and HTTP handlers are *later* plans and are deliberately out of scope here — the whole point of this slice is that the rules can be exhaustively tested with no fixtures, no network, and no clock.

**Tech Stack:** Go (stdlib), `modernc.org/sqlite` (pure-Go, cgo-free). No test framework beyond `testing`.

**Source spec:** `docs/superpowers/specs/2026-08-11-trellis-canopy-push-design.md` (revision 8). §5 is the state machine, §6 the storage and lifetimes.

## Global Constraints

- **Third-party dependency budget for all of Canopy: three.** `modernc.org/sqlite`, `golang.org/x/time/rate`, `github.com/fxamacker/cbor/v2`. Nothing else. This plan may only add `modernc.org/sqlite`.
- **No wall-clock reads inside decision code.** Every function that needs the time takes a `now time.Time` parameter. Ordering bugs between the lease, dormancy, and retention clocks were shipped twice in this design's history; they are only testable if time is injectable.
- **Leases and retention, exact values** (spec §6): `activity` — lease 72 h, hard delete at `lease_expiry + 7 d`; `start` and `device` — lease 30 d, hard delete at `lease_expiry + 90 d`.
- **Dormancy: 90 d**, computed as `now - max(last_delivery_at, last_successful_claim_at, created_at) > 90d`. **Not applicable to `activity`.** Rejected claims must never advance the dormancy clock — they stamp `last_failed_claim_at` only.
- **Retention must exceed dormancy** where dormancy applies: `lease + retention_after_lease > dormancy` (30 d + 90 d = 120 d > 90 d). Assert this arithmetically in a test so the constants cannot drift apart.
- **A live binding is `released_at IS NULL AND now < lease_expiry`.** Only live bindings count against the per-tenant cap of 500.
- **Every accepting rule** renews the lease, clears `released_at`, stamps `last_successful_claim_at`, and re-points `tenant` and `device_id`.
- **`binding_kind` is immutable after the first bind.** A claim disagreeing with the row is rejected with `KindMismatch` before the rules run.
- **Vouching is per token, per tenant, single-use, 10-minute expiry** (spec §5), and applies **only** to `binding_kind: device`. There is no standing per-install exemption — that was revision 7's cross-user takeover.
- Go module path: `github.com/mvks5/canopy`. Code lives in `canopy/` at the repo root.

---

### Task 1: Module scaffolding

**Files:**
- Create: `canopy/go.mod`
- Create: `canopy/README.md`
- Create: `canopy/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: a Go module rooted at `canopy/` with module path `github.com/mvks5/canopy`, so every later package imports as `github.com/mvks5/canopy/internal/...`.

- [ ] **Step 1: Create the module**

```bash
mkdir -p /Users/max/ai-projects/bambu-app/canopy
cd /Users/max/ai-projects/bambu-app/canopy && go mod init github.com/mvks5/canopy
```

- [ ] **Step 2: Write the README**

Create `canopy/README.md`:

```markdown
# Canopy

The owner-hosted APNs relay for Sprout. Holds the APNs signing keys and decides
who may push to which device token; understands nothing about Live Activities.

Design: `docs/superpowers/specs/2026-08-11-trellis-canopy-push-design.md`.

Canopy accepts inbound requests only. It never contacts a user's Bambuddy, and
it stores hashes, public keys and counters — never push payloads, never raw
tokens.

## Test

    go test ./...

## Dependency budget

Three, total, forever: `modernc.org/sqlite`, `golang.org/x/time/rate`,
`github.com/fxamacker/cbor/v2`. This service holds the signing keys for every
install of the app; its supply chain is part of its threat model.
```

- [ ] **Step 3: Write .gitignore**

Create `canopy/.gitignore`:

```
/canopy
*.db
*.db-wal
*.db-shm
```

- [ ] **Step 4: Verify the module builds**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go build ./... && go test ./...`
Expected: no output from build; `go test` prints `no test files` (exit 0).

- [ ] **Step 5: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add canopy/go.mod canopy/README.md canopy/.gitignore
git commit -m "feat(canopy): scaffold the Go module"
```

---

### Task 2: Domain types

**Files:**
- Create: `canopy/internal/binding/types.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `Kind`, `Rule`, `Reason`, `Claim`, `Row`, `Decision`, and the lease/retention/dormancy constants. Every later task in this plan uses these exact names.

- [ ] **Step 1: Write the types**

Create `canopy/internal/binding/types.go`:

```go
// Package binding implements Canopy's token-binding decision rules.
//
// Everything here is pure: no I/O, no wall clock, no crypto. Signature and
// attestation verification happen upstream and arrive as booleans, because the
// rules are the part of this design that has historically been wrong and they
// are only exhaustively testable when nothing else is in the way.
package binding

import "time"

// Kind is the binding_kind of a token. It is immutable after the first bind:
// it selects the lease and retention horizons, so letting a claim rewrite it
// would let an attacker relabel a device row as activity and collapse its
// retention.
type Kind string

const (
	KindActivity Kind = "activity"
	KindStart    Kind = "start"
	KindDevice   Kind = "device"
)

// Lease and retention horizons, per spec §6.
const (
	LeaseActivity     = 72 * time.Hour
	LeaseStartDevice  = 30 * 24 * time.Hour
	RetainActivity    = 7 * 24 * time.Hour
	RetainStartDevice = 90 * 24 * time.Hour
	Dormancy          = 90 * 24 * time.Hour
)

// Lease returns how long a fresh or renewed binding of this kind stays live.
func (k Kind) Lease() time.Duration {
	if k == KindActivity {
		return LeaseActivity
	}
	return LeaseStartDevice
}

// RetainAfterLease returns how long the row survives past lease expiry before
// hard deletion.
func (k Kind) RetainAfterLease() time.Duration {
	if k == KindActivity {
		return RetainActivity
	}
	return RetainStartDevice
}

// DormancyApplies reports whether a token of this kind can ever be re-bound by
// the dormancy path. Activity tokens die with their card long before 90 days,
// so the question never arises for them.
func (k Kind) DormancyApplies() bool { return k != KindActivity }

// NeedsVouch reports whether an unseen token of this kind must prove it is
// reachable on the claiming device before it may be bound. Only device tokens
// can receive the silent push that proves it; start and activity tokens cannot,
// which is a stated residual in spec §4 rather than a gap to paper over.
func (k Kind) NeedsVouch() bool { return k == KindDevice }

// Rule identifies which rule of spec §5 decided a claim. Tests assert on this
// rather than on the resulting row: a suite that checks each rule in isolation
// cannot catch two rules matching one input, which is how three revisions of
// overlapping guards survived review.
type Rule string

const (
	RuleR0 Rule = "R0" // unseen token, bind first-come (vouched if device)
	RuleR1 Rule = "R1" // pairing key matches the row
	RuleR2 Rule = "R2" // pairing key differs, attest key matches the row
	RuleR3 Rule = "R3" // nothing matched
)

// Reason is the refusal code returned to Trellis. Each is emitted by exactly
// one check so the client can say something true.
type Reason string

const (
	ReasonNone                   Reason = ""
	ReasonAttestationInvalid     Reason = "attestation_invalid"
	ReasonPairingSignatureInvalid Reason = "pairing_signature_invalid"
	ReasonKindMismatch           Reason = "kind_mismatch"
	ReasonVouchRequired          Reason = "vouch_required"
	ReasonPairingMismatch        Reason = "pairing_mismatch"
)

// Claim is one already-verified claim. AttestProofValid and PairingSigValid are
// the outcome of the crypto layer; VouchOK is the outcome of the vouch layer.
type Claim struct {
	TokenHash        string
	Kind             Kind
	Tenant           string
	DeviceID         string
	AttestKeyID      string
	PairingPublicKey string
	APNSEnvironment  string

	AttestProofValid bool
	PairingSigValid  bool

	// VouchOK reports that this exact token was vouched by this exact tenant
	// with an unexpired, unconsumed nonce. It is per token and per tenant: a
	// standing per-install exemption was revision 7's cross-user takeover.
	VouchOK bool
}

// Row is the stored binding, or nil when the token is UNSEEN.
type Row struct {
	TokenHash             string
	Kind                  Kind
	Tenant                string
	DeviceID              string
	AttestKeyID           string
	PairingPublicKey      string
	APNSEnvironment       string
	LeaseExpiry           time.Time
	LastDeliveryAt        time.Time
	LastSuccessfulClaimAt time.Time
	LastFailedClaimAt     time.Time
	ReleasedAt            *time.Time
	CreatedAt             time.Time
}

// Decision is what the store must persist. Accepted decisions always renew the
// lease, clear ReleasedAt, stamp LastSuccessfulClaimAt, and re-point Tenant and
// DeviceID — stated once, in Decide, because stating it per-rule is how an
// earlier revision lost the ReleasedAt clear.
type Decision struct {
	Rule     Rule
	Accepted bool
	Reason   Reason
	Row      *Row // the row to write when Accepted; nil otherwise
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go build ./...`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add canopy/internal/binding/types.go
git commit -m "feat(canopy): binding domain types and lifetime constants"
```

---

### Task 3: The constants are ordered correctly

**Files:**
- Create: `canopy/internal/binding/lifetime_test.go`

**Interfaces:**
- Consumes: `Kind`, `Lease()`, `RetainAfterLease()`, `Dormancy`, `DormancyApplies()` from Task 2.
- Produces: nothing consumed later; this is a guard test.

This is first because two earlier revisions of the design shipped a garbage collector that deleted rows *before* the dormancy rule could ever fire, and a test written from the wrong formula would have failed on the correct constants. The relation is `lease + retain > dormancy`, with both terms measured from the same last-activity epoch.

- [ ] **Step 1: Write the failing test**

Create `canopy/internal/binding/lifetime_test.go`:

```go
package binding

import "testing"

func TestRetentionOutlivesDormancy(t *testing.T) {
	for _, k := range []Kind{KindActivity, KindStart, KindDevice} {
		if !k.DormancyApplies() {
			continue
		}
		total := k.Lease() + k.RetainAfterLease()
		if total <= Dormancy {
			t.Errorf("kind %s: lease(%v)+retain(%v)=%v must exceed dormancy %v, "+
				"or a row is deleted before it can ever be re-bound",
				k, k.Lease(), k.RetainAfterLease(), total, Dormancy)
		}
	}
}

func TestActivityIsExemptFromDormancy(t *testing.T) {
	if KindActivity.DormancyApplies() {
		t.Fatal("activity rows are deleted 10 days after lease expiry, far " +
			"inside the 90-day dormancy window; claiming dormancy applies to " +
			"them would make the arithmetic above unsatisfiable")
	}
}

func TestOnlyDeviceTokensCanBeVouched(t *testing.T) {
	if !KindDevice.NeedsVouch() {
		t.Error("device tokens must be vouched: they are the only kind that can receive a silent push")
	}
	if KindStart.NeedsVouch() || KindActivity.NeedsVouch() {
		t.Error("start and activity tokens cannot receive a silent push, so requiring a vouch would make them unbindable")
	}
}
```

- [ ] **Step 2: Run the tests**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./internal/binding/ -run 'TestRetention|TestActivityIsExempt|TestOnlyDevice' -v`
Expected: PASS (all three). These guard constants already written in Task 2; if any fails, Task 2's constants are wrong — fix them, not the test.

- [ ] **Step 3: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add canopy/internal/binding/lifetime_test.go
git commit -m "test(canopy): pin the lease/retention/dormancy ordering"
```

---

### Task 4: The decision function

**Files:**
- Create: `canopy/internal/binding/decide.go`
- Create: `canopy/internal/binding/decide_test.go`

**Interfaces:**
- Consumes: every type from Task 2.
- Produces: `func Decide(c Claim, row *Row, now time.Time) Decision`. Task 7 (store) calls this and persists `Decision.Row`.

- [ ] **Step 1: Write the failing test**

Create `canopy/internal/binding/decide_test.go`:

```go
package binding

import (
	"testing"
	"time"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

// validClaim is a well-formed device claim from a vouched token. Individual
// tests mutate one field, so every case reads as "this input, this rule".
func validClaim() Claim {
	return Claim{
		TokenHash:        "tok-A",
		Kind:             KindDevice,
		Tenant:           "tenant-1",
		DeviceID:         "dev-1",
		AttestKeyID:      "attest-1",
		PairingPublicKey: "pair-1",
		APNSEnvironment:  "production",
		AttestProofValid: true,
		PairingSigValid:  true,
		VouchOK:          true,
	}
}

func boundRow() *Row {
	return &Row{
		TokenHash:             "tok-A",
		Kind:                  KindDevice,
		Tenant:                "tenant-1",
		DeviceID:              "dev-1",
		AttestKeyID:           "attest-1",
		PairingPublicKey:      "pair-1",
		APNSEnvironment:       "production",
		LeaseExpiry:           t0.Add(KindDevice.Lease()),
		LastDeliveryAt:        t0,
		LastSuccessfulClaimAt: t0,
		CreatedAt:             t0,
	}
}

func TestDecide(t *testing.T) {
	released := t0
	cases := []struct {
		name     string
		claim    func(c *Claim)
		row      *Row
		wantRule Rule
		wantOK   bool
		wantWhy  Reason
	}{
		{
			name:     "unseen device token with a vouch binds",
			row:      nil,
			wantRule: RuleR0, wantOK: true,
		},
		{
			name:     "unseen device token without a vouch is refused",
			claim:    func(c *Claim) { c.VouchOK = false },
			row:      nil,
			wantRule: RuleR0, wantOK: false, wantWhy: ReasonVouchRequired,
		},
		{
			name:     "unseen start token binds without a vouch",
			claim:    func(c *Claim) { c.Kind = KindStart; c.VouchOK = false },
			row:      nil,
			wantRule: RuleR0, wantOK: true,
		},
		{
			name:     "matching pairing key takes R1",
			row:      boundRow(),
			wantRule: RuleR1, wantOK: true,
		},
		{
			name:     "R1 fires even when the attest key changed, because reinstall rotates it",
			claim:    func(c *Claim) { c.AttestKeyID = "attest-2" },
			row:      boundRow(),
			wantRule: RuleR1, wantOK: true,
		},
		{
			name:     "new pairing key with the row's attest key takes R2",
			claim:    func(c *Claim) { c.PairingPublicKey = "pair-2" },
			row:      boundRow(),
			wantRule: RuleR2, wantOK: true,
		},
		{
			name:     "neither anchor matches is refused",
			claim:    func(c *Claim) { c.PairingPublicKey = "pair-2"; c.AttestKeyID = "attest-2" },
			row:      boundRow(),
			wantRule: RuleR3, wantOK: false, wantWhy: ReasonPairingMismatch,
		},
		{
			name:     "a vouch is never required against an existing row",
			claim:    func(c *Claim) { c.VouchOK = false },
			row:      boundRow(),
			wantRule: RuleR1, wantOK: true,
		},
		{
			name: "an expired lease is still anchored, not first-claimable",
			claim: func(c *Claim) {
				c.PairingPublicKey = "pair-attacker"
				c.AttestKeyID = "attest-attacker"
				c.Tenant = "tenant-2"
			},
			row: func() *Row {
				r := boundRow()
				r.LeaseExpiry = t0.Add(-time.Hour)
				return r
			}(),
			wantRule: RuleR3, wantOK: false, wantWhy: ReasonPairingMismatch,
		},
		{
			name: "a released row is still anchored, not first-claimable",
			claim: func(c *Claim) {
				c.PairingPublicKey = "pair-attacker"
				c.AttestKeyID = "attest-attacker"
				c.Tenant = "tenant-2"
			},
			row: func() *Row {
				r := boundRow()
				r.ReleasedAt = &released
				return r
			}(),
			wantRule: RuleR3, wantOK: false, wantWhy: ReasonPairingMismatch,
		},
		{
			name:     "a kind that disagrees with the row is refused before the rules",
			claim:    func(c *Claim) { c.Kind = KindActivity },
			row:      boundRow(),
			wantOK:   false, wantWhy: ReasonKindMismatch,
		},
		{
			name:     "an invalid attest proof never reaches the rules",
			claim:    func(c *Claim) { c.AttestProofValid = false },
			row:      boundRow(),
			wantOK:   false, wantWhy: ReasonAttestationInvalid,
		},
		{
			name:     "an invalid pairing signature never reaches the rules",
			claim:    func(c *Claim) { c.PairingSigValid = false },
			row:      boundRow(),
			wantOK:   false, wantWhy: ReasonPairingSignatureInvalid,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := validClaim()
			if tc.claim != nil {
				tc.claim(&c)
			}
			got := Decide(c, tc.row, t0)
			if got.Accepted != tc.wantOK {
				t.Fatalf("Accepted = %v, want %v (reason %q)", got.Accepted, tc.wantOK, got.Reason)
			}
			if tc.wantRule != "" && got.Rule != tc.wantRule {
				t.Errorf("Rule = %q, want %q", got.Rule, tc.wantRule)
			}
			if got.Reason != tc.wantWhy {
				t.Errorf("Reason = %q, want %q", got.Reason, tc.wantWhy)
			}
		})
	}
}

func TestAcceptedDecisionAlwaysRepointsAndRenews(t *testing.T) {
	released := t0.Add(-time.Hour)
	row := boundRow()
	row.ReleasedAt = &released
	row.LeaseExpiry = t0.Add(-time.Hour)

	c := validClaim()
	c.Tenant = "tenant-2"
	c.DeviceID = "dev-2"

	got := Decide(c, row, t0)
	if !got.Accepted {
		t.Fatalf("want accepted, got %q", got.Reason)
	}
	if got.Row.ReleasedAt != nil {
		t.Error("an accepting rule must clear ReleasedAt: a successful claim re-asserts ownership")
	}
	if !got.Row.LeaseExpiry.Equal(t0.Add(KindDevice.Lease())) {
		t.Errorf("LeaseExpiry = %v, want %v", got.Row.LeaseExpiry, t0.Add(KindDevice.Lease()))
	}
	if got.Row.Tenant != "tenant-2" || got.Row.DeviceID != "dev-2" {
		t.Errorf("tenant/device = %q/%q, want tenant-2/dev-2", got.Row.Tenant, got.Row.DeviceID)
	}
	if !got.Row.LastSuccessfulClaimAt.Equal(t0) {
		t.Error("an accepting rule must stamp LastSuccessfulClaimAt")
	}
}

func TestRejectedClaimNeverAdvancesTheDormancyClock(t *testing.T) {
	row := boundRow()
	c := validClaim()
	c.PairingPublicKey = "pair-attacker"
	c.AttestKeyID = "attest-attacker"

	got := Decide(c, row, t0.Add(48*time.Hour))
	if got.Accepted {
		t.Fatal("expected refusal")
	}
	if got.Row != nil {
		t.Fatal("a refusal must not produce a row to write; the caller stamps LastFailedClaimAt")
	}
	// The point of the assertion: a phone retrying a failing claim every five
	// minutes must not hold its own row non-dormant forever, which is what
	// made an earlier revision's dormancy rule unreachable in production.
}

func TestR2RequiresTheRowsAttestKeyNotJustAnyValidProof(t *testing.T) {
	row := boundRow()
	c := validClaim()
	c.PairingPublicKey = "pair-attacker"
	c.AttestKeyID = "attest-stranger" // valid proof, but not this row's key

	got := Decide(c, row, t0)
	if got.Accepted {
		t.Fatal("R2 must key on the row's stored attest key id; any-valid-proof would let a stranger replace the pairing key")
	}
	if got.Rule != RuleR3 {
		t.Errorf("Rule = %q, want R3", got.Rule)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./internal/binding/ -run TestDecide -v`
Expected: FAIL to build with `undefined: Decide`.

- [ ] **Step 3: Write the implementation**

Create `canopy/internal/binding/decide.go`:

```go
package binding

import "time"

// Decide applies spec §5's rules to one claim. Rules are evaluated in order and
// the first match wins; the guards are not independently exclusive, and the
// ordering is what resolves them. Tests assert which rule fired for that reason.
//
// Preconditions (both proofs valid, kind agrees with the row) are checked before
// any rule, so no rule has to restate them.
func Decide(c Claim, row *Row, now time.Time) Decision {
	if !c.AttestProofValid {
		return Decision{Reason: ReasonAttestationInvalid}
	}
	if !c.PairingSigValid {
		return Decision{Reason: ReasonPairingSignatureInvalid}
	}
	if row != nil && c.Kind != row.Kind {
		// binding_kind selects the lease and retention horizons, so a claim
		// must never be allowed to relabel a row.
		return Decision{Reason: ReasonKindMismatch}
	}

	switch {
	case row == nil:
		// R0. An unseen device token must first prove it is reachable on the
		// claiming device. Start and activity tokens cannot receive the silent
		// push that proves it, so they bind first-come — a stated residual,
		// not an oversight.
		if c.Kind.NeedsVouch() && !c.VouchOK {
			return Decision{Rule: RuleR0, Reason: ReasonVouchRequired}
		}
		return accept(RuleR0, c, &Row{
			TokenHash:       c.TokenHash,
			Kind:            c.Kind,
			APNSEnvironment: c.APNSEnvironment,
			CreatedAt:       now,
		}, now)

	case c.PairingPublicKey == row.PairingPublicKey:
		// R1, the primary path and the durable one. The attest key legitimately
		// changes on every reinstall while the pairing key does not, so this
		// rule adopts whatever attest key the claim carries.
		return accept(RuleR1, c, row, now)

	case c.AttestKeyID == row.AttestKeyID:
		// R2, the Keychain-lost-but-app-not-reinstalled case. The surviving
		// App Attest key authorises storing a new pairing key.
		return accept(RuleR2, c, row, now)

	default:
		return Decision{Rule: RuleR3, Reason: ReasonPairingMismatch}
	}
}

// accept applies the writes every accepting rule shares. Stating them once is
// deliberate: an earlier revision stated them per-rule and lost the ReleasedAt
// clear from one of them, which livelocked released-then-reclaimed tokens
// between a successful claim and a refused push.
func accept(r Rule, c Claim, row *Row, now time.Time) Decision {
	next := *row
	next.Tenant = c.Tenant
	next.DeviceID = c.DeviceID
	next.AttestKeyID = c.AttestKeyID
	next.PairingPublicKey = c.PairingPublicKey
	next.LeaseExpiry = now.Add(c.Kind.Lease())
	next.LastSuccessfulClaimAt = now
	next.ReleasedAt = nil
	return Decision{Rule: r, Accepted: true, Row: &next}
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./internal/binding/ -v`
Expected: PASS for every case, including all sub-tests of `TestDecide`.

- [ ] **Step 5: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add canopy/internal/binding/decide.go canopy/internal/binding/decide_test.go
git commit -m "feat(canopy): the binding decision rules R0-R3"
```

---

### Task 5: Liveness, dormancy and garbage collection predicates

**Files:**
- Create: `canopy/internal/binding/lifetime.go`
- Modify: `canopy/internal/binding/lifetime_test.go`

**Interfaces:**
- Consumes: `Row`, `Kind`, the constants from Task 2.
- Produces: `func (r *Row) IsLive(now time.Time) bool`, `func (r *Row) IsDormant(now time.Time) bool`, `func (r *Row) HardDeleteAt() time.Time`. Task 7 uses `IsLive` for the cap query and `HardDeleteAt` for the sweeper.

- [ ] **Step 1: Write the failing test**

Append to `canopy/internal/binding/lifetime_test.go`:

```go
func TestIsLive(t *testing.T) {
	released := t0
	base := func() *Row {
		return &Row{Kind: KindDevice, LeaseExpiry: t0.Add(time.Hour)}
	}

	if !base().IsLive(t0) {
		t.Error("an unreleased row inside its lease is live")
	}
	expired := base()
	expired.LeaseExpiry = t0.Add(-time.Hour)
	if expired.IsLive(t0) {
		t.Error("a row past its lease is not live")
	}
	rel := base()
	rel.ReleasedAt = &released
	if rel.IsLive(t0) {
		t.Error("a released row is not live, even inside its lease")
	}
}

func TestIsDormant(t *testing.T) {
	row := &Row{
		Kind:                  KindDevice,
		CreatedAt:             t0,
		LastDeliveryAt:        t0,
		LastSuccessfulClaimAt: t0,
	}
	if row.IsDormant(t0.Add(89 * 24 * time.Hour)) {
		t.Error("89 days of inactivity is not dormant")
	}
	if !row.IsDormant(t0.Add(91 * 24 * time.Hour)) {
		t.Error("91 days of inactivity is dormant")
	}

	// A delivery is activity: pushing to a token keeps it alive.
	delivered := &Row{
		Kind:                  KindDevice,
		CreatedAt:             t0,
		LastSuccessfulClaimAt: t0,
		LastDeliveryAt:        t0.Add(90 * 24 * time.Hour),
	}
	if delivered.IsDormant(t0.Add(91 * 24 * time.Hour)) {
		t.Error("a token delivered to yesterday is not dormant")
	}

	// A failed claim is NOT activity. If it were, a phone retrying a broken
	// claim every five minutes would hold its own row non-dormant forever and
	// the dormancy path would be unreachable in production.
	hammered := &Row{
		Kind:                  KindDevice,
		CreatedAt:             t0,
		LastDeliveryAt:        t0,
		LastSuccessfulClaimAt: t0,
		LastFailedClaimAt:     t0.Add(90 * 24 * time.Hour),
	}
	if !hammered.IsDormant(t0.Add(91 * 24 * time.Hour)) {
		t.Error("failed claims must not advance the dormancy clock")
	}

	activity := &Row{Kind: KindActivity, CreatedAt: t0, LastDeliveryAt: t0, LastSuccessfulClaimAt: t0}
	if activity.IsDormant(t0.Add(365 * 24 * time.Hour)) {
		t.Error("dormancy does not apply to activity rows")
	}
}

func TestHardDeleteAt(t *testing.T) {
	dev := &Row{Kind: KindDevice, LeaseExpiry: t0}
	if want := t0.Add(RetainStartDevice); !dev.HardDeleteAt().Equal(want) {
		t.Errorf("device HardDeleteAt = %v, want %v", dev.HardDeleteAt(), want)
	}
	act := &Row{Kind: KindActivity, LeaseExpiry: t0}
	if want := t0.Add(RetainActivity); !act.HardDeleteAt().Equal(want) {
		t.Errorf("activity HardDeleteAt = %v, want %v", act.HardDeleteAt(), want)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./internal/binding/ -run 'TestIsLive|TestIsDormant|TestHardDeleteAt' -v`
Expected: FAIL to build with `r.IsLive undefined`.

- [ ] **Step 3: Write the implementation**

Create `canopy/internal/binding/lifetime.go`:

```go
package binding

import "time"

// IsLive reports whether this row counts against the per-tenant binding cap and
// may be pushed to. Release and lease expiry both end liveness; neither makes
// the token claimable by a stranger, which is a separate question answered by
// Decide.
func (r *Row) IsLive(now time.Time) bool {
	return r.ReleasedAt == nil && now.Before(r.LeaseExpiry)
}

// IsDormant reports whether the token has seen no delivery and no *successful*
// claim for the dormancy window. Failed claims are deliberately excluded: a
// token under attack, or a phone retrying a claim it cannot satisfy, is not
// abandoned.
func (r *Row) IsDormant(now time.Time) bool {
	if !r.Kind.DormancyApplies() {
		return false
	}
	last := r.CreatedAt
	if r.LastDeliveryAt.After(last) {
		last = r.LastDeliveryAt
	}
	if r.LastSuccessfulClaimAt.After(last) {
		last = r.LastSuccessfulClaimAt
	}
	return now.Sub(last) > Dormancy
}

// HardDeleteAt is when the row may be swept. It must be later than the point at
// which the row could become dormant, or the dormancy path is unreachable —
// see TestRetentionOutlivesDormancy.
func (r *Row) HardDeleteAt() time.Time {
	return r.LeaseExpiry.Add(r.Kind.RetainAfterLease())
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./internal/binding/ -v`
Expected: PASS, every test in the package.

- [ ] **Step 5: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add canopy/internal/binding/lifetime.go canopy/internal/binding/lifetime_test.go
git commit -m "feat(canopy): liveness, dormancy and retention predicates"
```

---

### Task 6: SQLite schema and store

**Files:**
- Create: `canopy/internal/store/schema.go`
- Create: `canopy/internal/store/store.go`
- Create: `canopy/internal/store/store_test.go`
- Modify: `canopy/go.mod` (adds `modernc.org/sqlite`)

**Interfaces:**
- Consumes: `binding.Row`, `binding.Kind` from Task 2.
- Produces: `func Open(path string) (*Store, error)`, `func (s *Store) Close() error`, `func (s *Store) GetBinding(tokenHash string) (*binding.Row, error)`, `func (s *Store) PutBinding(r *binding.Row) error`, `func (s *Store) LiveCount(tenant string, now time.Time) (int, error)`. Task 7 composes these with `binding.Decide`.

- [ ] **Step 1: Add the dependency**

```bash
cd /Users/max/ai-projects/bambu-app/canopy && go get modernc.org/sqlite@latest
```

Expected: `go.mod` gains `modernc.org/sqlite`. This is one of the three dependencies the budget allows.

- [ ] **Step 2: Write the schema**

Create `canopy/internal/store/schema.go`:

```go
package store

// schema is applied on every Open. Canopy stores hashes, public keys and
// counters — never push payloads, never raw tokens. Raw tokens arrive per
// request and die with it.
const schema = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS bindings (
    token_hash                TEXT PRIMARY KEY,
    binding_kind              TEXT NOT NULL,
    apns_environment          TEXT NOT NULL,
    tenant                    TEXT NOT NULL,
    device_id                 TEXT NOT NULL,
    pairing_public_key        TEXT NOT NULL,
    attest_key_id             TEXT NOT NULL,
    lease_expiry              INTEGER NOT NULL,
    last_delivery_at          INTEGER NOT NULL DEFAULT 0,
    last_successful_claim_at  INTEGER NOT NULL DEFAULT 0,
    last_failed_claim_at      INTEGER NOT NULL DEFAULT 0,
    released_at               INTEGER,
    created_at                INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS bindings_tenant_lease
    ON bindings (tenant, released_at, lease_expiry);
`
```

- [ ] **Step 3: Write the failing test**

Create `canopy/internal/store/store_test.go`:

```go
package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/mvks5/canopy/internal/binding"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

func openTemp(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestPutAndGetBinding(t *testing.T) {
	s := openTemp(t)
	row := &binding.Row{
		TokenHash:             "tok-A",
		Kind:                  binding.KindDevice,
		Tenant:                "tenant-1",
		DeviceID:              "dev-1",
		PairingPublicKey:      "pair-1",
		AttestKeyID:           "attest-1",
		APNSEnvironment:       "production",
		LeaseExpiry:           t0.Add(binding.KindDevice.Lease()),
		LastSuccessfulClaimAt: t0,
		CreatedAt:             t0,
	}
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("PutBinding: %v", err)
	}

	got, err := s.GetBinding("tok-A")
	if err != nil {
		t.Fatalf("GetBinding: %v", err)
	}
	if got == nil {
		t.Fatal("GetBinding returned nil for a row that was just written")
	}
	if got.Tenant != "tenant-1" || got.PairingPublicKey != "pair-1" || got.Kind != binding.KindDevice {
		t.Errorf("round-trip mismatch: %+v", got)
	}
	if !got.LeaseExpiry.Equal(row.LeaseExpiry) {
		t.Errorf("LeaseExpiry = %v, want %v", got.LeaseExpiry, row.LeaseExpiry)
	}
	if got.ReleasedAt != nil {
		t.Error("ReleasedAt should round-trip as nil")
	}
}

func TestGetBindingMissingReturnsNilNotError(t *testing.T) {
	s := openTemp(t)
	got, err := s.GetBinding("nope")
	if err != nil {
		t.Fatalf("GetBinding on a missing token must not error: %v", err)
	}
	if got != nil {
		t.Fatal("want nil row for an unseen token — nil is how Decide learns the token is UNSEEN")
	}
}

func TestPutBindingUpserts(t *testing.T) {
	s := openTemp(t)
	row := &binding.Row{
		TokenHash: "tok-A", Kind: binding.KindDevice, Tenant: "tenant-1",
		DeviceID: "dev-1", PairingPublicKey: "pair-1", AttestKeyID: "attest-1",
		APNSEnvironment: "production", LeaseExpiry: t0.Add(time.Hour), CreatedAt: t0,
	}
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("first PutBinding: %v", err)
	}
	row.Tenant = "tenant-2"
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("second PutBinding: %v", err)
	}
	got, _ := s.GetBinding("tok-A")
	if got.Tenant != "tenant-2" {
		t.Errorf("Tenant = %q, want tenant-2 — PutBinding must upsert", got.Tenant)
	}
}

func TestReleasedAtRoundTrips(t *testing.T) {
	s := openTemp(t)
	released := t0.Add(time.Minute)
	row := &binding.Row{
		TokenHash: "tok-A", Kind: binding.KindDevice, Tenant: "tenant-1",
		DeviceID: "dev-1", PairingPublicKey: "pair-1", AttestKeyID: "attest-1",
		APNSEnvironment: "production", LeaseExpiry: t0.Add(time.Hour),
		ReleasedAt: &released, CreatedAt: t0,
	}
	if err := s.PutBinding(row); err != nil {
		t.Fatalf("PutBinding: %v", err)
	}
	got, _ := s.GetBinding("tok-A")
	if got.ReleasedAt == nil || !got.ReleasedAt.Equal(released) {
		t.Errorf("ReleasedAt = %v, want %v", got.ReleasedAt, released)
	}
}

func TestLiveCountExcludesReleasedAndExpired(t *testing.T) {
	s := openTemp(t)
	released := t0
	rows := []*binding.Row{
		{TokenHash: "live", LeaseExpiry: t0.Add(time.Hour)},
		{TokenHash: "expired", LeaseExpiry: t0.Add(-time.Hour)},
		{TokenHash: "released", LeaseExpiry: t0.Add(time.Hour), ReleasedAt: &released},
	}
	for _, r := range rows {
		r.Kind = binding.KindDevice
		r.Tenant = "tenant-1"
		r.DeviceID = "dev-1"
		r.PairingPublicKey = "pair-1"
		r.AttestKeyID = "attest-1"
		r.APNSEnvironment = "production"
		r.CreatedAt = t0
		if err := s.PutBinding(r); err != nil {
			t.Fatalf("PutBinding(%s): %v", r.TokenHash, err)
		}
	}
	n, err := s.LiveCount("tenant-1", t0)
	if err != nil {
		t.Fatalf("LiveCount: %v", err)
	}
	if n != 1 {
		t.Errorf("LiveCount = %d, want 1 — only unreleased rows inside their lease count against the cap", n)
	}
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./internal/store/ -v`
Expected: FAIL to build with `undefined: Open`.

- [ ] **Step 5: Write the implementation**

Create `canopy/internal/store/store.go`:

```go
// Package store owns Canopy's SQLite persistence. It translates binding rows to
// and from the database and answers the cap query; it makes no decisions.
package store

import (
	"database/sql"
	"errors"
	"time"

	"github.com/mvks5/canopy/internal/binding"

	_ "modernc.org/sqlite"
)

// Store is a handle on the Canopy database.
type Store struct{ db *sql.DB }

// Open opens (creating if needed) the database at path and applies the schema.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

// Close releases the database handle.
func (s *Store) Close() error { return s.db.Close() }

// GetBinding returns the row for tokenHash, or (nil, nil) when the token is
// UNSEEN. A missing row is not an error: "no row exists" is a state the decision
// rules act on, not a failure.
func (s *Store) GetBinding(tokenHash string) (*binding.Row, error) {
	const q = `SELECT token_hash, binding_kind, apns_environment, tenant, device_id,
	                  pairing_public_key, attest_key_id, lease_expiry,
	                  last_delivery_at, last_successful_claim_at, last_failed_claim_at,
	                  released_at, created_at
	             FROM bindings WHERE token_hash = ?`

	var (
		r          binding.Row
		kind       string
		lease      int64
		delivery   int64
		okClaim    int64
		failClaim  int64
		released   sql.NullInt64
		created    int64
	)
	err := s.db.QueryRow(q, tokenHash).Scan(
		&r.TokenHash, &kind, &r.APNSEnvironment, &r.Tenant, &r.DeviceID,
		&r.PairingPublicKey, &r.AttestKeyID, &lease,
		&delivery, &okClaim, &failClaim, &released, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	r.Kind = binding.Kind(kind)
	r.LeaseExpiry = time.UnixMilli(lease).UTC()
	r.LastDeliveryAt = time.UnixMilli(delivery).UTC()
	r.LastSuccessfulClaimAt = time.UnixMilli(okClaim).UTC()
	r.LastFailedClaimAt = time.UnixMilli(failClaim).UTC()
	r.CreatedAt = time.UnixMilli(created).UTC()
	if released.Valid {
		t := time.UnixMilli(released.Int64).UTC()
		r.ReleasedAt = &t
	}
	return &r, nil
}

// PutBinding inserts or replaces the row for r.TokenHash.
func (s *Store) PutBinding(r *binding.Row) error {
	const q = `INSERT INTO bindings (
	               token_hash, binding_kind, apns_environment, tenant, device_id,
	               pairing_public_key, attest_key_id, lease_expiry,
	               last_delivery_at, last_successful_claim_at, last_failed_claim_at,
	               released_at, created_at)
	           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
	           ON CONFLICT(token_hash) DO UPDATE SET
	               binding_kind = excluded.binding_kind,
	               apns_environment = excluded.apns_environment,
	               tenant = excluded.tenant,
	               device_id = excluded.device_id,
	               pairing_public_key = excluded.pairing_public_key,
	               attest_key_id = excluded.attest_key_id,
	               lease_expiry = excluded.lease_expiry,
	               last_delivery_at = excluded.last_delivery_at,
	               last_successful_claim_at = excluded.last_successful_claim_at,
	               last_failed_claim_at = excluded.last_failed_claim_at,
	               released_at = excluded.released_at,
	               created_at = excluded.created_at`

	var released any
	if r.ReleasedAt != nil {
		released = r.ReleasedAt.UnixMilli()
	}
	_, err := s.db.Exec(q,
		r.TokenHash, string(r.Kind), r.APNSEnvironment, r.Tenant, r.DeviceID,
		r.PairingPublicKey, r.AttestKeyID, r.LeaseExpiry.UnixMilli(),
		r.LastDeliveryAt.UnixMilli(), r.LastSuccessfulClaimAt.UnixMilli(),
		r.LastFailedClaimAt.UnixMilli(), released, r.CreatedAt.UnixMilli())
	return err
}

// LiveCount returns how many of tenant's bindings count against its cap: rows
// that are unreleased and still inside their lease.
func (s *Store) LiveCount(tenant string, now time.Time) (int, error) {
	const q = `SELECT COUNT(*) FROM bindings
	            WHERE tenant = ? AND released_at IS NULL AND lease_expiry > ?`
	var n int
	err := s.db.QueryRow(q, tenant, now.UnixMilli()).Scan(&n)
	return n, err
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./... -v`
Expected: PASS in both `internal/binding` and `internal/store`.

- [ ] **Step 7: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add canopy/go.mod canopy/go.sum canopy/internal/store/
git commit -m "feat(canopy): SQLite store for bindings"
```

---

### Task 7: Apply a claim end to end

**Files:**
- Create: `canopy/internal/claims/apply.go`
- Create: `canopy/internal/claims/apply_test.go`

**Interfaces:**
- Consumes: `binding.Claim`, `binding.Decide`, `store.Store` from Tasks 2, 4 and 6.
- Produces: `func Apply(s *store.Store, c binding.Claim, now time.Time) (binding.Decision, error)`. The HTTP layer (a later plan) calls exactly this.

- [ ] **Step 1: Write the failing test**

Create `canopy/internal/claims/apply_test.go`:

```go
package claims

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/mvks5/canopy/internal/binding"
	"github.com/mvks5/canopy/internal/store"
)

var t0 = time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)

func openTemp(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "canopy.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func deviceClaim() binding.Claim {
	return binding.Claim{
		TokenHash: "tok-A", Kind: binding.KindDevice, Tenant: "tenant-1",
		DeviceID: "dev-1", AttestKeyID: "attest-1", PairingPublicKey: "pair-1",
		APNSEnvironment: "production",
		AttestProofValid: true, PairingSigValid: true, VouchOK: true,
	}
}

func TestApplyBindsThenRecognises(t *testing.T) {
	s := openTemp(t)

	first, err := Apply(s, deviceClaim(), t0)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if !first.Accepted || first.Rule != binding.RuleR0 {
		t.Fatalf("first claim: rule %q accepted %v, want R0 accepted", first.Rule, first.Accepted)
	}

	second, err := Apply(s, deviceClaim(), t0.Add(time.Hour))
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if !second.Accepted || second.Rule != binding.RuleR1 {
		t.Fatalf("second claim: rule %q accepted %v, want R1 accepted", second.Rule, second.Accepted)
	}
}

func TestApplyPersistsTheVouchRequirementAcrossCalls(t *testing.T) {
	s := openTemp(t)
	c := deviceClaim()
	c.VouchOK = false

	got, err := Apply(s, c, t0)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if got.Accepted {
		t.Fatal("an unseen device token without a vouch must not bind")
	}
	if got.Reason != binding.ReasonVouchRequired {
		t.Errorf("Reason = %q, want vouch_required", got.Reason)
	}
	if row, _ := s.GetBinding("tok-A"); row != nil {
		t.Fatal("a refused claim must not write a binding")
	}
}

func TestApplyStampsFailedClaimWithoutAdvancingDormancy(t *testing.T) {
	s := openTemp(t)
	if _, err := Apply(s, deviceClaim(), t0); err != nil {
		t.Fatalf("seed: %v", err)
	}

	bad := deviceClaim()
	bad.PairingPublicKey = "pair-attacker"
	bad.AttestKeyID = "attest-attacker"
	later := t0.Add(80 * 24 * time.Hour)
	got, err := Apply(s, bad, later)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if got.Accepted {
		t.Fatal("expected refusal")
	}

	row, _ := s.GetBinding("tok-A")
	if !row.LastFailedClaimAt.Equal(later) {
		t.Errorf("LastFailedClaimAt = %v, want %v", row.LastFailedClaimAt, later)
	}
	if !row.LastSuccessfulClaimAt.Equal(t0) {
		t.Error("a refused claim must not advance the successful-claim clock")
	}
	if !row.IsDormant(t0.Add(91 * 24 * time.Hour)) {
		t.Error("a row hammered by refused claims must still become dormant on schedule")
	}
	if row.Tenant != "tenant-1" {
		t.Errorf("Tenant = %q — a refused claim must not re-point the tenant", row.Tenant)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./internal/claims/ -v`
Expected: FAIL to build with `undefined: Apply`.

- [ ] **Step 3: Write the implementation**

Create `canopy/internal/claims/apply.go`:

```go
// Package claims composes the pure decision rules with persistence. It is the
// entry point the HTTP layer calls; it adds no policy of its own.
package claims

import (
	"time"

	"github.com/mvks5/canopy/internal/binding"
	"github.com/mvks5/canopy/internal/store"
)

// Apply loads the current row for the claim's token, decides, and persists the
// result. A refused claim stamps LastFailedClaimAt on the existing row and
// changes nothing else — deliberately not LastSuccessfulClaimAt, so that a
// token under repeated refused claims still reaches dormancy on schedule.
func Apply(s *store.Store, c binding.Claim, now time.Time) (binding.Decision, error) {
	row, err := s.GetBinding(c.TokenHash)
	if err != nil {
		return binding.Decision{}, err
	}

	d := binding.Decide(c, row, now)

	switch {
	case d.Accepted:
		// Carry forward the fields Decide does not own.
		if row != nil {
			d.Row.LastDeliveryAt = row.LastDeliveryAt
			d.Row.LastFailedClaimAt = row.LastFailedClaimAt
		}
		if err := s.PutBinding(d.Row); err != nil {
			return binding.Decision{}, err
		}
	case row != nil:
		row.LastFailedClaimAt = now
		if err := s.PutBinding(row); err != nil {
			return binding.Decision{}, err
		}
	}
	return d, nil
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/max/ai-projects/bambu-app/canopy && go test ./... -v`
Expected: PASS across all three packages.

- [ ] **Step 5: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add canopy/internal/claims/
git commit -m "feat(canopy): apply a claim against the store"
```

---

## What this plan deliberately leaves out

Each is its own later plan, in this order:

1. **Vouching transport** — `POST /v1/vouch`, the nonce table, the silent APNs push, per-token global caps, and the constant `202` so it is not a liveness oracle. Task 4 already takes `VouchOK` as an input, so this slots in without touching the rules.
2. **App Attest verification** — Apple's full ordered procedure including the credCert extension `1.2.840.113635.100.8.2` nonce comparison and the assertion signature check, plus the pairing-key P-256 verification. Needs the real-device fixtures from rollout step 0.
3. **APNs client** — ES256 JWT, HTTP/2, one key per environment, the `BadDeviceToken` retry that swaps host *and* key, topic forcing, priority clamping, the 4096-byte cap.
4. **HTTP layer** — enroll (with recovery codes), challenges, claims, push, release, delete, health; the two-field `(transport_outcome, apns_status)` result; rate limits and tenant-scoped shedding.

## Self-review

- **Spec coverage for this slice:** §5's rules R0–R3 (Task 4), the vouch gate as an input (Task 4), `binding_kind` immutability (Task 4), the accepting-rule write set (Task 4), §6's lease/retention/dormancy arithmetic (Tasks 3 and 5), the live-binding definition and cap query (Tasks 5 and 6), the storage shape (Task 6). Crypto, APNs, vouch transport and HTTP are explicitly deferred above.
- **Placeholders:** none — every step carries the code or the exact command.
- **Type consistency:** `binding.Kind`, `binding.Rule`, `binding.Reason`, `binding.Claim`, `binding.Row`, `binding.Decision`, `binding.Decide`, `store.Open/GetBinding/PutBinding/LiveCount`, and `claims.Apply` are spelled identically in every task that uses them.
