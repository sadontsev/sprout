package apns

import (
	"errors"
	"testing"
)

const bundleID = "com.example.sprout"

func TestTopicIsHardcodedPerPushType(t *testing.T) {
	cases := []struct {
		p    PushType
		want string
	}{
		{LiveActivity, "com.example.sprout.push-type.liveactivity"},
		{Alert, "com.example.sprout"},
		{Background, "com.example.sprout"},
	}
	for _, tc := range cases {
		got, err := tc.p.Topic(bundleID)
		if err != nil {
			t.Fatalf("%s: %v", tc.p, err)
		}
		if got != tc.want {
			t.Errorf("%s topic = %q, want %q", tc.p, got, tc.want)
		}
	}
}

func TestUnknownPushTypeHasNoTopic(t *testing.T) {
	if _, err := PushType("anything-a-tenant-sends").Topic(bundleID); err == nil {
		t.Fatal("an unknown push type must not produce a topic: the mapping is the " +
			"only thing stopping a tenant from choosing what we sign for")
	}
}

func TestClampPriority(t *testing.T) {
	for in, want := range map[int]int{-5: 5, 0: 5, 1: 5, 5: 5, 9: 5, 10: 10, 11: 10, 99: 10} {
		if got := ClampPriority(in); got != want {
			t.Errorf("ClampPriority(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestEnvironmentHostAndOther(t *testing.T) {
	if Sandbox.Host() != "api.sandbox.push.apple.com" {
		t.Errorf("sandbox host = %q", Sandbox.Host())
	}
	if Production.Host() != "api.push.apple.com" {
		t.Errorf("production host = %q", Production.Host())
	}
	if Sandbox.Other() != Production || Production.Other() != Sandbox {
		t.Error("Other must flip the environment: the gateway retry swaps host and key together")
	}
}

func TestTokenIsDeadOnlyForDeliveredResults(t *testing.T) {
	dead := []Result{
		{Outcome: Delivered, APNsStatus: 410},
		{Outcome: Delivered, APNsStatus: 400, APNsReason: "BadDeviceToken"},
	}
	for _, r := range dead {
		if !r.TokenIsDead() {
			t.Errorf("%+v should be a dead token", r)
		}
	}

	alive := []Result{
		{Outcome: Delivered, APNsStatus: 200},
		{Outcome: Delivered, APNsStatus: 400, APNsReason: "PayloadTooLarge"},
		{Outcome: Delivered, APNsStatus: 429},
		// The load-bearing cases: Canopy's own failures must never read as a
		// dead token, or a malformed body or a network blip would delete a
		// healthy registration.
		{Outcome: Transport, Err: errors.New("dial tcp: timeout")},
		{Outcome: Refused, Err: errors.New("payload too large")},
	}
	for _, r := range alive {
		if r.TokenIsDead() {
			t.Errorf("%+v must not read as a dead token", r)
		}
	}
}
