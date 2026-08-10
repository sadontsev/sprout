"""The owner's MakerWorld collections, read with the Bambu Cloud token Bambuddy already holds.

Why this lives here rather than in the app: every collection endpoint is Bearer-gated, and that
bearer is the whole Bambu account. A phone is lost or stolen far more often than a home server, and
Bambu Lab has been actively hostile to third-party cloud access — a bearer used from a mobile IP by a
non-Bambu client is the pattern most likely to get an account actioned. So the token never leaves the
machine it is already on, and the app asks this service, which it already trusts, with the API key it
already sends.

Bambuddy exposes no collection endpoint and `POST /cloud/token` only *accepts* a token, so the only
way to reach the token is to read Bambuddy's own database. It is mounted read-only and re-read per
request rather than cached, so a token Bambuddy refreshes is picked up immediately and one it drops
stops working immediately.

**The endpoint choice is deliberate.** This API answers `200` with an empty list to unauthenticated
callers on some paths — `favorites/designs/{uid}` returns `total: 0` with no token and `total: 30`
with one, for the same user. Passing that through would show an empty Collection and imply the owner
has none, which is a silent lie. The two endpoints used here both fail LOUDLY without a bearer
(`listlite` → 401, `{id}/designs` → 403), so "empty" from them means empty.
"""
from __future__ import annotations

import os
import sqlite3
from typing import Any

import httpx

API = "https://api.bambulab.com/v1/design-service"

# Honest, identifying, and never pretending to be Bambu Studio or Handy.
USER_AGENT = "bambu-la-push/1.0 (+https://github.com/mvks5/bambu-app; personal 3D printer client)"

# Bambuddy's SQLite, mounted read-only. Overridable so tests never touch a real one.
DB_PATH = os.environ.get("BAMBUDDY_DB", "/bambuddy/bambuddy.db")

TIMEOUT = 20.0


class CollectionsUnavailable(Exception):
    """The collections cannot be read, with a reason meant for a person.

    `status` is what the HTTP layer should answer: `503` when this server cannot act (no database, no
    token), `502` when MakerWorld itself refused. They are different problems with different fixes and
    must not be collapsed — the whole point of this module is that a wrong-but-plausible answer is
    worse than an error.
    """

    def __init__(self, message: str, status: int = 503) -> None:
        super().__init__(message)
        self.message = message
        self.status = status


def read_token(db_path: str | None = None) -> str:
    """The stored Bambu Cloud bearer. Raises `CollectionsUnavailable` rather than returning None, so
    no caller can mistake "no token" for "no collections"."""
    path = db_path or DB_PATH
    if not os.path.exists(path):
        raise CollectionsUnavailable(
            "This server can't see Bambuddy's database, so it can't read your Bambu Cloud sign-in. "
            "Mount it read-only at /bambuddy.")
    try:
        # Read-only URI: this process must never be able to write Bambuddy's database, and an
        # accidental write here would be a corruption bug in someone else's app.
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            row = conn.execute(
                "SELECT cloud_token FROM users WHERE cloud_token IS NOT NULL AND cloud_token != '' "
                "ORDER BY id LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
    except sqlite3.Error as exc:
        raise CollectionsUnavailable(f"Couldn't read Bambuddy's database: {exc}") from exc

    if not row or not row[0]:
        raise CollectionsUnavailable(
            "Your Bambuddy server isn't signed in to Bambu Cloud. Sign in under Bambuddy → Profiles "
            "→ Cloud Profiles, then try again.")
    return row[0]


async def _get(client: httpx.AsyncClient, path: str, token: str) -> dict[str, Any]:
    try:
        r = await client.get(
            f"{API}{path}",
            headers={"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT,
                     "Accept": "application/json"},
            timeout=TIMEOUT,
        )
    except Exception as exc:
        raise CollectionsUnavailable(f"Couldn't reach MakerWorld: {exc}", status=502) from exc

    if r.status_code in (401, 403):
        # Loud by design — see the module docstring. A refusal here is a real answer.
        raise CollectionsUnavailable(
            "MakerWorld rejected your server's Bambu Cloud sign-in. It may have expired — sign in "
            "again under Bambuddy → Profiles → Cloud Profiles.", status=502)
    if r.status_code == 429:
        raise CollectionsUnavailable("MakerWorld is rate-limiting this server. Try again shortly.",
                                     status=502)
    if r.status_code >= 400:
        raise CollectionsUnavailable(f"MakerWorld returned {r.status_code}.", status=502)
    try:
        body = r.json()
    except Exception as exc:
        raise CollectionsUnavailable("MakerWorld returned something unreadable.", status=502) from exc
    return body if isinstance(body, dict) else {}


def _first_url(*candidates: Any) -> str | None:
    """The first usable image URL out of fields that are sometimes a string and sometimes a list.

    Measured: a collection's `cover` comes back as an **array** of design covers — MakerWorld builds
    the folder thumbnail as a collage — while `designCover` is a plain string. Passing the array
    through failed to decode in the app with Foundation's useless "the data couldn't be read", so the
    shape is flattened here, once, rather than in every client.
    """
    for value in candidates:
        if isinstance(value, str) and value:
            return value
        if isinstance(value, list):
            for item in value:
                if isinstance(item, str) and item:
                    return item
    return None


def normalise_collection(hit: dict[str, Any]) -> dict[str, Any]:
    """One collection folder, reduced to what a picker needs.

    `designCnt` is carried through as `count` because it is the only honest way to show an empty
    collection as empty — fetching every collection's contents just to count them would be several
    round-trips to say nothing.
    """
    return {
        "id": hit.get("id"),
        "title": hit.get("title") or "Untitled collection",
        "count": hit.get("designCnt") or 0,
        # Two sources appear: the folder's own cover (a LIST) and a fallback from a design inside it
        # (a string). Either beats a grey box; neither is guaranteed.
        "cover": _first_url(hit.get("cover"), hit.get("designCover")),
        "is_default": bool(hit.get("isDefault")),
    }


async def list_collections(db_path: str | None = None) -> list[dict[str, Any]]:
    """The owner's collections, newest MakerWorld ordering preserved.

    Collections with no id are dropped: the id is what the contents call needs, so a row without one
    would render as a folder that cannot be opened.
    """
    token = read_token(db_path)
    async with httpx.AsyncClient() as client:
        body = await _get(client, "/my/favorites/listlite?offset=0&limit=50", token)
    hits = body.get("hits")
    if not isinstance(hits, list):
        return []
    return [normalise_collection(h) for h in hits if isinstance(h, dict) and h.get("id")]


def union_for_add(current: set[int], collection_id: int) -> list[int]:
    """The `favoritesIds` to send when ADDING a design to one collection.

    `PUT my/design/favoriteslist` **replaces** the design's entire collection membership — measured:
    a design in "Default Collection", PUT with `favoritesIds: [Collection]`, ends up in Collection
    and is silently gone from Default. So an add has to send everything it was already in, plus the
    new one, or it quietly un-collects.
    """
    return sorted(current | {int(collection_id)})


def union_for_remove(current: set[int], collection_id: int) -> list[int]:
    """The `favoritesIds` to send when REMOVING a design from one collection: everything else."""
    return sorted(current - {int(collection_id)})


async def _designs_in(client: httpx.AsyncClient, collection_id: int, token: str) -> set[int]:
    """Every design id in a collection, paged out.

    Paging matters here in a way it does not for display: this set becomes the membership we write
    back, and a truncated read would drop designs from collections that are not even being edited.
    """
    ids: set[int] = set()
    offset, page = 0, 50
    while True:
        body = await _get(client, f"/favorites/{int(collection_id)}/designs?offset={offset}&limit={page}",
                          token)
        hits = body.get("hits")
        hits = hits if isinstance(hits, list) else []
        ids |= {h.get("id") for h in hits if isinstance(h, dict) and h.get("id")}
        if len(hits) < page:
            return ids
        offset += page


async def design_collection_ids(design_id: int, db_path: str | None = None) -> list[int]:
    """Which of the owner's collections currently contain this design.

    There is no endpoint that answers this directly — `hasCollect` on a design is a bare boolean —
    so it is derived by scanning every collection. That is several requests, which is why it happens
    once per user action and is never used for rendering a list.
    """
    token = read_token(db_path)
    async with httpx.AsyncClient() as client:
        cols = await _get(client, "/my/favorites/listlite?offset=0&limit=50", token)
        hits = cols.get("hits")
        ids = [h["id"] for h in (hits if isinstance(hits, list) else []) if isinstance(h, dict) and h.get("id")]
        found = []
        for cid in ids:
            if int(design_id) in await _designs_in(client, cid, token):
                found.append(cid)
    return found


async def set_design_collections(design_id: int, collection_id: int, *, add: bool,
                                 db_path: str | None = None) -> dict[str, Any]:
    """Add or remove ONE collection, preserving every other membership.

    The read half is not optional and its failure is not survivable: if the membership scan raises,
    this raises too rather than writing a set built from partial knowledge. A `PUT` with a short list
    is indistinguishable, to MakerWorld, from the owner deliberately un-collecting a design.
    """
    token = read_token(db_path)
    current = set(await design_collection_ids(design_id, db_path))
    wanted = (union_for_add if add else union_for_remove)(current, collection_id)
    if sorted(current) == wanted:
        # Nothing to do. Writing anyway would be a needless mutation of the owner's account.
        return {"design_id": int(design_id), "collections": wanted, "changed": False}

    async with httpx.AsyncClient() as client:
        try:
            # `client.put`, matching `_get`'s use of `client.get`. NOT `client.send(req, timeout=…)`:
            # send() takes no timeout kwarg, and a stub that accepted one let this ship broken.
            r = await client.put(
                f"{API}/my/design/favoriteslist",
                headers={"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT,
                         "Content-Type": "application/json", "Accept": "application/json"},
                json={"designId": int(design_id), "favoritesIds": wanted},
                timeout=TIMEOUT,
            )
        except Exception as exc:
            raise CollectionsUnavailable(f"Couldn't reach MakerWorld: {exc}", status=502) from exc
    if r.status_code in (401, 403):
        raise CollectionsUnavailable(
            "MakerWorld rejected your server's Bambu Cloud sign-in. It may have expired — sign in "
            "again under Bambuddy → Profiles → Cloud Profiles.", status=502)
    if r.status_code >= 400:
        raise CollectionsUnavailable(f"MakerWorld returned {r.status_code}.", status=502)
    return {"design_id": int(design_id), "collections": wanted, "changed": True}


async def collection_designs(collection_id: int, offset: int = 0, limit: int = 20,
                             db_path: str | None = None) -> dict[str, Any]:
    """The designs inside one collection.

    The hits are passed through **unchanged**. They are the same shape the public search endpoint
    returns, so the app decodes and renders them with the type it already has — one tile, one detail
    flow, no second code path to drift.
    """
    token = read_token(db_path)
    async with httpx.AsyncClient() as client:
        body = await _get(
            client,
            f"/favorites/{int(collection_id)}/designs?offset={int(offset)}&limit={int(limit)}",
            token,
        )
    hits = body.get("hits")
    return {"total": body.get("total"), "hits": hits if isinstance(hits, list) else []}
