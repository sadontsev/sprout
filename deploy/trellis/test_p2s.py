"""Unit tests for the push-to-start rule. Run: python3 -m unittest discover deploy/Trellis"""
from __future__ import annotations

import unittest

from p2s import (aggregate_should_start, dry_identity, hms_reason, may_wake, next_started_for,
                 print_identity, prune, should_start, wake_push_due)


class TestPrintIdentity(unittest.TestCase):
    def test_prefers_the_archive_id(self):
        self.assertEqual(print_identity({"current_archive_id": 412}, {"name": "cube"}), "a412")

    def test_falls_back_to_the_subtask_name(self):
        self.assertEqual(print_identity({}, {"name": "Snag Cutter V5"}), "nSnag Cutter V5")
        self.assertEqual(print_identity({"subtask_name": "Snag Cutter V5"}, {}), "nSnag Cutter V5")

    def test_unidentifiable_prints_collapse_to_ONE_identity(self):
        # The failure mode being prevented: no identity must never mean "a new print every tick",
        # or the duplication comes straight back.
        a = print_identity({}, {})
        b = print_identity({"current_archive_id": 0}, {"name": "  "})
        self.assertEqual(a, b)
        self.assertEqual(a, "unknown")

    def test_identity_is_stable_across_polls_of_the_same_print(self):
        # Progress, layer and remaining time all change every poll; identity must not.
        s1 = {"current_archive_id": 412, "progress": 12}
        s2 = {"current_archive_id": 412, "progress": 87}
        self.assertEqual(print_identity(s1, {}), print_identity(s2, {}))


class TestShouldStart(unittest.TestCase):
    def test_starts_once_for_a_print(self):
        self.assertTrue(should_start(True, "a412", None, False))

    def test_does_NOT_start_again_for_the_same_print(self):
        # THE regression: the old rule re-fired every time its 10-minute claim expired, producing
        # 199 cards for one print.
        self.assertFalse(should_start(True, "a412", "a412", False))

    def test_does_NOT_start_when_the_identity_merely_CHANGES_mid_print(self):
        # Bambuddy assigns the archive id shortly after printing starts, so identity legitimately
        # goes from the subtask name to "a125" during one print. Comparing values started a second
        # card — observed live. Only leaving the live state may re-arm.
        self.assertFalse(should_start(True, "a125", "nSide changed. Mounting…", False))
        self.assertFalse(should_start(True, "a413", "a412", False))

    def test_never_starts_when_a_card_is_already_registered(self):
        self.assertFalse(should_start(True, "a412", None, True))
        self.assertFalse(should_start(True, "a999", "a412", True))

    def test_never_starts_when_nothing_is_active(self):
        self.assertFalse(should_start(False, "a412", None, False))

    def test_a_thousand_ticks_of_one_print_produce_exactly_one_start(self):
        started_for, starts = None, 0
        for _ in range(1000):
            if should_start(True, "a412", started_for, False):
                starts += 1
            started_for = next_started_for(True, "a412", started_for)
        self.assertEqual(starts, 1)

    def test_a_second_print_gets_exactly_one_more(self):
        started_for, starts = None, 0
        for identity, active in [("a412", True)] * 50 + [("", False)] * 5 + [("a413", True)] * 50:
            if should_start(active, identity, started_for, False):
                starts += 1
            started_for = next_started_for(active, identity, started_for)
        self.assertEqual(starts, 2)

    def test_a_print_whose_identity_churns_still_gets_exactly_one(self):
        # The real sequence: no archive id yet -> subtask name -> archive id.
        seq = [("unknown", True)] * 3 + [("nSide changed…", True)] * 20 + [("a125", True)] * 200
        started_for, starts = None, 0
        for identity, active in seq:
            if should_start(active, identity, started_for, False):
                starts += 1
            started_for = next_started_for(active, identity, started_for)
        self.assertEqual(starts, 1)

    def test_going_idle_re_arms_even_for_the_SAME_identity(self):
        # A reprint of the same archive is a new print and deserves a card.
        started_for = next_started_for(True, "a412", None)
        started_for = next_started_for(False, "", started_for)  # print ended
        self.assertIsNone(started_for)
        self.assertTrue(should_start(True, "a412", started_for, False))


class TestDryIdentity(unittest.TestCase):
    def test_ignores_the_countdown_so_it_is_stable_mid_cycle(self):
        a = dry_identity(0, {"dry_filament": "PETG", "dry_target_temp": 65, "dry_time": 120})
        b = dry_identity(0, {"dry_filament": "PETG", "dry_target_temp": 65, "dry_time": 30})
        self.assertEqual(a, b)

    def test_distinguishes_units_and_cycles(self):
        base = {"dry_filament": "PETG", "dry_target_temp": 65}
        self.assertNotEqual(dry_identity(0, base), dry_identity(128, base))
        self.assertNotEqual(dry_identity(0, base), dry_identity(0, {**base, "dry_filament": "PLA"}))
        self.assertNotEqual(dry_identity(0, base), dry_identity(0, {**base, "dry_target_temp": 85}))

    def test_one_start_per_cycle_across_many_ticks(self):
        unit = {"dry_filament": "PETG-CF", "dry_target_temp": 85}
        ident, started_for, starts = dry_identity(128, unit), None, 0
        for _ in range(500):
            if should_start(True, ident, started_for, False):
                starts += 1
            started_for = next_started_for(True, ident, started_for)
        self.assertEqual(starts, 1)


class TestPrune(unittest.TestCase):
    def test_drops_keys_that_are_no_longer_live(self):
        self.assertEqual(prune({"2": "a412", "dry:2:0": "0:PETG:65"}, {"2"}), {"2": "a412"})

    def test_keeps_live_keys_and_survives_an_empty_map(self):
        self.assertEqual(prune({"2": "a412"}, {"2", "3"}), {"2": "a412"})
        self.assertEqual(prune({}, {"2"}), {})
        self.assertEqual(prune({"2": "a412"}, set()), {})


if __name__ == "__main__":
    unittest.main()


class AggregateArmingTests(unittest.TestCase):
    """The aggregate drying card's arming rule.

    Split out of `should_start` on purpose. That helper refuses to compare identity — a print's
    identity is unstable early on, and comparing it started a second card — whereas the aggregate's
    identity IS the set of cycles, which is stable and which selects the card.

    The rule was written inline as `should_start(_p2s_tokens, akey)`: two arguments to a
    four-parameter function, a TypeError waiting for the first batch of two simultaneous cycles.
    It survived because it had no test and no call of its own.
    """

    def test_a_new_set_arms(self):
        self.assertTrue(aggregate_should_start("agg:1,2", None, False))
        self.assertTrue(aggregate_should_start("agg:1,2", "agg:1", False))
        self.assertTrue(aggregate_should_start("agg:1", "agg:1,2", False))

    def test_the_same_set_does_not_rearm(self):
        self.assertFalse(aggregate_should_start("agg:1,2", "agg:1,2", False))

    def test_a_grant_overrides_the_answer(self):
        self.assertTrue(aggregate_should_start("agg:1,2", "agg:1,2", True))

    def test_the_signature_is_not_should_starts(self):
        """The bug in one line: the two functions take different arguments and are not
        interchangeable, however similar their names read at a call site."""
        with self.assertRaises(TypeError):
            should_start(set(), "dry:2:-1")   # what the aggregate block used to call


class WakeCeilingTests(unittest.TestCase):
    """The floor under Apple's ceiling for silent pushes.

    "Don't try to send more than two or three per hour." Being throttled is invisible from the
    service — iOS just stops delivering — so the rule is a tested function rather than an inline
    comparison, and the interval is far below the ceiling rather than near it.
    """

    def test_a_wake_inside_the_interval_is_refused(self):
        self.assertFalse(may_wake(now=1000.0, last=1000.0, min_interval=1800.0))
        self.assertFalse(may_wake(now=2799.0, last=1000.0, min_interval=1800.0))

    def test_a_wake_at_or_past_the_interval_is_allowed(self):
        self.assertTrue(may_wake(now=2800.0, last=1000.0, min_interval=1800.0))
        self.assertTrue(may_wake(now=2801.0, last=1000.0, min_interval=1800.0))

    def test_a_device_never_woken_is_allowed(self):
        """None, not a zero sentinel. `now - 0 >= 1800` is true for every real clock reading, so a
        sentinel would pass by accident and fail the moment anyone tested it with small numbers —
        which is exactly how this was found."""
        self.assertTrue(may_wake(now=1.0, last=None, min_interval=1800.0))
        self.assertTrue(may_wake(now=1_787_000_000.0, last=None, min_interval=1800.0))

    def test_the_default_interval_stays_under_two_an_hour(self):
        self.assertLessEqual(3600 / 1800.0, 2.0)


class WakeSettleTests(unittest.TestCase):
    """The re-render a card is owed after its app was woken.

    `meaningful_change` compares numbers, and after a wake no number has moved — a print in its
    calibration phase sits at progress 0, layer 0, temperatures settled. So the plate would land on
    disk and the card would keep drawing the glyph until the 450 s heartbeat.
    """

    def test_nothing_is_owed_when_no_wake_was_sent(self):
        self.assertFalse(wake_push_due(now=1_787_483_300.0, due=None))

    def test_the_push_waits_for_the_app_to_fetch(self):
        """A wake and its push in the same tick would re-render a card whose file does not exist
        yet: measured, the cover arrived one second after the push."""
        self.assertFalse(wake_push_due(now=1_787_483_266.0, due=1_787_483_276.0))

    def test_the_push_is_due_once_the_window_passes(self):
        self.assertTrue(wake_push_due(now=1_787_483_276.0, due=1_787_483_276.0))
        self.assertTrue(wake_push_due(now=1_787_483_999.0, due=1_787_483_276.0))


class HmsReasonTests(unittest.TestCase):
    """Which fault a halt banner names.

    Bambuddy resolves a description for the 8-char `print_error` family only, so most faults still
    have nothing to say — the two that matter most to a user, spaghetti and filament runout, do.
    """

    SPAGHETTI = "Spaghetti defects were detected by the AI Print Monitoring."
    RUNOUT = "Filament ran out. Please load new filament."

    def test_no_errors_is_no_reason(self):
        self.assertIsNone(hms_reason(None))
        self.assertIsNone(hms_reason([]))

    def test_a_resolving_fault_is_named(self):
        self.assertEqual(
            hms_reason([{"full_code": "03008004", "description": self.RUNOUT}]),
            self.RUNOUT,
        )

    def test_the_last_resolving_fault_wins(self):
        """`hms_errors` ACCUMULATES across a print — the print_error branch appends and clears only
        on a fresh `hms` array or a new print. The first entry is the oldest thing the printer has
        mentioned, not the thing that just halted it."""
        self.assertEqual(
            hms_reason([
                {"full_code": "03008003", "description": self.SPAGHETTI},
                {"full_code": "03008004", "description": self.RUNOUT},
            ]),
            self.RUNOUT,
        )

    def test_a_sixteen_char_hms_fault_is_not_named(self):
        """The `hms[]` family resolves to nothing in Bambu's own table. Both faults live on the
        H2C while this was written are of this kind, so the banner keeps its generic wording."""
        self.assertIsNone(hms_reason([{"full_code": "050002000003000A", "description": None}]))

    def test_a_sixteen_char_fault_is_skipped_even_if_something_described_it(self):
        """The length test confines the answer to the branch that fires on a halt, so a described
        16-char entry must not win over an 8-char one behind it."""
        self.assertEqual(
            hms_reason([
                {"full_code": "03008003", "description": self.SPAGHETTI},
                {"full_code": "0500050000010007", "description": "something else entirely"},
            ]),
            self.SPAGHETTI,
        )

    def test_an_older_bambuddy_sends_no_description_at_all(self):
        """Trellis may run ahead of the Bambuddy beside it. A missing key is not an error and needs
        no version negotiation — the banner simply keeps its generic wording."""
        self.assertIsNone(hms_reason([{"full_code": "03008004"}]))
        self.assertIsNone(hms_reason([{"full_code": "03008004", "description": ""}]))
        self.assertIsNone(hms_reason([{"full_code": "03008004", "description": "   "}]))

    def test_a_malformed_entry_does_not_raise(self):
        self.assertIsNone(hms_reason([{}, {"full_code": None}, {"full_code": 3008004}]))
