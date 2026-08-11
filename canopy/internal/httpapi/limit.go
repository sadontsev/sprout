package httpapi

import (
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Limiter is a keyed token bucket. Canopy keys separately by tenant, by source
// IP and by push token, because the three answer different questions: how much
// one customer may do, how much one network location may do, and how often one
// device may be pushed to. Collapsing them would let an attacker who can enroll
// more tenants evade a per-tenant cap.
type Limiter struct {
	rate  rate.Limit
	burst int
	ttl   time.Duration

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	lim  *rate.Limiter
	seen time.Time
}

// NewLimiter builds a limiter allowing r events per second per key, with the
// given burst. Idle keys are dropped after ttl so the map cannot grow without
// bound under a stream of distinct keys.
func NewLimiter(r rate.Limit, burst int, ttl time.Duration) *Limiter {
	return &Limiter{rate: r, burst: burst, ttl: ttl, buckets: map[string]*bucket{}}
}

// Allow reports whether one event for key may proceed at now.
func (l *Limiter) Allow(key string, now time.Time) bool {
	if l == nil {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{lim: rate.NewLimiter(l.rate, l.burst)}
		l.buckets[key] = b
	}
	b.seen = now

	// Opportunistic sweep: cheap, and it keeps a long-running process from
	// accumulating a bucket per token it has ever seen.
	if len(l.buckets) > 1024 {
		for k, v := range l.buckets {
			if now.Sub(v.seen) > l.ttl {
				delete(l.buckets, k)
			}
		}
	}
	return b.lim.AllowN(now, 1)
}

// PerMinute is a convenience for the common shape: n events a minute with a
// burst of n.
func PerMinute(n int) *Limiter {
	return NewLimiter(rate.Limit(float64(n)/60.0), n, 10*time.Minute)
}
