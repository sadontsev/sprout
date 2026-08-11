package binding

import (
	"testing"
	"time"
)

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
