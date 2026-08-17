"""Unit tests for the per-client Live-Activity wire shapes. Run: python3 -m unittest discover deploy/Trellis

Deliberately dependency-free (stdlib unittest, no pytest/httpx/fastapi) so it runs anywhere the
service does, including inside the container — same rule as test_cooldown.py / test_p2s.py.

What these are really guarding: BOTH ways of getting the shape wrong return HTTP 200 from APNs and
then do nothing on the phone. There is no error to observe and no log to read, so the only place the
mistake can be caught is here.
"""
from __future__ import annotations

import json
import unittest

from clients import EXPO, NATIVE, NATIVE_BASE, client_of, envelope, key_ids, norm_client, start_attributes

# A representative print content state, exactly as app.py's classify() + _tick build it.
PRINT_CS = {
    "printerName": "H2C", "iconUri": "file:///nozzle.png", "name": "cube.3mf",
    "stateLabel": "Printing", "tint": "#30D158", "progress": 42, "layer": 88, "totalLayers": 210,
    "etaEpochMs": 1_700_000_000_000, "finished": False, "symbol": "square.stack.3d.up.fill",
    "nozzle": 220, "nozzleTarget": 220, "nozzle2": 0, "nozzle2Target": 0, "hasNozzle2": False,
    "activeNozzle": 0, "bed": 60, "bedTarget": 60, "modelUri": "", "queueCount": 0, "nextName": "",
}
DRY_CS = {
    "printerName": "H2C", "iconUri": "", "dry": True, "stateLabel": "Drying",
    "name": "AMS HT · PETG-CF @ 85°", "tint": "#FFB86C", "symbol": "humidity.fill",
    "progress": 0, "layer": 0, "totalLayers": 0, "etaEpochMs": 1_700_000_000_000, "finished": False,
    "amsTemp": 62, "amsTarget": 85, "humidity": 12,
    "nozzle": 0, "nozzleTarget": 0, "nozzle2": 0, "nozzle2Target": 0, "hasNozzle2": False,
    "activeNozzle": 0, "bed": 0, "bedTarget": 0, "modelUri": "", "queueCount": 0, "nextName": "",
}


class TestNormClient(unittest.TestCase):
    def test_the_default_is_expo_so_the_installed_RN_BUILD_IS_UNCHANGED(self):
        # THE compatibility rule: the RN app never sends the field and can only be changed by an OTA,
        # so every way of not saying anything has to keep meaning "expo".
        for absent in (None, "", "   ", 0, False, [], {}):
            self.assertEqual(norm_client(absent), EXPO)

    def test_native_is_recognised_case_and_whitespace_insensitively(self):
        for v in ("native", "Native", "NATIVE", " native "):
            self.assertEqual(norm_client(v), NATIVE)

    def test_an_unknown_value_degrades_to_expo_rather_than_erroring(self):
        # A refused registration is a card frozen at 0 % that looks exactly like Trellis being down.
        self.assertEqual(norm_client("swiftui"), EXPO)
        self.assertEqual(norm_client("expo "), EXPO)

    def test_client_of_reads_a_stored_registration(self):
        self.assertEqual(client_of({"client": "native"}), NATIVE)
        self.assertEqual(client_of({"client": "expo"}), EXPO)
        # Registrations persisted before the field existed, and a missing registration entirely.
        self.assertEqual(client_of({"printerId": 2, "pushToken": "t"}), EXPO)
        self.assertEqual(client_of(None), EXPO)


class TestEnvelope(unittest.TestCase):
    def test_expo_gets_the_wrapped_props_string_exactly_as_before(self):
        env = envelope(PRINT_CS, EXPO)
        self.assertEqual(set(env), {"name", "props"})
        self.assertEqual(env["name"], "PrintActivity")
        self.assertIsInstance(env["props"], str)  # a DICT here fails to decode on-device
        self.assertEqual(json.loads(env["props"]), PRINT_CS)

    def test_expo_props_stay_compact_json(self):
        self.assertNotIn(", ", envelope(PRINT_CS, EXPO)["props"])

    def test_native_gets_the_flat_state_with_no_wrapper(self):
        env = envelope(PRINT_CS, NATIVE)
        self.assertNotIn("props", env)
        self.assertEqual(env["stateLabel"], "Printing")
        self.assertEqual(env["progress"], 42)
        for k, v in PRINT_CS.items():
            self.assertEqual(env[k], v)

    def test_native_and_expo_never_produce_the_same_payload(self):
        self.assertNotEqual(envelope(PRINT_CS, NATIVE), envelope(PRINT_CS, EXPO))

    def test_the_default_and_unknown_clients_take_the_expo_shape(self):
        self.assertEqual(envelope(PRINT_CS, "expo"), envelope(PRINT_CS, "who?"))
        self.assertEqual(envelope(PRINT_CS, "who?")["name"], "PrintActivity")

    def test_native_print_state_carries_every_field_swift_requires(self):
        # Swift's synthesized Decodable THROWS on a missing key rather than using the property's
        # default, and one throw discards the whole push while APNs still answers 200.
        env = envelope(PRINT_CS, NATIVE)
        for field in NATIVE_BASE:
            self.assertIn(field, env)

    def test_native_print_state_does_NOT_claim_to_be_a_drying_card(self):
        # `dry`/`amsTemp`/… are Optionals on the Swift side; padding them would make the widget take
        # the drying branch for a print.
        env = envelope(PRINT_CS, NATIVE)
        for field in ("dry", "amsTemp", "amsTarget", "humidity"):
            self.assertNotIn(field, env)

    def test_native_drying_state_keeps_its_drying_fields(self):
        env = envelope(DRY_CS, NATIVE)
        self.assertIs(env["dry"], True)
        self.assertEqual((env["amsTemp"], env["amsTarget"], env["humidity"]), (62, 85, 12))
        self.assertEqual(env["stateLabel"], "Drying")

    def test_a_sparse_end_payload_is_padded_for_native(self):
        # _push_end merges over a card's stored lastState, which is None for a card that ended before
        # it was ever updated — so an end really can arrive with a handful of keys. Unpadded, Swift
        # drops it and the card stays on the lock screen with nothing able to clear it.
        sparse = {"printerName": "H2C", "dry": True, "stateLabel": "Done", "finished": True, "etaEpochMs": 0}
        env = envelope(sparse, NATIVE)
        for field in NATIVE_BASE:
            self.assertIn(field, env)
        # The caller's values win over the padding.
        self.assertEqual(env["stateLabel"], "Done")
        self.assertIs(env["finished"], True)
        self.assertEqual(env["printerName"], "H2C")
        self.assertEqual(env["etaEpochMs"], 0)

    def test_padding_never_touches_the_expo_shape(self):
        sparse = {"stateLabel": "Done", "finished": True}
        self.assertEqual(json.loads(envelope(sparse, EXPO)["props"]), sparse)


class TestStartAttributes(unittest.TestCase):
    def test_expo_starts_are_byte_for_byte_what_they_always_were(self):
        self.assertEqual(start_attributes(EXPO, 2, None), ("LiveActivityAttributes", {}))
        self.assertEqual(start_attributes(EXPO, 2, 128), ("LiveActivityAttributes", {}))
        self.assertEqual(start_attributes("anything else", 2, 128), ("LiveActivityAttributes", {}))

    def test_native_print_start_names_the_swift_type_and_the_printer(self):
        self.assertEqual(start_attributes(NATIVE, 7, None), ("PrintActivityAttributes", {"printerId": 7}))

    def test_native_print_start_omits_amsId(self):
        # `Int?` in Swift, decoded with decodeIfPresent; a drying card is identified BY carrying it.
        self.assertNotIn("amsId", start_attributes(NATIVE, 7, None)[1])

    def test_native_drying_start_carries_its_unit(self):
        self.assertEqual(start_attributes(NATIVE, 7, 128), ("PrintActivityAttributes", {"printerId": 7, "amsId": 128}))
        # AMS unit 0 is a real unit — a falsy id must not be dropped.
        self.assertEqual(start_attributes(NATIVE, 7, 0), ("PrintActivityAttributes", {"printerId": 7, "amsId": 0}))

    def test_the_two_clients_never_share_an_attributes_type(self):
        self.assertNotEqual(start_attributes(NATIVE, 7, None)[0], start_attributes(EXPO, 7, None)[0])


class TestKeyIds(unittest.TestCase):
    def test_a_print_key_is_just_the_printer(self):
        self.assertEqual(key_ids("2"), (2, None))

    def test_a_drying_key_carries_its_unit(self):
        self.assertEqual(key_ids("dry:2:0"), (2, 0))
        self.assertEqual(key_ids("dry:2:128"), (2, 128))

    def test_the_legacy_per_printer_drying_key_still_parses(self):
        # Registrations written before drying cards were keyed per unit.
        self.assertEqual(key_ids("dry:2"), (2, None))

    def test_round_trips_the_keys_app_py_builds(self):
        for pid, ams in ((2, None), (7, 0), (7, 128)):
            key = str(pid) if ams is None else f"dry:{pid}:{ams}"
            self.assertEqual(key_ids(key), (pid, ams))


class TestTheTwoClientsTogether(unittest.TestCase):
    """The whole point: one poll tick pushes the same content state to both apps, and each has to get
    a payload its own decoder accepts."""

    def test_one_content_state_becomes_two_valid_payloads(self):
        expo_env, native_env = envelope(PRINT_CS, EXPO), envelope(PRINT_CS, NATIVE)
        self.assertEqual(json.loads(expo_env["props"])["progress"], 42)
        self.assertEqual(native_env["progress"], 42)

    def test_a_registration_dict_drives_the_shape_end_to_end(self):
        rn = {"printerId": 2, "pushToken": "a", "client": "expo"}
        sw = {"printerId": 2, "pushToken": "b", "client": "native"}
        legacy = {"printerId": 2, "pushToken": "c"}  # persisted before the field existed
        self.assertEqual(envelope(PRINT_CS, client_of(rn))["name"], "PrintActivity")
        self.assertEqual(envelope(PRINT_CS, client_of(legacy))["name"], "PrintActivity")
        self.assertEqual(envelope(PRINT_CS, client_of(sw))["stateLabel"], "Printing")


if __name__ == "__main__":
    unittest.main()
