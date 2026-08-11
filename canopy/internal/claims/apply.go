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
