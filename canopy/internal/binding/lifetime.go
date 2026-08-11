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
