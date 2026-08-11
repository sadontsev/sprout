"""Tests for the multi-device card registry.

Each test names the silent failure it prevents. Nothing here fails loudly in
production: APNs answers 200 to a push nobody sees, the poll loop swallows
exceptions, and /health keeps reporting ok — so these assertions are the only
place the difference between a working card and a frozen one is visible.
"""

import unittest

import registry as reg


def card(device, token, printer_id=1, **extra):
    out = {"deviceId": device, "pushToken": token, "printerId": printer_id}
    out.update(extra)
    return out


class TestCoerce(unittest.TestCase):
    def test_single_card_format_migrates(self):
        got = reg.coerce({"1": {"pushToken": "tokA", "printerId": 1}})

        self.assertEqual(list(got), ["1"])
        self.assertEqual(len(got["1"]), 1)
        self.assertEqual(got["1"][0]["deviceId"], reg.LEGACY_DEVICE,
                         "migrated rows need an id so device-scoped operations can "
                         "reason about them instead of treating them as everyone's")

    def test_list_format_is_preserved(self):
        raw = {"1": [card("d1", "tokA"), card("d2", "tokB")]}
        got = reg.coerce(raw)
        self.assertEqual(len(got["1"]), 2)

    def test_coercion_is_idempotent_across_a_rollback_round_trip(self):
        # Rolling back to the previous image rewrites the file in the old shape;
        # a re-upgrade has to survive that, which is why coercion stays in the
        # load path forever rather than running once.
        once = reg.coerce({"1": {"pushToken": "tokA", "printerId": 1}})
        twice = reg.coerce(once)
        self.assertEqual(once, twice)

    def test_junk_is_discarded_without_raising(self):
        got = reg.coerce({"1": "nonsense", "2": None, "3": [1, 2, "x"], "4": []})
        self.assertEqual(got, {}, "a key with nothing usable must not survive as an "
                                  "empty list: that reads as 'a card exists' forever")

    def test_non_dict_input_is_survivable(self):
        self.assertEqual(reg.coerce(None), {})
        self.assertEqual(reg.coerce("nonsense"), {})


class TestPerDevicePresence(unittest.TestCase):
    def test_has_card_is_scoped_to_the_device(self):
        regs = {"1": [card("phoneA", "tokA")]}

        self.assertTrue(reg.has_card(regs, "1", "phoneA"))
        self.assertFalse(
            reg.has_card(regs, "1", "phoneB"),
            "asking whether the KEY exists instead answers a nearby question: once "
            "one phone adopts a card the other never receives a start again, for "
            "any print, and nothing logs it",
        )

    def test_missing_key_has_no_card(self):
        self.assertFalse(reg.has_card({}, "1", "phoneA"))


class TestUpsert(unittest.TestCase):
    def test_two_devices_coexist(self):
        regs: reg.Registry = {}
        reg.upsert(regs, "1", card("phoneA", "tokA"))
        reg.upsert(regs, "1", card("phoneB", "tokB"))

        self.assertEqual(len(regs["1"]), 2,
                         "the second registration must not clobber the first — that "
                         "is what freezes one phone's card for a whole print")

    def test_same_device_replaces_its_own_row(self):
        regs: reg.Registry = {}
        reg.upsert(regs, "1", card("phoneA", "tokOld"))
        reg.upsert(regs, "1", card("phoneA", "tokNew"))

        self.assertEqual(len(regs["1"]), 1)
        self.assertEqual(regs["1"][0]["pushToken"], "tokNew",
                         "a token rotation must replace the device's row, not add one")

    def test_same_token_replaces_even_without_a_device_id(self):
        regs: reg.Registry = {"1": [{"pushToken": "tokA", "printerId": 1}]}
        reg.upsert(regs, "1", {"pushToken": "tokA", "printerId": 1, "printerName": "P"})

        self.assertEqual(len(regs["1"]), 1)
        self.assertEqual(regs["1"][0]["printerName"], "P")

    def test_per_element_state_is_not_shared(self):
        # The most damaging thing to get wrong, and the most tempting to
        # "simplify". A shared lastPush makes one device's push start another's
        # 30-second throttle; a shared lastState makes meaningful_change compare
        # against content the other device never received, freezing its card.
        regs: reg.Registry = {}
        reg.upsert(regs, "1", card("phoneA", "tokA", lastPush=100, lastState={"progress": 5}))
        reg.upsert(regs, "1", card("phoneB", "tokB"))

        a, b = regs["1"]
        self.assertEqual(a["lastPush"], 100)
        self.assertIsNone(b.get("lastPush"),
                          "a fresh device must have no push history, so its first "
                          "push is treated as urgent and goes out at priority 10")
        self.assertIsNone(b.get("lastState"))


class TestDrops(unittest.TestCase):
    def test_dropping_a_dead_token_spares_the_other_devices(self):
        # 400/410 is a statement about one device. Removing the key would freeze
        # every other device's card, never end it, and — because the key
        # vanished — start a duplicate underneath on the next tick.
        regs = {"1": [card("phoneA", "tokA"), card("phoneB", "tokB")]}

        self.assertTrue(reg.drop_token(regs, "1", "tokA"))
        self.assertEqual([r["deviceId"] for r in regs["1"]], ["phoneB"])

    def test_dropping_the_last_registration_removes_the_key(self):
        regs = {"1": [card("phoneA", "tokA")]}
        reg.drop_token(regs, "1", "tokA")

        self.assertNotIn("1", regs,
                         "an empty list is truthy under `key in regs`, so leaving one "
                         "behind silently disables push-to-start for that printer forever")

    def test_dropping_an_unknown_token_changes_nothing(self):
        regs = {"1": [card("phoneA", "tokA")]}
        self.assertFalse(reg.drop_token(regs, "1", "nope"))
        self.assertEqual(len(regs["1"]), 1)

    def test_drop_device(self):
        regs = {"1": [card("phoneA", "tokA"), card("phoneB", "tokB")]}
        self.assertTrue(reg.drop_device(regs, "1", "phoneA"))
        self.assertEqual([r["deviceId"] for r in regs["1"]], ["phoneB"])

        self.assertTrue(reg.drop_device(regs, "1", "phoneB"))
        self.assertNotIn("1", regs)


class TestPrune(unittest.TestCase):
    def test_sync_only_drops_the_reporting_devices_rows(self):
        # The single most damaging operation if left unscoped: merely opening the
        # app on one phone would deregister every card on the other, which then
        # freezes on its lock screen with no owner and no way to report it.
        regs = {
            "1": [card("phoneA", "tokA"), card("phoneB", "tokB")],
            "2": [card("phoneB", "tokC", printer_id=2)],
        }

        reg.prune_device(regs, "phoneA", seen_tokens=[])

        self.assertEqual([r["deviceId"] for r in regs["1"]], ["phoneB"])
        self.assertEqual(len(regs["2"]), 1, "another printer's other-device card is untouched")

    def test_a_device_keeps_the_tokens_it_still_reports(self):
        regs = {"1": [card("phoneA", "tokA"), card("phoneA", "tokDead")]}
        reg.prune_device(regs, "phoneA", seen_tokens=["tokA"])

        self.assertEqual([r["pushToken"] for r in regs["1"]], ["tokA"])

    def test_pruning_everything_removes_the_key(self):
        regs = {"1": [card("phoneA", "tokA")]}
        reg.prune_device(regs, "phoneA", seen_tokens=[])
        self.assertNotIn("1", regs)

    def test_pruning_reports_which_keys_changed(self):
        regs = {"1": [card("phoneA", "tokA")], "2": [card("phoneB", "tokB", printer_id=2)]}
        self.assertEqual(reg.prune_device(regs, "phoneA", seen_tokens=[]), ["1"])


class TestAggregates(unittest.TestCase):
    def test_printer_ids_flattens_every_device(self):
        regs = {
            "1": [card("phoneA", "tokA", printer_id=1), card("phoneB", "tokB", printer_id=1)],
            "dry:2:128": [card("phoneA", "tokC", printer_id=2)],
        }
        self.assertEqual(reg.printer_ids(regs), {1, 2})

    def test_printer_ids_survives_a_malformed_row(self):
        # This set drives which printers get polled at all. A TypeError here dies
        # on the first line of the tick, before any card is updated or any banner
        # sent — and the poll loop swallows it, so the only symptom is a log line.
        regs = {"1": [card("phoneA", "tokA"), {"pushToken": "x"}, {"printerId": "junk"}]}
        self.assertEqual(reg.printer_ids(regs), {1})

    def test_card_count_counts_registrations_not_keys(self):
        regs = {"1": [card("phoneA", "tokA"), card("phoneB", "tokB")]}
        self.assertEqual(reg.card_count(regs), 2,
                         "counting keys would report one when two exist, making a "
                         "half-failed migration look clean to whoever checks after deploy")

    def test_count_by_client_handles_a_mixed_fleet(self):
        # This tally is the only way to spot a native build that silently
        # registered as expo, and a mixed fleet is exactly when that happens.
        regs = {"1": [card("phoneA", "tokA", client="expo"), card("phoneB", "tokB", client="native")]}
        got = reg.count_by(regs, lambda r: r.get("client", "expo"))
        self.assertEqual(got, {"expo": 1, "native": 1})

    def test_all_tokens(self):
        regs = {"1": [card("phoneA", "tokA"), card("phoneB", "tokB")]}
        self.assertEqual(reg.all_tokens(regs), {"tokA", "tokB"})

    def test_find_by_token(self):
        regs = {"1": [card("phoneA", "tokA")], "2": [card("phoneB", "tokB", printer_id=2)]}
        found = reg.find_by_token(regs, "tokB")

        self.assertIsNotNone(found)
        key, row = found
        self.assertEqual(key, "2")
        self.assertEqual(row["deviceId"], "phoneB")
        self.assertIsNone(reg.find_by_token(regs, "nope"))


class TestCardsAccessor(unittest.TestCase):
    def test_missing_key_yields_an_empty_list(self):
        self.assertEqual(reg.cards({}, "1"), [])

    def test_iteration_is_safe_over_a_snapshot(self):
        # _tick mutates while iterating; callers take the list from here and the
        # registry may change underneath. Mutating during iteration raises inside
        # the poll loop, which swallows it, so drying cards just stop updating.
        regs = {"1": [card("phoneA", "tokA"), card("phoneB", "tokB")]}
        for row in list(reg.cards(regs, "1")):
            reg.drop_token(regs, "1", row["pushToken"])
        self.assertNotIn("1", regs)


if __name__ == "__main__":
    unittest.main()
