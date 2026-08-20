import time
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

import asyncio
import os
import unittest

os.environ.setdefault("BAMBUDDY_API_KEY", "test-key")

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

    def tearDown(self):
        la.app.dependency_overrides.clear()

    def _register(self, token="tok-1", claim=None):
        return self.client.post("/register", json={
            "printer_id": 1, "push_token": token, "printer_name": "P",
            "kind": "print", "device_id": "phoneA", "client": "native",
            **({"claim": claim} if claim else {}),
        })

    def test_a_relay_registration_without_a_claim_is_not_bound(self):
        r = self._register()

        self.assertEqual(r.status_code, 200, "the card itself is fine and must still be stored")
        self.assertIs(r.json()["bound"], False,
                      "an unclaimed token cannot be pushed to; saying otherwise freezes the card")

    def test_an_unbound_registration_is_remembered_as_needing_a_claim(self):
        # Clearing needs_claim here threw away the only record that this token still needs
        # claiming, so nothing downstream could ever tell the device to retry.
        self._register(token="tok-unbound")

        self.assertIn("tok-unbound", la._needs_claim)

    def test_the_card_is_still_stored_when_it_could_not_be_bound(self):
        self._register(token="tok-1")

        self.assertTrue(registry.has_card(la._regs, "1", "phoneA"),
                        "refusing to store the card would lose the print's name and icon too")

    def test_start_and_device_registrations_answer_the_same_question(self):
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


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class ContactDiagnostics(unittest.TestCase):
    """Telling the operator what has NOT happened.

    The failure that motivated this logs nothing: the phone cannot reach Trellis, so there is no
    request to log and no verbosity setting that would produce one. The operator sees a healthy
    container, an empty log, and no way to tell "unreachable" from "working, nothing printing".
    """

    def setUp(self):
        la.app.dependency_overrides[la._require_key] = lambda: None
        self.client = TestClient(la.app)
        la._regs = {}
        la._device_tokens = []
        la._first_seen_any = None
        la._first_seen_authed = None
        la._seen_any = 0
        la._seen_unauthorized = 0
        la._save = lambda: None

    def tearDown(self):
        la.app.dependency_overrides.clear()

    def test_health_says_nothing_has_ever_connected(self):
        body = self.client.get("/health").json()["app_contact"]

        self.assertFalse(body["any_request"])
        self.assertFalse(body["authenticated"])
        self.assertEqual(body["requests"], 0)

    def test_a_request_is_recorded_as_contact(self):
        self.client.post("/sync", json={"tokens": [], "device_id": "phoneA", "client": "native"})
        body = self.client.get("/health").json()["app_contact"]

        self.assertTrue(body["any_request"], "the network path demonstrably works once anything arrives")
        self.assertEqual(body["requests"], 1)

    def test_health_itself_does_not_count_as_contact(self):
        # /health is what an operator curls WHILE debugging. Counting it would answer the question
        # with their own probe and report the path as working when nothing else has arrived.
        self.client.get("/health")
        self.client.get("/health")
        body = self.client.get("/health").json()["app_contact"]

        self.assertFalse(body["any_request"])
        self.assertEqual(body["requests"], 0)

    def test_reachable_but_unauthenticated_is_a_distinct_state(self):
        # The whole point of splitting these: "nothing arrived" is DNS/routing/TLS, "arrived and was
        # rejected" is the API key. Different problems, different files, indistinguishable from a
        # card count of zero.
        la.app.dependency_overrides.clear()  # exercise the real key gate
        self.client.post("/sync", json={"tokens": [], "device_id": "phoneA"})
        body = self.client.get("/health").json()["app_contact"]

        self.assertTrue(body["any_request"], "it reached us")
        self.assertFalse(body["authenticated"], "but it did not get past the key")
        self.assertGreaterEqual(body["rejected"], 1)


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class TheRealKeyGate(unittest.TestCase):
    """Exercise _require_key ITSELF, with no dependency_overrides.

    Every other test in this file replaces the gate with `lambda: None` to skip the Bambuddy round
    trip. That is reasonable for testing what is BEHIND the gate — and it meant the gate's own
    success path had never once been executed by the suite. A NameError on that path shipped green:
    224 passing tests, and every authenticated request in production answering 500.

    So these deliberately go through the real thing. `BAMBUDDY_API_KEY=test-key` is set at import,
    which makes the equality fast path reachable without any network.
    """

    def setUp(self):
        self.client = TestClient(la.app, raise_server_exceptions=False)
        la._regs = {}
        la._device_tokens = []
        la._first_seen_any = None
        la._first_seen_authed = None
        la._seen_any = 0
        la._seen_authed = 0
        la._seen_unauthorized = 0
        la._key_cache = {}
        la._save = lambda: None

    def post(self, key):
        headers = {"X-API-Key": key} if key else {}
        return self.client.post("/sync", json={"tokens": [], "device_id": "phoneA"}, headers=headers)

    def test_a_good_key_is_accepted(self):
        resp = self.post("test-key")

        self.assertEqual(
            resp.status_code, 200,
            "a 500 here is the gate throwing, and it locks out registration, sync and claims at "
            "once — every authenticated endpoint there is",
        )
        self.assertTrue(la._first_seen_authed, "the success path must record that it authenticated")

    def test_a_wrong_key_is_rejected_not_crashed(self):
        # Bambuddy is unreachable from the test env, so this exercises the fail-closed branch.
        resp = self.post("not-the-key")

        self.assertEqual(resp.status_code, 401)
        self.assertEqual(la._seen_unauthorized, 1)

    def test_a_missing_key_is_rejected(self):
        self.assertEqual(self.post(None).status_code, 401)
        self.assertEqual(la._seen_unauthorized, 1)

    def test_arrived_but_no_verdict_is_not_blamed_on_the_key(self):
        # The state the broken gate actually produced: requests arrive, none authenticate, and none
        # are rejected either. The watchdog used to call that "this is the API key", sending the
        # operator to check a credential that was never involved.
        la._seen_any, la._seen_unauthorized, la._first_seen_authed = 47, 0, None
        msg = self.watch_message()

        self.assertIn("NOT the API key", msg)
        self.assertIn("traceback", msg)

    def test_arrived_and_rejected_IS_blamed_on_the_key(self):
        la._seen_any, la._seen_unauthorized, la._first_seen_authed = 47, 47, None
        msg = self.watch_message()

        self.assertIn("API key", msg)
        self.assertNotIn("NOT the API key", msg)

    def watch_message(self):
        import contextlib, io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            la._contact_report()
        return buf.getvalue()


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class PushToStartSpendsItsOneShotWisely(unittest.TestCase):
    """A print gets ONE start per live session. These are the two ways it was thrown away.

    Found with a real print stuck at 0 %. Two Simulator instances (App Attest does not exist in the
    Simulator, so every claim they send is nil and every token they own is permanently unbound) had
    registered start tokens against the production service. The log read:

        [p2s] start print 2 (native) -> 200
        [p2s] start print 2 (native) -> 0
        [p2s] start print 2 (native) -> 0
        [p2s] start print 2 (native) -> 0

    Three of those four pushes failed outright, and every one of them still armed a pending claim and
    reported the start as sent.
    """

    def setUp(self):
        la._regs = {}
        la._p2s_tokens = ["good", "unbound"]
        la._p2s_devices = {"good": "phone", "unbound": "simulator"}
        la._p2s_clients = {"good": "native", "unbound": "native"}
        la._p2s_icons = {}
        la._p2s_pending = {}
        la._p2s_started = {}
        la._p2s_rearm = {}
        la._needs_claim = {}
        la._save = lambda: None
        self.pushed = []

    def run_start(self, codes):
        """Drive _remote_start with a stubbed APNs, returning per-token status codes."""
        async def fake_push(client, token, cs, printer_id, ams_id, la_client=la.EXPO):
            self.pushed.append(token)
            return codes.get(token, 200)

        real, la._push_start = la._push_start, fake_push
        try:
            return asyncio.run(la._remote_start(None, "2", {"stateLabel": "Printing"}, "print 2"))
        finally:
            la._push_start = real

    def test_a_token_known_to_be_unbound_is_not_pushed_to(self):
        # Trellis already recorded this at registration: the relay refuses it. Spending the one start
        # on it is the "offer what the backend will refuse" bug, with the print's only card as cost.
        la._needs_claim["unbound"] = "simulator"

        self.run_start({})

        self.assertEqual(self.pushed, ["good"], "the unbound token must be skipped, not attempted")

    def test_a_failed_push_does_not_arm_a_pending_claim(self):
        # A pending claim for a device that never received a card expires ~10 minutes later as
        # "the app will end that card as an orphan" — chasing a card that was never created.
        self.run_start({"good": 0, "unbound": 0})

        self.assertEqual(la._p2s_pending, {}, "nothing was delivered, so nothing is awaiting adoption")

    def test_a_failed_push_is_not_reported_as_sent(self):
        # The caller marks the print started on this return value. Reporting a total failure as sent
        # burns the one start for the whole print, and the lock screen stays empty to the end.
        self.assertFalse(self.run_start({"good": 0, "unbound": 0}))

    def test_a_delivered_push_still_arms_and_reports(self):
        self.assertTrue(self.run_start({}))
        self.assertIn(la._pending_id("2", "phone"), la._p2s_pending)

    def test_one_failure_does_not_taint_a_delivered_sibling(self):
        # The real shape: the phone's push lands, the simulator's does not.
        self.assertTrue(self.run_start({"unbound": 0}))

        self.assertIn(la._pending_id("2", "phone"), la._p2s_pending)
        self.assertNotIn(
            la._pending_id("2", "simulator"), la._p2s_pending,
            "the device that received nothing must not be waited on",
        )

    def test_a_dead_token_is_still_dropped(self):
        self.run_start({"unbound": 410})
        self.assertNotIn("unbound", la._p2s_tokens)


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class TestAggregateDryState(unittest.TestCase):
    """Two or more drying units collapse into one card. Must agree with the app's
    `aggregateDryContent` field for field — Trellis pushes this JSON straight into the widget."""

    @staticmethod
    def _unit(uid, mins, temp=50, target=65, hum=24, fil="PETG", ht=False):
        return {"id": uid, "dry_time": mins, "temp": temp, "dry_target_temp": target,
                "humidity": hum, "dry_filament": fil, "is_ams_ht": ht}

    def test_one_unit_keeps_its_own_card(self):
        # An aggregate of one is a worse version of the card it replaces.
        st = {"ams": [self._unit(0, 120)]}
        self.assertIsNone(la.aggregate_dry_state(st))

    def test_two_units_aggregate(self):
        st = {"ams": [self._unit(0, 120), self._unit(1, 45)]}
        got = la.aggregate_dry_state(st)
        self.assertIsNotNone(got)
        self.assertEqual(len(got["dryUnits"]), 2)
        self.assertTrue(got["dry"])

    def test_rows_sort_soonest_first(self):
        st = {"ams": [self._unit(0, 300), self._unit(1, 45), self._unit(2, 120)]}
        rows = la.aggregate_dry_state(st)["dryUnits"]
        self.assertEqual([r["minutesLeft"] for r in rows], [45, 120, 300])

    def test_headline_is_the_longest_not_the_soonest(self):
        # The header answers "when is the whole batch done"; the rows answer "which is next".
        st = {"ams": [self._unit(0, 300), self._unit(1, 45)]}
        got = la.aggregate_dry_state(st)
        eta_minutes = (got["etaEpochMs"] / 1000 - time.time()) / 60
        self.assertAlmostEqual(eta_minutes, 300, delta=1)

    def test_idle_units_are_not_rows(self):
        st = {"ams": [self._unit(0, 120), self._unit(1, 0), self._unit(2, 45)]}
        rows = la.aggregate_dry_state(st)["dryUnits"]
        self.assertEqual({r["amsId"] for r in rows}, {0, 2})

    def test_the_ht_is_not_ams_3(self):
        st = {"ams": [self._unit(0, 120), self._unit(128, 45, ht=True)]}
        rows = la.aggregate_dry_state(st)["dryUnits"]
        self.assertEqual({r["label"] for r in rows}, {"AMS 1", "AMS HT"})

    def test_the_sentinel_cannot_be_a_real_unit_id(self):
        # Unit ids are indices, so a negative sentinel can never collide and let the aggregate
        # replace a unit's own card.
        self.assertLess(la.AGGREGATE_AMS_ID, 0)
