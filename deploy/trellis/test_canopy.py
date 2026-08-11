import unittest

from canopy import (
    CanopyClient,
    CanopyError,
    Credentials,
    Outcome,
    PushResult,
)


class FakeTransport:
    """Records calls and replays scripted responses, so none of this touches a
    network."""

    def __init__(self, responses=None, raises=None):
        self.calls = []
        self.responses = responses or {}
        self.raises = raises or set()

    async def __call__(self, method, path, body, bearer):
        self.calls.append({"method": method, "path": path, "body": body, "bearer": bearer})
        if path in self.raises:
            raise OSError("connection refused")
        return self.responses.get(path, (404, {"error": "no stub"}))


CREDS = Credentials("tenant-1", "secret-1", "recovery-1")


class TestEnrollment(unittest.IsolatedAsyncioTestCase):
    async def test_enroll_stores_credentials(self):
        t = FakeTransport({"/v1/enroll": (201, {
            "tenant_id": "T", "tenant_secret": "S", "recovery_code": "R",
        })})
        c = CanopyClient(t)
        creds = await c.enroll()

        self.assertEqual(creds.tenant_id, "T")
        self.assertEqual(creds.bearer, "T.S")
        self.assertEqual(c.credentials, creds)
        self.assertIsNone(t.calls[0]["bearer"], "enrollment cannot be authenticated")

    async def test_recovery_code_is_forwarded(self):
        t = FakeTransport({"/v1/enroll": (201, {
            "tenant_id": "T", "tenant_secret": "S2", "recovery_code": "R2",
        })})
        await CanopyClient(t).enroll(recovery_code="R1")
        self.assertEqual(t.calls[0]["body"], {"recovery_code": "R1"})

    async def test_enroll_failure_raises(self):
        t = FakeTransport({"/v1/enroll": (403, {"error": "invite_required"})})
        with self.assertRaises(CanopyError):
            await CanopyClient(t).enroll()

    async def test_authenticated_call_without_credentials_raises(self):
        with self.assertRaises(CanopyError):
            await CanopyClient(FakeTransport()).challenge("assertion")


class TestClaims(unittest.IsolatedAsyncioTestCase):
    async def test_successful_claim(self):
        t = FakeTransport({"/v1/claims": (204, None)})
        res = await CanopyClient(t, CREDS).claim({"token": "tok"})

        self.assertTrue(res.ok)
        self.assertTrue(res.definitive)
        self.assertEqual(t.calls[0]["bearer"], "tenant-1.secret-1")

    async def test_claim_body_is_passed_through_verbatim(self):
        # Every field is inside the device's signed client data, so altering one
        # would only invalidate the signature. Passing it through untouched is
        # what makes a compromised Trellis unable to bind somebody else's token.
        body = {"token": "tok", "client_data": "abc", "pairing_signature": "sig", "extra": 1}
        t = FakeTransport({"/v1/claims": (204, None)})
        await CanopyClient(t, CREDS).claim(body)
        self.assertEqual(t.calls[0]["body"], body)

    async def test_rejected_claim_is_definitive(self):
        t = FakeTransport({"/v1/claims": (403, {"error": "vouch_required"})})
        res = await CanopyClient(t, CREDS).claim({"token": "tok"})

        self.assertFalse(res.ok)
        self.assertEqual(res.reason, "vouch_required")
        self.assertTrue(res.definitive, "a refusal is a decision; the phone should see it")

    async def test_transport_failure_is_not_definitive(self):
        t = FakeTransport(raises={"/v1/claims"})
        res = await CanopyClient(t, CREDS).claim({"token": "tok"})

        self.assertFalse(res.ok)
        self.assertFalse(
            res.definitive,
            "a lost claim must fail to the phone so its retry converges, rather "
            "than the phone believing it succeeded and never trying again",
        )

    async def test_reattest_required_is_recognised(self):
        t = FakeTransport({"/v1/claims": (403, {"error": "reattest_required"})})
        res = await CanopyClient(t, CREDS).claim({"token": "tok"})
        self.assertTrue(res.needs_reattest)


class TestPush(unittest.IsolatedAsyncioTestCase):
    async def test_delivered_carries_the_apns_status(self):
        t = FakeTransport({"/v1/push": (200, {"apns_status": 200, "apns_reason": ""})})
        res = await CanopyClient(t, CREDS).push("tok", "liveactivity", 10, {"aps": {}})

        self.assertIs(res.outcome, Outcome.DELIVERED)
        self.assertEqual(res.apns_status, 200)
        self.assertFalse(res.token_is_dead)

    async def test_dead_token_is_recognised(self):
        for status, reason in ((410, "Unregistered"), (400, "BadDeviceToken")):
            with self.subTest(status=status):
                t = FakeTransport({"/v1/push": (200, {"apns_status": status, "apns_reason": reason})})
                res = await CanopyClient(t, CREDS).push("tok", "alert", 10, {})
                self.assertTrue(res.token_is_dead)

    async def test_other_apns_failures_do_not_kill_the_token(self):
        t = FakeTransport({"/v1/push": (200, {"apns_status": 400, "apns_reason": "PayloadTooLarge"})})
        res = await CanopyClient(t, CREDS).push("tok", "alert", 10, {})
        self.assertFalse(res.token_is_dead)

    async def test_canopy_side_failures_are_never_apns_statuses(self):
        # The load-bearing property. A malformed body, a rate limit or a dial
        # timeout must not reach the code that drops registrations.
        cases = {
            400: Outcome.REFUSED,
            429: Outcome.RATE_LIMITED,
            500: Outcome.TRANSPORT,
            502: Outcome.TRANSPORT,
        }
        for status, want in cases.items():
            with self.subTest(status=status):
                t = FakeTransport({"/v1/push": (status, {"error": "whatever"})})
                res = await CanopyClient(t, CREDS).push("tok", "alert", 10, {})
                self.assertIs(res.outcome, want)
                self.assertIsNone(res.apns_status)
                self.assertFalse(res.token_is_dead)

        t = FakeTransport(raises={"/v1/push"})
        res = await CanopyClient(t, CREDS).push("tok", "alert", 10, {})
        self.assertIs(res.outcome, Outcome.TRANSPORT)
        self.assertFalse(res.token_is_dead)

    async def test_not_bound_and_not_owner_stay_distinct(self):
        bound = FakeTransport({"/v1/push": (403, {"error": "not_bound"})})
        res = await CanopyClient(bound, CREDS).push("tok", "alert", 10, {})
        self.assertIs(res.outcome, Outcome.NOT_BOUND)

        owner = FakeTransport({"/v1/push": (403, {"error": "not_owner"})})
        res = await CanopyClient(owner, CREDS).push("tok", "alert", 10, {})
        self.assertIs(
            res.outcome,
            Outcome.NOT_OWNER,
            "conflating these would make routine housekeeping look like an "
            "attack, and would suspend every token at once after a restore",
        )

    async def test_retryable_outcomes(self):
        self.assertTrue(PushResult(outcome=Outcome.TRANSPORT).should_retry)
        self.assertTrue(PushResult(outcome=Outcome.RATE_LIMITED).should_retry)
        self.assertFalse(PushResult(outcome=Outcome.NOT_OWNER).should_retry)
        self.assertFalse(PushResult(outcome=Outcome.DELIVERED, apns_status=200).should_retry)

    async def test_collapse_id_is_optional(self):
        t = FakeTransport({"/v1/push": (200, {"apns_status": 200})})
        await CanopyClient(t, CREDS).push("tok", "alert", 10, {})
        self.assertNotIn("collapse_id", t.calls[0]["body"])

        await CanopyClient(t, CREDS).push("tok", "alert", 10, {}, collapse_id="c1")
        self.assertEqual(t.calls[1]["body"]["collapse_id"], "c1")


class TestBindingLifecycle(unittest.IsolatedAsyncioTestCase):
    async def test_release_and_delete(self):
        t = FakeTransport({"/v1/bindings/release": (204, None), "/v1/bindings": (204, None)})
        c = CanopyClient(t, CREDS)

        self.assertTrue(await c.release("tok"))
        self.assertTrue(await c.delete("tok"))
        self.assertEqual(t.calls[0]["method"], "POST")
        self.assertEqual(t.calls[1]["method"], "DELETE")

    async def test_release_by_a_non_owner_reports_failure(self):
        t = FakeTransport({"/v1/bindings/release": (403, {"error": "not_owner"})})
        self.assertFalse(await CanopyClient(t, CREDS).release("tok"))

    async def test_vouch_tolerates_rate_limiting(self):
        ok = FakeTransport({"/v1/vouch": (202, None)})
        await CanopyClient(ok, CREDS).vouch("tok", "production")

        limited = FakeTransport({"/v1/vouch": (429, {"error": "rate_limited"})})
        await CanopyClient(limited, CREDS).vouch("tok", "production")  # must not raise

        broken = FakeTransport({"/v1/vouch": (500, {"error": "internal"})})
        with self.assertRaises(CanopyError):
            await CanopyClient(broken, CREDS).vouch("tok", "production")

    async def test_health_is_unauthenticated_and_survives_failure(self):
        t = FakeTransport({"/v1/health": (200, {"ok": True})})
        self.assertTrue(await CanopyClient(t, CREDS).healthy())
        self.assertIsNone(t.calls[0]["bearer"])

        self.assertFalse(await CanopyClient(FakeTransport(raises={"/v1/health"}), CREDS).healthy())


if __name__ == "__main__":
    unittest.main()
