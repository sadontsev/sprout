"""Unit tests for the MakerWorld collection endpoints. Run: python3 -m unittest discover deploy/Trellis

Dependency-free apart from what the service itself imports (stdlib unittest, no pytest) — same rule
as test_clients.py / test_cooldown.py / test_p2s.py, so this runs anywhere the service runs,
including inside the container.

What these are really guarding: this API answers **200 with an empty list** to unauthenticated
callers on some paths — `favorites/designs/{uid}` returns `total: 0` with no token and `total: 30`
with one, for the same account. So "you have no collections" and "your sign-in expired" look
identical on the wire, and the failure mode is not an error the owner can see, it is a screen that
calmly shows nothing. Every test below exists to keep those two apart, all the way to the sentence
the owner reads.
"""
from __future__ import annotations

import sqlite3
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

try:
    import httpx  # noqa: F401 - makerworld imports it at module scope
except ImportError:  # the service's own deps are absent; see scripts-test.sh
    HAVE_DEPS = False
else:
    HAVE_DEPS = True
    # Outside the guard on purpose: with httpx present, a failure to import
    # makerworld is a real bug and must fail rather than skip.
    import makerworld as mw


# MARK: - A stand-in for httpx, so no test touches the network


class FakeResponse:
    def __init__(self, status_code: int, payload=None, body: bytes | None = None):
        self.status_code = status_code
        self._payload = payload
        self._body = body

    def json(self):
        if self._body is not None:
            raise ValueError("not json")
        return self._payload


class FakeClient:
    """Matches only the surface makerworld.py uses: `async with`, then `.get(url, headers, timeout)`."""

    def __init__(self, handler):
        self._handler = handler

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return False

    async def get(self, url, headers=None, timeout=None):
        return self._handler(url, headers or {})


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class MakerWorldTestCase(unittest.IsolatedAsyncioTestCase):

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._real_client = mw.httpx.AsyncClient
        self.addCleanup(lambda: setattr(mw.httpx, "AsyncClient", self._real_client))
        self.requests: list[tuple[str, dict]] = []

    # Helpers

    def db(self, token: str | None = "tok-abc", with_table: bool = True) -> str:
        path = Path(self._tmp.name) / "bambuddy.db"
        # Idempotent: a subTest loop calls this more than once against the same temp directory.
        conn = sqlite3.connect(path)
        if with_table:
            conn.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, cloud_token TEXT)")
            conn.execute("INSERT OR REPLACE INTO users (id, cloud_token) VALUES (1, ?)", (token,))
            conn.commit()
        conn.close()
        return str(path)

    def serve(self, responder):
        """Install a fake transport. `responder(url, headers) -> FakeResponse`, or raises."""
        def factory(*_a, **_kw):
            def handler(url, headers):
                self.requests.append((str(url), headers))
                return responder(str(url), headers)
            return FakeClient(handler)
        mw.httpx.AsyncClient = factory

    def json_once(self, payload, status=200):
        self.serve(lambda url, headers: FakeResponse(status, payload))


# MARK: - Reading the token


class ReadToken(MakerWorldTestCase):

    def test_reads_the_stored_token(self):
        self.assertEqual(mw.read_token(self.db()), "tok-abc")

    def test_a_missing_database_names_the_mount_rather_than_looking_empty(self):
        with self.assertRaises(mw.CollectionsUnavailable) as cm:
            mw.read_token(str(Path(self._tmp.name) / "nope.db"))
        self.assertEqual(cm.exception.status, 503)
        self.assertIn("/bambuddy", cm.exception.message)

    def test_no_token_says_sign_in_rather_than_returning_nothing(self):
        """The failure that would otherwise render as 'you have no collections'."""
        with self.assertRaises(mw.CollectionsUnavailable) as cm:
            mw.read_token(self.db(token=None))
        self.assertIn("Cloud Profiles", cm.exception.message)

    def test_an_empty_string_token_counts_as_no_token(self):
        with self.assertRaises(mw.CollectionsUnavailable):
            mw.read_token(self.db(token=""))

    def test_a_database_without_the_users_table_is_an_error_not_an_empty_result(self):
        with self.assertRaises(mw.CollectionsUnavailable):
            mw.read_token(self.db(with_table=False))

    def test_the_database_is_opened_read_only(self):
        """This service must never be able to write another app's database."""
        path = self.db()
        mw.read_token(path)
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        with self.assertRaises(sqlite3.OperationalError):
            conn.execute("INSERT INTO users (id, cloud_token) VALUES (2, 'x')")
        conn.close()


# MARK: - Shaping a collection


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class NormaliseCollection(unittest.TestCase):

    def test_a_collection_carries_its_count_so_empty_can_be_shown_as_empty(self):
        self.assertEqual(
            mw.normalise_collection({"id": 7, "title": "Lego", "designCnt": 3, "isDefault": False}),
            {"id": 7, "title": "Lego", "count": 3, "cover": None, "is_default": False})

    def test_a_missing_count_is_zero_not_absent(self):
        self.assertEqual(mw.normalise_collection({"id": 1, "title": "x"})["count"], 0)

    def test_an_untitled_collection_still_reads_as_something(self):
        self.assertEqual(mw.normalise_collection({"id": 1})["title"], "Untitled collection")

    def test_the_design_cover_is_used_when_the_folder_has_none(self):
        self.assertEqual(mw.normalise_collection({"id": 1, "designCover": "d.jpg"})["cover"], "d.jpg")
        self.assertEqual(
            mw.normalise_collection({"id": 1, "cover": "c.jpg", "designCover": "d.jpg"})["cover"],
            "c.jpg")

    def test_a_cover_that_arrives_as_a_list_is_flattened_to_one_url(self):
        """The live shape, and the one an invented fixture missed: MakerWorld builds a folder
        thumbnail as a COLLAGE, so `cover` is an array. Passing it through reached the app as a
        decode failure reading 'the data couldn't be read because it isn't in the correct format'."""
        self.assertEqual(
            mw.normalise_collection({"id": 1, "cover": ["a.png", "b.jpg"]})["cover"], "a.png")

    def test_an_empty_or_junk_cover_list_falls_through_rather_than_yielding_nonsense(self):
        self.assertEqual(mw.normalise_collection({"id": 1, "cover": []})["cover"], None)
        self.assertEqual(
            mw.normalise_collection({"id": 1, "cover": [None, ""], "designCover": "d.jpg"})["cover"],
            "d.jpg")
        self.assertIsNone(mw.normalise_collection({"id": 1, "cover": [{"url": "x"}]})["cover"])


# MARK: - Listing


class ListCollections(MakerWorldTestCase):

    async def test_lists_collections_from_the_live_shape(self):
        """The exact payload measured against the account: folders with id/title/designCnt."""
        self.json_once({"total": 5, "hits": [
            {"id": 9100001, "title": "Default Collection", "designCnt": 19, "isDefault": True},
            {"id": 9100002, "title": "toys", "designCnt": 1},
            {"id": 9100003, "title": "Lego", "designCnt": 3},
        ]})
        got = await mw.list_collections(self.db())
        self.assertEqual([c["title"] for c in got], ["Default Collection", "toys", "Lego"])
        self.assertEqual(got[0]["count"], 19)
        self.assertTrue(got[0]["is_default"])

    async def test_the_bearer_is_sent_and_the_right_endpoint_is_called(self):
        self.json_once({"hits": []})
        await mw.list_collections(self.db())
        url, headers = self.requests[0]
        self.assertIn("/my/favorites/listlite", url)
        self.assertEqual(headers.get("Authorization"), "Bearer tok-abc")
        self.assertIn("bambu-trellis", headers.get("User-Agent", ""))

    async def test_a_collection_without_an_id_is_dropped_not_rendered(self):
        """The id is what opening it needs, so a row without one would be a folder that cannot open."""
        self.json_once({"hits": [{"title": "ghost"}, {"id": 2, "title": "ok"}]})
        got = await mw.list_collections(self.db())
        self.assertEqual([c["title"] for c in got], ["ok"])

    async def test_a_genuinely_empty_account_is_an_empty_list_not_an_error(self):
        self.json_once({"total": 0, "hits": []})
        self.assertEqual(await mw.list_collections(self.db()), [])

    async def test_a_null_hits_list_does_not_crash(self):
        self.json_once({"total": 0, "hits": None})
        self.assertEqual(await mw.list_collections(self.db()), [])


# MARK: - The distinction this module exists for


class FailuresStayDistinct(MakerWorldTestCase):

    async def test_a_rejected_token_is_reported_as_a_sign_in_problem_not_as_empty(self):
        """The whole point. An expired token must never render as 'you have no collections'."""
        for status in (401, 403):
            with self.subTest(status=status):
                self.json_once({}, status=status)
                with self.assertRaises(mw.CollectionsUnavailable) as cm:
                    await mw.list_collections(self.db())
                self.assertEqual(cm.exception.status, 502)
                self.assertIn("expired", cm.exception.message)
                self.assertIn("Cloud Profiles", cm.exception.message)

    async def test_rate_limiting_is_its_own_message(self):
        self.json_once({}, status=429)
        with self.assertRaises(mw.CollectionsUnavailable) as cm:
            await mw.list_collections(self.db())
        self.assertIn("rate-limit", cm.exception.message)

    async def test_makerworld_being_down_blames_makerworld_not_this_server(self):
        def boom(url, headers):
            raise OSError("no route to host")
        self.serve(boom)
        with self.assertRaises(mw.CollectionsUnavailable) as cm:
            await mw.list_collections(self.db())
        self.assertEqual(cm.exception.status, 502)
        self.assertIn("reach MakerWorld", cm.exception.message)

    async def test_an_unreadable_body_is_an_error_rather_than_an_empty_collection(self):
        self.serve(lambda url, headers: FakeResponse(200, body=b"<html>nope</html>"))
        with self.assertRaises(mw.CollectionsUnavailable):
            await mw.list_collections(self.db())

    async def test_this_servers_problems_and_makerworlds_get_different_statuses(self):
        """503 means 'fix this box'; 502 means 'MakerWorld refused'. Collapsing them sends the owner
        to the wrong machine."""
        with self.assertRaises(mw.CollectionsUnavailable) as cm:
            mw.read_token(str(Path(self._tmp.name) / "gone.db"))
        self.assertEqual(cm.exception.status, 503)
        self.json_once({}, status=500)
        with self.assertRaises(mw.CollectionsUnavailable) as cm:
            await mw.list_collections(self.db())
        self.assertEqual(cm.exception.status, 502)


# MARK: - Adding to / removing from a collection
#
# The upstream PUT REPLACES a design's whole collection membership — measured live: a design in
# "Default Collection", PUT with favoritesIds=[Collection], ends up in Collection and is silently
# gone from Default. Every test here exists because getting this wrong does not error, it quietly
# un-collects things the owner curated.


@unittest.skipUnless(HAVE_DEPS, "service dependencies not installed")
class MembershipArithmetic(unittest.TestCase):

    def test_adding_keeps_every_collection_it_was_already_in(self):
        self.assertEqual(mw.union_for_add({10, 20}, 30), [10, 20, 30])

    def test_adding_to_a_collection_it_is_already_in_is_a_no_op_set(self):
        self.assertEqual(mw.union_for_add({10, 20}, 20), [10, 20])

    def test_adding_to_nothing_yields_just_that_collection(self):
        self.assertEqual(mw.union_for_add(set(), 7), [7])

    def test_removing_leaves_the_others_untouched(self):
        self.assertEqual(mw.union_for_remove({10, 20, 30}, 20), [10, 30])

    def test_removing_the_last_one_is_an_empty_list_not_a_missing_field(self):
        """`favoritesIds: []` is how MakerWorld is told 'no collections' — measured."""
        self.assertEqual(mw.union_for_remove({10}, 10), [])

    def test_removing_something_it_was_not_in_changes_nothing(self):
        self.assertEqual(mw.union_for_remove({10, 20}, 99), [10, 20])

    def test_ids_are_ints_even_when_they_arrive_as_strings(self):
        self.assertEqual(mw.union_for_add({10}, "20"), [10, 20])
        self.assertEqual(mw.union_for_remove({10, 20}, "20"), [10])

    def test_the_result_is_sorted_so_a_diff_is_readable(self):
        self.assertEqual(mw.union_for_add({30, 10}, 20), [10, 20, 30])


class SetDesignCollections(MakerWorldTestCase):
    """`set_design_collections` reads the current membership, then writes the whole set back."""

    def account(self, membership: dict[int, list[int]], put_status: int = 200):
        """Serve a fake account and capture the PUT body.

        `membership` maps collection id -> the design ids it contains.
        """
        captured: dict = {}

        def get(url, headers):
            if "listlite" in url:
                return FakeResponse(200, {"hits": [{"id": c} for c in membership]})
            for cid, designs in membership.items():
                if f"/favorites/{cid}/designs" in url:
                    return FakeResponse(200, {"hits": [{"id": d} for d in designs]})
            return FakeResponse(200, {"hits": []})

        class Client(FakeClient):
            # Mirrors the REAL httpx surface the code uses. An over-permissive stub is how a
            # `send(req, timeout=…)` call — which httpx does not accept — passed 42 tests and then
            # failed against the live server.
            async def put(self, url, headers=None, json=None, timeout=None):
                captured["body"] = json
                captured["method"] = "PUT"
                captured["url"] = str(url)
                return FakeResponse(put_status, {"total": 1})

        mw.httpx.AsyncClient = lambda *a, **k: Client(get)
        return captured

    async def test_adding_sends_the_existing_memberships_plus_the_new_one(self):
        """The bug this whole design exists to prevent: design 555 is in collection 10, and adding
        it to 20 must send BOTH — sending just [20] removes it from 10, silently."""
        put = self.account({10: [555], 20: []})
        got = await mw.set_design_collections(555, 20, add=True, db_path=self.db())
        self.assertEqual(put["method"], "PUT")
        self.assertEqual(put["body"], {"designId": 555, "favoritesIds": [10, 20]})
        self.assertEqual(got["collections"], [10, 20])
        self.assertTrue(got["changed"])

    async def test_removing_sends_everything_except_that_collection(self):
        put = self.account({10: [555], 20: [555], 30: []})
        got = await mw.set_design_collections(555, 10, add=False, db_path=self.db())
        self.assertEqual(put["body"], {"designId": 555, "favoritesIds": [20]})
        self.assertEqual(got["collections"], [20])

    async def test_removing_the_only_one_sends_an_empty_list(self):
        put = self.account({10: [555]})
        await mw.set_design_collections(555, 10, add=False, db_path=self.db())
        self.assertEqual(put["body"], {"designId": 555, "favoritesIds": []})

    async def test_a_no_op_add_writes_nothing_at_all(self):
        """Already there — mutating the owner's account anyway would be gratuitous."""
        put = self.account({10: [555]})
        got = await mw.set_design_collections(555, 10, add=True, db_path=self.db())
        self.assertFalse(got["changed"])
        self.assertEqual(put, {}, "no PUT should have been sent")

    async def test_a_failed_membership_read_aborts_instead_of_writing_a_short_list(self):
        """The dangerous failure. A partial read would PUT a set that silently un-collects."""
        def get(url, headers):
            if "listlite" in url:
                return FakeResponse(200, {"hits": [{"id": 10}, {"id": 20}]})
            return FakeResponse(403, {})
        mw.httpx.AsyncClient = lambda *a, **k: FakeClient(get)
        with self.assertRaises(mw.CollectionsUnavailable):
            await mw.set_design_collections(555, 20, add=True, db_path=self.db())

    async def test_a_refused_write_is_reported_rather_than_reported_as_success(self):
        self.account({10: [555]}, put_status=403)
        with self.assertRaises(mw.CollectionsUnavailable):
            await mw.set_design_collections(555, 20, add=True, db_path=self.db())

    async def test_membership_is_read_across_pages(self):
        """A truncated read would drop designs from collections nobody is editing."""
        big = list(range(1, 51))          # exactly one full page
        calls = {"n": 0}

        def get(url, headers):
            if "listlite" in url:
                return FakeResponse(200, {"hits": [{"id": 10}]})
            calls["n"] += 1
            return FakeResponse(200, {"hits": [{"id": d} for d in big]} if calls["n"] == 1
                                else {"hits": [{"id": 999}]})
        mw.httpx.AsyncClient = lambda *a, **k: FakeClient(get)
        self.assertEqual(await mw.design_collection_ids(999, self.db()), [10],
                         "the design is on page 2; a single-page read would have missed it")


# MARK: - Designs inside a collection


class CollectionDesigns(MakerWorldTestCase):

    HIT = {"id": 2320073, "title": "AMS 2 Pro Lattice Dry Pods", "cover": "c.jpg",
           "downloadCount": 12, "designCreator": {"name": "someone"}, "license": "BY"}

    async def test_designs_are_passed_through_unchanged_so_the_app_reuses_its_search_tile(self):
        self.json_once({"total": 19, "hits": [self.HIT]})
        got = await mw.collection_designs(9100001, db_path=self.db())
        self.assertEqual(got["total"], 19)
        self.assertEqual(got["hits"], [self.HIT],
                         "the app decodes MakerWorld's own hit shape; do not reshape it")
        self.assertIn("/favorites/9100001/designs", self.requests[0][0])

    async def test_paging_is_forwarded(self):
        self.json_once({"total": 40, "hits": []})
        await mw.collection_designs(5, offset=20, limit=10, db_path=self.db())
        url = self.requests[0][0]
        self.assertIn("offset=20", url)
        self.assertIn("limit=10", url)

    async def test_the_collection_id_is_coerced_to_an_int(self):
        """It arrives from a URL path; a string would be interpolated straight into the request."""
        self.json_once({"hits": []})
        await mw.collection_designs("42", db_path=self.db())
        self.assertIn("/favorites/42/designs", self.requests[0][0])

    async def test_a_non_numeric_id_is_refused_before_it_reaches_the_network(self):
        self.json_once({"hits": []})
        with self.assertRaises(ValueError):
            await mw.collection_designs("../../admin", db_path=self.db())
        self.assertEqual(self.requests, [])

    async def test_an_empty_collection_returns_no_hits_rather_than_failing(self):
        self.json_once({"total": 0, "hits": []})
        got = await mw.collection_designs(1, db_path=self.db())
        self.assertEqual(got, {"total": 0, "hits": []})


if __name__ == "__main__":
    unittest.main()
