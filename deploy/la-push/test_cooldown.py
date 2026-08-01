"""Unit tests for the plate-cooldown decision. Run: python3 -m unittest discover deploy/la-push

Deliberately dependency-free (stdlib unittest, no pytest/httpx/fastapi) so it runs anywhere the
service does, including inside the container.
"""
from __future__ import annotations

import unittest

from cooldown import (
    COOL_DEFAULT_C,
    COOL_MAX_C,
    COOL_MIN_C,
    PLATEAU_DELTA_C,
    PLATEAU_WINDOW_S,
    READY,
    STALLED,
    clamp_threshold,
    cool_step,
    new_state,
)

T = COOL_DEFAULT_C  # 35.0


def run(steps, threshold=T, state=None, t0=1_000_000.0):
    """Feed (printing, bed, seconds_since_start) tuples; collect the actions fired."""
    st = state if state is not None else new_state()
    fired = []
    for printing, bed, dt in steps:
        action, st = cool_step(printing, bed, threshold, st, t0 + dt)
        if action:
            fired.append((action, bed, dt))
    return fired, st


class TestClampThreshold(unittest.TestCase):
    def test_defaults_to_bambus_published_number(self):
        self.assertEqual(COOL_DEFAULT_C, 35.0)
        for bad in (None, "abc", object(), float("nan"), float("inf")):
            self.assertEqual(clamp_threshold(bad), 35.0)

    def test_rejects_a_threshold_that_could_never_be_reached(self):
        self.assertEqual(clamp_threshold(25), COOL_MIN_C)
        self.assertEqual(clamp_threshold(-100), COOL_MIN_C)

    def test_rejects_a_threshold_hot_enough_to_burn(self):
        self.assertEqual(clamp_threshold(60), COOL_MAX_C)
        self.assertLess(COOL_MAX_C, 48)  # EN ISO 13732-1, bare metal, 10 min contact

    def test_passes_through_sane_values_including_strings(self):
        self.assertEqual(clamp_threshold(40), 40.0)
        self.assertEqual(clamp_threshold("38"), 38.0)


class TestArming(unittest.TestCase):
    def test_a_cold_idle_printer_never_fires(self):
        # THE reason arming exists: without it, every poll of a cold idle machine announces itself.
        fired, st = run([(False, 24, i * 5) for i in range(200)])
        self.assertEqual(fired, [])
        self.assertFalse(st["armed"])

    def test_arms_only_once_the_bed_is_actually_hot_during_a_print(self):
        _, cold = run([(True, 20, 0)])
        self.assertFalse(cold["armed"])
        _, hot = run([(True, 60, 0)])
        self.assertTrue(hot["armed"])

    def test_a_print_that_never_heated_the_bed_produces_no_announcement(self):
        fired, _ = run([(True, 22, 0), (True, 23, 60), (False, 22, 120), (False, 21, 180)])
        self.assertEqual(fired, [])

    def test_fires_once_and_only_once_per_print(self):
        steps = [(True, 60, 0)] + [(False, 34, 60 + i * 5) for i in range(50)]
        fired, st = run(steps)
        self.assertEqual(len(fired), 1)
        self.assertEqual(fired[0][0], READY)
        self.assertTrue(st["fired"])

    def test_re_arms_for_the_next_print(self):
        first = [(True, 60, 0), (False, 34, 60)]
        second = [(True, 60, 3600), (False, 33, 3700)]
        fired, _ = run(first + second)
        self.assertEqual([f[0] for f in fired], [READY, READY])

    def test_a_new_print_clears_a_pending_announcement_and_its_history(self):
        _, st = run([(True, 60, 0), (False, 50, 60), (False, 49, 120)])
        self.assertTrue(st["seen"])
        _, st2 = cool_step(True, 60, T, st, 1_000_180.0)
        self.assertEqual(st2["seen"], [])
        self.assertFalse(st2["fired"])


class TestThresholdCrossing(unittest.TestCase):
    def test_fires_when_the_bed_reaches_the_threshold(self):
        fired, _ = run([(True, 60, 0), (False, 40, 60), (False, 36, 120), (False, 35, 180)])
        self.assertEqual([f[0] for f in fired], [READY])
        self.assertEqual(fired[0][1], 35)

    def test_stays_silent_while_the_plate_is_still_hot(self):
        fired, _ = run([(True, 60, 0)] + [(False, 60 - i, 60 + i * 30) for i in range(20)])
        self.assertEqual(fired, [])

    def test_honours_a_custom_threshold(self):
        fired, _ = run([(True, 60, 0), (False, 39, 60)], threshold=40.0)
        self.assertEqual([f[0] for f in fired], [READY])

    def test_ignores_a_zero_reading_which_means_no_data(self):
        fired, _ = run([(True, 60, 0), (False, 0, 60), (False, 0, 120)])
        self.assertEqual(fired, [])

    def test_survives_a_non_numeric_reading(self):
        st = new_state()
        st["armed"] = True
        action, st2 = cool_step(False, None, T, st, 1.0)  # type: ignore[arg-type]
        self.assertIsNone(action)
        self.assertTrue(st2["armed"])  # not consumed by junk


class TestPlateau(unittest.TestCase):
    """The branch that stops the notification silently never firing in a warm room."""

    def test_announces_when_the_bed_stops_falling_above_the_threshold(self):
        # Settles at 37C in a ~36C room: the 35C threshold will never arrive.
        steps = [(True, 60, 0)] + [(False, 37, 60 + i * 60) for i in range(20)]
        fired, _ = run(steps)
        self.assertEqual([f[0] for f in fired], [STALLED])

    def test_does_not_announce_a_plateau_while_the_bed_is_still_falling(self):
        steps = [(True, 70, 0)] + [(False, 60 - i, 60 + i * 60) for i in range(20)]
        fired, _ = run(steps)
        self.assertEqual(fired, [])

    def test_needs_the_whole_window_not_just_three_quick_readings(self):
        # Three identical readings five seconds apart prove nothing about cooling.
        steps = [(True, 60, 0)] + [(False, 37, 60 + i * 5) for i in range(4)]
        fired, _ = run(steps)
        self.assertEqual(fired, [])

    def test_movement_bigger_than_the_delta_is_not_a_plateau(self):
        # Falling steadily but still well above the threshold: neither branch should fire.
        steps = [(True, 60, 0)] + [(False, 50 - i * PLATEAU_DELTA_C, 60 + i * 300) for i in range(6)]
        fired, _ = run(steps)
        self.assertEqual(fired, [])
        self.assertGreater(50 - 5 * PLATEAU_DELTA_C, T)  # never crossed the threshold

    def test_prefers_the_real_threshold_over_a_plateau_when_both_could_apply(self):
        # Flat AND below threshold -> the honest message is "cool", not "stopped cooling".
        steps = [(True, 60, 0)] + [(False, 34, 60 + i * 60) for i in range(20)]
        fired, _ = run(steps)
        self.assertEqual([f[0] for f in fired], [READY])

    def test_old_readings_fall_out_of_the_window(self):
        # Hot long ago, then flat for the last window -> still a plateau.
        steps = [(True, 70, 0), (False, 50, 60)] + [(False, 37, 4000 + i * 60) for i in range(20)]
        fired, _ = run(steps)
        self.assertEqual([f[0] for f in fired], [STALLED])
        self.assertLess(PLATEAU_WINDOW_S, 4000)


class TestPurity(unittest.TestCase):
    def test_does_not_mutate_the_state_it_is_given(self):
        st = {"armed": True, "fired": False, "seen": []}
        snapshot = {"armed": True, "fired": False, "seen": []}
        cool_step(False, 34, T, st, 1.0)
        self.assertEqual(st, snapshot)

    def test_tolerates_a_missing_or_partial_state_blob(self):
        # Survives a restart onto an older persisted shape.
        for st in (None, {}, {"armed": True}, {"fired": True}):
            action, out = cool_step(False, 34, T, st, 1.0)
            self.assertIn(set(out), [set(out)])  # shape is always complete
            self.assertEqual(sorted(out.keys()), ["armed", "fired", "seen"])

    def test_a_partial_state_with_armed_still_fires(self):
        action, _ = cool_step(False, 34, T, {"armed": True}, 1.0)
        self.assertEqual(action, READY)


class TestRealCooldown(unittest.TestCase):
    """Replay of a real 89-minute cooldown recorded from the printer (69C -> 33C, room ~28.5C)."""

    CURVE = [
        69, 67, 65, 64, 63, 61, 60, 59, 58, 57, 56, 56, 55, 54, 53, 53, 52, 51, 51, 50, 50, 49, 48,
        48, 48, 47, 47, 46, 46, 45, 45, 45, 44, 44, 44, 43, 43, 43, 42, 42, 42, 41, 41, 41, 41, 40,
        40, 40, 40, 39, 39, 39, 39, 39, 38, 38, 38, 38, 38, 37, 37, 37, 37, 37, 37, 36, 36, 36, 36,
        36, 36, 36, 35, 35, 35, 35, 35, 35, 35, 35, 35, 34, 34, 34, 34, 34, 34, 33, 33, 33,
    ]

    def test_fires_exactly_once_at_the_minute_the_plate_really_hit_35C(self):
        steps = [(True, 70, 0)] + [(False, c, 60 + m * 60) for m, c in enumerate(self.CURVE)]
        fired, _ = run(steps)
        self.assertEqual(len(fired), 1)
        action, bed, dt = fired[0]
        self.assertEqual(action, READY)
        self.assertEqual(bed, 35)
        self.assertEqual((dt - 60) // 60, 72)  # the real curve crossed 35C at minute 72

    def test_a_warm_room_takes_the_plateau_path_instead_of_going_silent(self):
        # Same curve, but the room is 36C: it flattens at 37 and never reaches 35.
        warm = [max(c, 37) for c in self.CURVE]
        steps = [(True, 70, 0)] + [(False, c, 60 + m * 60) for m, c in enumerate(warm)]
        fired, _ = run(steps)
        self.assertEqual(len(fired), 1)
        self.assertEqual(fired[0][0], STALLED)


if __name__ == "__main__":
    unittest.main()
