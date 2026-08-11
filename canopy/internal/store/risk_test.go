package store

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

func putKey(t *testing.T, s *Store, keyID, env string, receipt []byte) {
	t.Helper()
	err := s.PutAttestKey(AttestKey{
		KeyID:       keyID,
		PublicKey:   "pub-" + keyID,
		Counter:     1,
		Environment: env,
		Receipt:     receipt,
	}, t0)
	if err != nil {
		t.Fatalf("PutAttestKey(%s): %v", keyID, err)
	}
}

func dueIDs(t *testing.T, s *Store, now time.Time, limit int) []string {
	t.Helper()
	rows, err := s.AttestKeysDueForRedemption(now, limit)
	if err != nil {
		t.Fatalf("AttestKeysDueForRedemption: %v", err)
	}
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.KeyID)
	}
	return out
}

func TestANeverRedeemedKeyWithAReceiptIsDue(t *testing.T) {
	s := openTemp(t)
	putKey(t, s, "k1", "production", []byte("receipt"))

	got := dueIDs(t, s, t0, 10)
	if len(got) != 1 || got[0] != "k1" {
		t.Fatalf("due = %v, want [k1]", got)
	}
}

func TestAKeyWithNoReceiptIsNeverDue(t *testing.T) {
	// Nothing to redeem. Listing it would produce a failed call per sweep, forever.
	s := openTemp(t)
	putKey(t, s, "none", "production", nil)
	putKey(t, s, "empty", "production", []byte{})

	if got := dueIDs(t, s, t0, 10); len(got) != 0 {
		t.Fatalf("due = %v, want none", got)
	}
}

func TestAKeyIsNotDueUntilItsNotBefore(t *testing.T) {
	s := openTemp(t)
	putKey(t, s, "k1", "production", []byte("receipt"))
	next := t0.Add(6 * time.Hour)
	if err := s.PutAttestRisk("k1", 3, true, []byte("refreshed"), next, t0); err != nil {
		t.Fatalf("PutAttestRisk: %v", err)
	}

	if got := dueIDs(t, s, t0.Add(time.Hour), 10); len(got) != 0 {
		t.Errorf("due = %v before the not-before; Apple would answer 429", got)
	}
	if got := dueIDs(t, s, next.Add(time.Minute), 10); len(got) != 1 {
		t.Errorf("due = %v after the not-before, want [k1]", got)
	}
}

func TestTheRefreshedReceiptReplacesTheStoredOne(t *testing.T) {
	// Apple supersedes the receipt on every redemption. Keeping the original would make the second
	// redemption fail and every one after it — a metric that works exactly once.
	s := openTemp(t)
	putKey(t, s, "k1", "production", []byte("original"))
	if err := s.PutAttestRisk("k1", 3, true, []byte("refreshed"), t0.Add(time.Hour), t0); err != nil {
		t.Fatal(err)
	}

	got, err := s.GetAttestKey("k1")
	if err != nil {
		t.Fatal(err)
	}
	if string(got.Receipt) != "refreshed" {
		t.Errorf("receipt = %q, want the refreshed one", got.Receipt)
	}
}

func TestAnAbsentMetricIsStoredAsNullNotZero(t *testing.T) {
	// The distinction the alerting rests on: "not yet known" must not become "known to be clean".
	s := openTemp(t)
	putKey(t, s, "k1", "production", []byte("r"))
	if err := s.PutAttestRisk("k1", 0, false, []byte("r2"), t0.Add(time.Hour), t0); err != nil {
		t.Fatal(err)
	}

	risk, err := s.GetAttestRisk("k1")
	if err != nil {
		t.Fatal(err)
	}
	if risk.HasMetric {
		t.Error("no metric was supplied; HasMetric must be false")
	}
	if risk.CheckedAt.IsZero() {
		t.Error("the attempt itself must still be recorded")
	}
}

func TestAKnownMetricSurvivesALaterRedemptionThatCarriesNone(t *testing.T) {
	// Apple can answer with an ATTEST receipt. Overwriting a real count with nothing would erase
	// the only evidence about a device that had already been flagged.
	s := openTemp(t)
	putKey(t, s, "k1", "production", []byte("r"))
	if err := s.PutAttestRisk("k1", 40, true, []byte("r2"), t0.Add(time.Hour), t0); err != nil {
		t.Fatal(err)
	}
	if err := s.PutAttestRisk("k1", 0, false, []byte("r3"), t0.Add(2*time.Hour), t0); err != nil {
		t.Fatal(err)
	}

	risk, err := s.GetAttestRisk("k1")
	if err != nil {
		t.Fatal(err)
	}
	if !risk.HasMetric || risk.Metric != 40 {
		t.Errorf("metric = %d (has %v), want the previously recorded 40", risk.Metric, risk.HasMetric)
	}
}

func TestDeferringPushesTheNextAttemptWithoutRecordingAMetric(t *testing.T) {
	s := openTemp(t)
	putKey(t, s, "k1", "production", []byte("r"))
	until := t0.Add(24 * time.Hour)
	if err := s.DeferAttestRedemption("k1", until, t0); err != nil {
		t.Fatal(err)
	}

	if got := dueIDs(t, s, t0.Add(time.Hour), 10); len(got) != 0 {
		t.Errorf("due = %v, want none until %v", got, until)
	}
	risk, err := s.GetAttestRisk("k1")
	if err != nil {
		t.Fatal(err)
	}
	if risk.HasMetric {
		t.Error("a deferral produced no answer and must record none")
	}
	if !risk.NotBefore.Equal(until) {
		t.Errorf("NotBefore = %v, want %v", risk.NotBefore, until)
	}
}

func TestTheOldestDueKeyComesFirstAndTheBatchIsHonoured(t *testing.T) {
	// A backlog must drain oldest-first. Ordering by key id would starve whichever key sorts last
	// for as long as the backlog exceeds one batch.
	s := openTemp(t)
	for _, k := range []string{"a", "b", "c"} {
		putKey(t, s, k, "production", []byte("r"))
	}
	// c is due earliest, then b, then a.
	mustRisk(t, s, "a", t0.Add(3*time.Hour))
	mustRisk(t, s, "b", t0.Add(2*time.Hour))
	mustRisk(t, s, "c", t0.Add(1*time.Hour))

	got := dueIDs(t, s, t0.Add(10*time.Hour), 2)
	if len(got) != 2 || got[0] != "c" || got[1] != "b" {
		t.Errorf("due = %v, want [c b]", got)
	}
}

func mustRisk(t *testing.T, s *Store, keyID string, next time.Time) {
	t.Helper()
	if err := s.PutAttestRisk(keyID, 1, true, []byte("r"), next, t0); err != nil {
		t.Fatal(err)
	}
}

func TestGetAttestRiskOnAnUnknownKeyIsNotAnError(t *testing.T) {
	s := openTemp(t)
	got, err := s.GetAttestRisk("never-seen")
	if err != nil {
		t.Fatalf("GetAttestRisk: %v", err)
	}
	if got != nil {
		t.Errorf("got %+v, want nil for a key that does not exist", got)
	}
}

func TestMigrationsApplyToADatabaseThatPredatesThem(t *testing.T) {
	// The case CREATE TABLE IF NOT EXISTS silently skips — and the only deployment that has the
	// history worth reading. Build the pre-migration table by hand, then Open over it.
	path := filepath.Join(t.TempDir(), "old.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE attest_keys (
	    key_id             TEXT PRIMARY KEY,
	    public_key         TEXT NOT NULL,
	    counter            INTEGER NOT NULL,
	    attest_environment TEXT NOT NULL,
	    receipt            BLOB,
	    first_seen         INTEGER NOT NULL,
	    last_seen          INTEGER NOT NULL
	);
	INSERT INTO attest_keys VALUES ('legacy','pub',1,'production',X'6162',0,0);`)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()

	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open over a pre-migration database: %v", err)
	}
	defer s.Close()

	if got := dueIDs(t, s, t0, 10); len(got) != 1 || got[0] != "legacy" {
		t.Fatalf("due = %v, want the pre-existing key to become assessable", got)
	}
}

func TestOpeningTwiceIsIdempotent(t *testing.T) {
	// Every restart re-runs the migrations; a duplicate-column error must not stop the process.
	path := filepath.Join(t.TempDir(), "canopy.db")
	for i := 0; i < 3; i++ {
		s, err := Open(path)
		if err != nil {
			t.Fatalf("Open #%d: %v", i+1, err)
		}
		s.Close()
	}
}
