"""Unit tests for the push-to-start rule. Run: python3 -m unittest discover deploy/la-push"""
from __future__ import annotations

import unittest

from p2s import dry_identity, next_started_for, print_identity, prune, should_start


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
