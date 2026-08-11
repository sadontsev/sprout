"""Integration tests for the multi-device registry, through the real endpoints.

app.py has never had tests. That matters more than usual here because its poll
loop wraps everything in `except Exception`: a mistake does not crash the
container, it leaves /health reporting ok:true while every card quietly stops
updating. These tests exercise the endpoints that two phones share, which is the
case the single-card registry got wrong in every direction at once.

Requires the service's own dependencies (fastapi, httpx, pydantic), so it is
skipped where they are absent — the same reason test_makerworld skips outside
the container.
"""

import os
import unittest

os.environ.setdefault("BAMBUDDY_API_KEY", "test-key")
os.environ.setdefault("APNS_KEY_ID", "KEYID")
os.environ.setdefault("APNS_TEAM_ID", "TEAMID")
os.environ.setdefault("APNS_TOPIC", "com.example.app.push-type.liveactivity")

try:
    from fastapi.testclient import TestClient
    import app as la
    import registry
    HAVE_DEPS = True
except Exception:  # noqa: BLE001 - missing service deps outside the container
    HAVE_DEPS = False


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class MultiDeviceRegistry(unittest.TestCase):
    def setUp(self):
        # Bypass the Bambuddy round trip the API-key guard would otherwise make.
        la.app.dependency_overrides[la._require_key] = lambda: None
        self.client = TestClient(la.app)
        la._regs = {}
        la._p2s_tokens = []
        la._p2s_devices = {}
        la._p2s_pending = {}
        la._device_tokens = []
        la._suspended = {}
        la._needs_claim = {}
        la._save = lambda: None  # keep the tests off the filesystem

    def tearDown(self):
        la.app.dependency_overrides.clear()

    def register(self, printer_id, token, device, **extra):
        body = {
            "printer_id": printer_id, "push_token": token, "device_id": device,
            "printer_name": "Printer", **extra,
        }
        return self.client.post("/register", json=body)

    def test_two_phones_both_keep_their_card(self):
        self.assertEqual(self.register(1, "tokA", "phoneA").status_code, 200)
        self.assertEqual(self.register(1, "tokB", "phoneB").status_code, 200)

        self.assertEqual(
            len(la._regs["1"]), 2,
            "the second phone's registration must not clobber the first — that is "
            "what froze one phone's card for the rest of a print",
        )

    def test_re_registering_replaces_only_that_devices_row(self):
        self.register(1, "tokA", "phoneA")
        self.register(1, "tokB", "phoneB")
        self.register(1, "tokA2", "phoneA")  # token rotation on phone A

        tokens = sorted(r["pushToken"] for r in la._regs["1"])
        self.assertEqual(tokens, ["tokA2", "tokB"])

    def test_per_device_state_is_not_shared(self):
        self.register(1, "tokA", "phoneA")
        la._regs["1"][0]["lastPush"] = 12345
        la._regs["1"][0]["lastState"] = {"progress": 42}
        self.register(1, "tokB", "phoneB")

        phone_b = next(r for r in la._regs["1"] if r["deviceId"] == "phoneB")
        self.assertEqual(phone_b["lastPush"], 0)
        self.assertIsNone(
            phone_b["lastState"],
            "a shared lastState makes meaningful_change compare against content "
            "this phone never received, freezing its card at old progress",
        )

    def test_sync_from_one_phone_leaves_the_others_cards_alone(self):
        # The most damaging operation if unscoped: merely opening the app on one
        # phone would deregister every card on the other, which then freezes with
        # no owner while the next tick starts a duplicate underneath.
        self.register(1, "tokA", "phoneA")
        self.register(1, "tokB", "phoneB")

        resp = self.client.post("/sync", json={"tokens": [], "device_id": "phoneA"})
        self.assertEqual(resp.status_code, 200)

        self.assertEqual([r["deviceId"] for r in la._regs["1"]], ["phoneB"])

    def test_sync_keeps_the_tokens_the_device_still_reports(self):
        self.register(1, "tokA", "phoneA")
        self.client.post("/sync", json={"tokens": ["tokA"], "device_id": "phoneA"})
        self.assertEqual(len(la._regs["1"]), 1)

    def test_sync_returns_only_this_devices_needs_claim(self):
        la._needs_claim = {"tokA": "phoneA", "tokB": "phoneB"}
        body = self.client.post("/sync", json={"tokens": [], "device_id": "phoneA"}).json()

        self.assertEqual(
            body["needs_claim"], ["tokA"],
            "handing one phone another's tokens would have it claim tokens it does "
            "not hold, which is an attestation oracle",
        )

    def test_unregister_is_token_scoped(self):
        self.register(1, "tokA", "phoneA")
        self.register(1, "tokB", "phoneB")

        resp = self.client.post("/unregister", params={"printer_id": 1, "push_token": "tokA"})
        self.assertEqual(resp.status_code, 200)
        self.assertEqual([r["deviceId"] for r in la._regs["1"]], ["phoneB"])

    def test_unregistering_the_last_card_removes_the_key(self):
        self.register(1, "tokA", "phoneA")
        self.client.post("/unregister", params={"printer_id": 1, "push_token": "tokA"})

        self.assertNotIn(
            "1", la._regs,
            "an empty list is truthy under `key in _regs`, which reads as 'a card "
            "exists' and silently blocks push-to-start for that printer forever",
        )

    def test_health_counts_registrations_not_keys(self):
        self.register(1, "tokA", "phoneA")
        self.register(1, "tokB", "phoneB")

        body = self.client.get("/health").json()
        self.assertEqual(
            body["registrations"], 2,
            "reporting one when two exist makes a half-failed migration look clean "
            "to whoever checks straight after a deploy",
        )

    def test_health_reports_a_mixed_fleet(self):
        self.register(1, "tokA", "phoneA", client="expo")
        self.register(1, "tokB", "phoneB", client="native")

        by_client = self.client.get("/health").json()["cards_by_client"]
        self.assertEqual(by_client.get("expo"), 1)
        self.assertEqual(
            by_client.get("native"), 1,
            "this tally is the only way to spot a native build that silently "
            "registered as expo, and a mixed fleet is exactly when that happens",
        )

    def test_legacy_state_on_disk_still_loads(self):
        la._regs = registry.coerce({"1": {"printerId": 1, "pushToken": "old"}})
        self.register(1, "tokNew", "phoneB")

        self.assertEqual(len(la._regs["1"]), 2)
        self.assertEqual(la._regs["1"][0]["deviceId"], registry.LEGACY_DEVICE)

    def test_push_to_start_pending_is_per_device(self):
        la._p2s_pending = {la._pending_id("1", "phoneA"): 1e12}

        self.assertEqual(la._pending_key("phoneA"), "1")
        self.assertIsNone(
            la._pending_key("phoneB"),
            "a global pending claim means one phone's unresolved start blocks the "
            "other's, so the second phone never adopts a card",
        )


if __name__ == "__main__":
    unittest.main()
