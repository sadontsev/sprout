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
except ImportError:  # the service's own deps are absent; see scripts-test.sh
    HAVE_DEPS = False
else:
    HAVE_DEPS = True
    # Deliberately OUTSIDE the guard, and catching ImportError only. With the
    # dependencies present, a failure to import app is a bug IN APP, and the
    # first version of this file swallowed it: `except Exception` around both
    # imports turned "app.py is broken" into twelve silent skips and a green
    # run. That is the exact shape this codebase keeps rediscovering — a guard
    # answering a nearby question ("did anything go wrong?") instead of the
    # real one ("are the dependencies installed?").
    import app as la
    import registry


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


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class RegistrationReportsWhetherItBound(unittest.TestCase):
    """The bug that froze a live card for a whole print.

    A registration whose claim could not be built on the phone is still STORED — the card is real
    and Trellis answers 200 — but the token is not bound at the relay and cannot be pushed to. The
    app used to read that 200 as "registration finished", mark the pair done, and never retry, so a
    transient App Attest failure became a permanently frozen Live Activity with every component
    reporting success.

    So the response has to answer the second question separately.
    """

    def setUp(self):
        la.app.dependency_overrides[la._require_key] = lambda: None
        self.client = TestClient(la.app)
        la._regs = {}
        la._needs_claim = {}
        la._p2s_tokens = []
        la._p2s_icons = {}
        la._p2s_clients = {}
        la._p2s_devices = {}
        la._p2s_pending = {}
        la._device_tokens = []
        la._suspended = {}
        la._save = lambda: None
        self._relay = la.RELAY_MODE

    def tearDown(self):
        la.RELAY_MODE = self._relay
        la.app.dependency_overrides.clear()

    def _register(self, token="tok-1", claim=None):
        return self.client.post("/register", json={
            "printer_id": 1, "push_token": token, "printer_name": "P",
            "kind": "print", "device_id": "phoneA", "client": "native",
            **({"claim": claim} if claim else {}),
        })

    def test_a_relay_registration_without_a_claim_is_not_bound(self):
        la.RELAY_MODE = True
        r = self._register()

        self.assertEqual(r.status_code, 200, "the card itself is fine and must still be stored")
        self.assertIs(r.json()["bound"], False,
                      "an unclaimed token cannot be pushed to; saying otherwise freezes the card")

    def test_an_unbound_registration_is_remembered_as_needing_a_claim(self):
        # Clearing needs_claim here threw away the only record that this token still needs
        # claiming, so nothing downstream could ever tell the device to retry.
        la.RELAY_MODE = True
        self._register(token="tok-unbound")

        self.assertIn("tok-unbound", la._needs_claim)

    def test_the_card_is_still_stored_when_it_could_not_be_bound(self):
        la.RELAY_MODE = True
        self._register(token="tok-1")

        self.assertTrue(registry.has_card(la._regs, "1", "phoneA"),
                        "refusing to store the card would lose the print's name and icon too")

    def test_direct_mode_reports_bound_because_there_is_nothing_to_bind(self):
        # This deployment signs its own pushes. Reporting False here would make the app retry a
        # registration forever against a server that never had a binding to make.
        la.RELAY_MODE = False
        r = self._register()

        self.assertIs(r.json()["bound"], True)

    def test_start_and_device_registrations_answer_the_same_question(self):
        la.RELAY_MODE = True
        start = self.client.post("/register-start", json={
            "push_token": "start-1", "icon_uri": "", "device_id": "phoneA", "client": "native",
        })
        device = self.client.post("/register-device", json={
            "device_token": "dev-1", "device_id": "phoneA",
        })

        self.assertIs(start.json()["bound"], False)
        self.assertIs(device.json()["bound"], False)
        self.assertIn("start-1", la._needs_claim)
        self.assertIn("dev-1", la._needs_claim)


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class SyncCarriesTheReportingClient(unittest.TestCase):
    """A card adopted through /sync is pushed to with the payload shape of whichever app reported it.

    This path used to hardcode expo, with a note that the native app never posts here. It does now,
    and an unmarked adoption pushes an expo-shaped start at a native widget — accepted by APNs, and
    no card on the phone. Exactly the failure this codebase keeps rediscovering: a value that was
    safe to assume right up until the moment it wasn't.
    """

    def setUp(self):
        la.app.dependency_overrides[la._require_key] = lambda: None
        self.client = TestClient(la.app)
        la._regs = {}
        la._needs_claim = {}
        la._p2s_pending = {la._pending_id("2", "phoneA"): 9e12}  # an outstanding remote start
        la._printers_cache = {2: "H2C"}
        la._save = lambda: None

    def tearDown(self):
        la.app.dependency_overrides.clear()

    def adopt(self, **extra):
        self.client.post("/sync", json={"tokens": ["tok-new"], "device_id": "phoneA", **extra})
        return la._regs["2"][0]

    def test_a_native_report_adopts_the_card_as_native(self):
        self.assertEqual(self.adopt(client="native")["client"], "native")

    def test_an_unmarked_report_still_adopts_as_expo(self):
        # The installed RN app does not send the field, and must keep working unchanged.
        self.assertEqual(self.adopt()["client"], "expo")

    def test_an_unknown_client_degrades_to_expo_rather_than_failing(self):
        self.assertEqual(self.adopt(client="something-new")["client"], "expo")


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class SyncReconcilesGhostCards(unittest.TestCase):
    """The deadlock this path exists to break.

    A card that dies on the phone leaves a registration nothing can push into, and because Trellis
    refuses to start a card for a key it already holds, no replacement is ever made. Observed live:
    installing a new build terminated the running Live Activity, and the print then had no card at
    all until the registry was cleared by hand.
    """

    def setUp(self):
        la.app.dependency_overrides[la._require_key] = lambda: None
        self.client = TestClient(la.app)
        la._regs = {}
        la._needs_claim = {}
        la._p2s_pending = {}
        la._save = lambda: None

    def tearDown(self):
        la.app.dependency_overrides.clear()

    def test_a_card_the_device_can_no_longer_see_is_dropped(self):
        self.client.post("/register", json={
            "printer_id": 2, "push_token": "ghost", "printer_name": "H2C",
            "device_id": "phoneA", "client": "native",
        })
        self.client.post("/sync", json={"tokens": [], "device_id": "phoneA", "client": "native"})

        self.assertNotIn("2", la._regs,
                         "the ghost row blocks push-to-start for the rest of the print")

    def test_an_unclaimable_token_comes_back_for_the_app_to_end(self):
        body = self.client.post("/sync", json={
            "tokens": ["orphan"], "device_id": "phoneA", "client": "native",
        }).json()

        self.assertEqual(body["end"], ["orphan"])

    def test_needs_claim_is_returned_scoped_to_the_reporting_device(self):
        # The recovery signal the app acts on. Handing one phone another's tokens would have it
        # claim tokens it does not hold, which is an attestation oracle.
        la._needs_claim = {"mine": "phoneA", "theirs": "phoneB"}
        body = self.client.post("/sync", json={
            "tokens": [], "device_id": "phoneA", "client": "native",
        }).json()

        self.assertEqual(body["needs_claim"], ["mine"])


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class ADeadCardIsReplacedButADismissedOneIsNot(unittest.TestCase):
    """The distinction that decides whether a card comes back.

    Arming push-to-start is once per live session, so a mid-print identity change cannot spawn a
    second card. The cost was that a card which DIED mid-print was never replaced — the lock screen
    stayed empty for the rest of the print, which is exactly what happened when installing a new
    build terminated a running activity.

    /sync and /unregister carry opposite instructions and must not be collapsed:
      * /unregister is a dismissal the app WITNESSED. The user swiped it away; putting it back is
        the opposite of what they asked for.
      * /sync reporting a card absent, with no dismissal behind it, is a death.
    """

    def setUp(self):
        la.app.dependency_overrides[la._require_key] = lambda: None
        self.client = TestClient(la.app)
        la._regs = {}
        la._needs_claim = {}
        la._p2s_pending = {}
        la._p2s_rearm = {}
        la._p2s_started = {"2": "a133"}
        la._save = lambda: None

    def tearDown(self):
        la.app.dependency_overrides.clear()

    def register(self):
        self.client.post("/register", json={
            "printer_id": 2, "push_token": "tok", "printer_name": "H2C",
            "device_id": "phoneA", "client": "native",
        })

    def test_a_card_that_died_re_arms_push_to_start(self):
        self.register()
        self.client.post("/sync", json={"tokens": [], "device_id": "phoneA", "client": "native"})

        # A grant for THIS device, not a clear of the global session marker: that marker is the one
        # piece of push-to-start state not scoped per device, and clearing it re-armed every phone.
        self.assertIn(la._pending_id("2", "phoneA"), la._p2s_rearm,
                      "without a replacement grant the print runs to completion with no card")
        self.assertEqual(la._p2s_started.get("2"), "a133",
                         "the session marker must survive; it is global")

    def test_a_dismissal_does_not_re_arm(self):
        self.register()
        self.client.post("/unregister", params={
            "printer_id": 2, "push_token": "tok", "device_id": "phoneA",
        })

        self.assertEqual(la._p2s_rearm, {},
                         "the user swiped this away; bringing it straight back ignores them")
        self.assertEqual(la._p2s_started.get("2"), "a133")

    def test_re_arming_does_not_disturb_another_printers_card(self):
        self.register()
        la._p2s_started["9"] = "other"
        self.client.post("/sync", json={"tokens": [], "device_id": "phoneA", "client": "native"})

        self.assertEqual(la._p2s_started.get("9"), "other")
        self.assertNotIn(la._pending_id("9", "phoneA"), la._p2s_rearm)


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class ReArmIsPerDeviceAndOnlyForClientsThatReportDismissals(unittest.TestCase):
    """Two ways the replacement grant must not over-reach.

    Arming push-to-start is once per live session, so a card that dies mid-print is otherwise never
    replaced. Granting a replacement is right — but the first version cleared the global
    `_p2s_started`, and that key is the ONLY push-to-start state not scoped per device.
    """

    def setUp(self):
        la.app.dependency_overrides[la._require_key] = lambda: None
        self.client = TestClient(la.app)
        la._regs = {}
        la._needs_claim = {}
        la._p2s_pending = {}
        la._p2s_rearm = {}
        la._p2s_started = {"2": "a133"}
        la._save = lambda: None

    def tearDown(self):
        la.app.dependency_overrides.clear()

    def register(self, device="phoneA", token="tok"):
        self.client.post("/register", json={
            "printer_id": 2, "push_token": token, "printer_name": "H2C",
            "device_id": device, "client": "native",
        })

    def sync(self, device="phoneA", client="native", tokens=None):
        return self.client.post("/sync", json={
            "tokens": tokens or [], "device_id": device, "client": client,
        })

    def test_a_native_report_grants_a_replacement_for_that_device_only(self):
        self.register(device="phoneA")
        self.sync(device="phoneA")

        self.assertIn(la._pending_id("2", "phoneA"), la._p2s_rearm)
        self.assertNotIn(la._pending_id("2", "phoneB"), la._p2s_rearm)

    def test_the_global_session_marker_is_left_alone(self):
        # Clearing it re-armed EVERY device, stacking a second card onto a phone that still had one
        # it had never adopted.
        self.register(device="phoneA")
        self.sync(device="phoneA")

        self.assertEqual(la._p2s_started.get("2"), "a133")

    def test_an_expo_report_does_not_grant_a_replacement(self):
        # The RN app's only reconcile path is /sync, so a swipe and a death look identical from it.
        # Granting on that basis puts a card the user deliberately dismissed straight back within
        # 45 seconds.
        self.register(device="phoneA")
        self.sync(device="phoneA", client="expo")

        self.assertEqual(la._p2s_rearm, {})

    def test_an_unmarked_client_is_treated_as_expo(self):
        self.register(device="phoneA")
        self.sync(device="phoneA", client="")

        self.assertEqual(la._p2s_rearm, {})

    def test_a_grant_makes_the_poll_loop_reach_remote_start(self):
        # should_start says no for the rest of the live session, so without this the grant would sit
        # unconsumed and no replacement would ever be made.
        self.assertFalse(la._has_rearm("2"))
        la._p2s_rearm[la._pending_id("2", "phoneA")] = 1.0
        self.assertTrue(la._has_rearm("2"))

    def test_a_grant_for_another_card_does_not_unblock_this_one(self):
        la._p2s_rearm[la._pending_id("dry:2:128", "phoneA")] = 1.0

        self.assertFalse(la._has_rearm("2"), "keys must not match on a prefix")
        self.assertTrue(la._has_rearm("dry:2:128"))
