#!/usr/bin/env python3
"""Spike — is a MakerWorld collection reachable, and can it be reached WITHOUT a token?

Anonymously, `design-service/favorites/designs/{uid}` answers `200 {"hits":[],"total":0}` for every
user tried. That is ambiguous, and the ambiguity is the whole question:

  (a) those users genuinely have no public favourites, or
  (b) the endpoint returns an empty list to unauthenticated callers regardless — the same shape that
      makes `design-service/design/search` look broken.

Only an authenticated call can tell them apart, and the only token in this system lives on the
server, where Bambuddy already uses it to download 3MFs. So: read the owner's own favourites WITH the
stored token, then ask the SAME question anonymously and compare. If the authenticated call returns
items and the anonymous one returns none, anonymous access is dead and a collection feature needs
server-side plumbing.

Read-only. Prints counts, shapes and titles — never the token, never the uid in full.

    docker exec -i bambuddy python3 - < mw_collection_probe.py
"""
import json
import sqlite3
import urllib.error
import urllib.request

API = "https://api.bambulab.com/v1"
UA = "Bambuddy/1.0 (+https://github.com/maziggy/bambuddy)"


def token():
    c = sqlite3.connect("/app/data/bambuddy.db")
    row = c.execute("SELECT cloud_token FROM users WHERE cloud_token IS NOT NULL LIMIT 1").fetchone()
    c.close()
    return row[0] if row else None


def get(path, bearer=None):
    req = urllib.request.Request(f"{API}{path}", headers={"User-Agent": UA, "Accept": "application/json"})
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception as e:
        return -1, {"err": str(e)}


def summarise(label, status, body):
    if not isinstance(body, dict):
        print(f"  {label:34} http={status} (no json)")
        return None
    hits = body.get("hits")
    total = body.get("total")
    n = len(hits) if isinstance(hits, list) else ("null" if hits is None else "?")
    print(f"  {label:34} http={status} total={total} hits={n}")
    return hits if isinstance(hits, list) else []


t = token()
if not t:
    raise SystemExit("no cloud token stored — nothing to test")
print(f"token present (len {len(t)}), never printed\n")

# 1. Who are we? This is also the cheapest check that the token still works.
status, me = get("/design-service/my/profile", bearer=t)
uid = None
if isinstance(me, dict):
    uid = me.get("uid") or (me.get("user") or {}).get("uid")
    handle = me.get("handle") or (me.get("user") or {}).get("handle")
    print(f"my/profile: http={status} uid={'…' + str(uid)[-4:] if uid else None} handle={handle}")
    print(f"  keys: {sorted(me.keys())[:14]}")
print()

print("AUTHENTICATED (server-side token):")
auth_hits = []
for label, path in (
    ("my/favorites/listlite", "/design-service/my/favorites/listlite?offset=0&limit=5"),
    ("my/design/favoriteslist", "/design-service/my/design/favoriteslist?offset=0&limit=5"),
    ("my/design/like", "/design-service/my/design/like?offset=0&limit=5"),
):
    s, b = get(path, bearer=t)
    h = summarise(label, s, b)
    if h:
        auth_hits = auth_hits or h

if uid:
    s, b = get(f"/design-service/favorites/designs/{uid}?offset=0&limit=5", bearer=t)
    summarise("favorites/designs/<me> (auth)", s, b)

    print("\nANONYMOUS (no token) — the same question:")
    s, b = get(f"/design-service/favorites/designs/{uid}?offset=0&limit=5")
    anon = summarise("favorites/designs/<me> (anon)", s, b)

    print()
    if auth_hits and not anon:
        print("VERDICT: the list is real but INVISIBLE without a token. Anonymous access is dead;")
        print("         a collection feature needs the token, which lives on the server only.")
    elif auth_hits and anon:
        print("VERDICT: readable ANONYMOUSLY given a uid — a collection feature needs no token at all.")
    elif not auth_hits:
        print("VERDICT: the account genuinely has no favourites — inconclusive about visibility.")
        print("         Collect one model on MakerWorld and re-run to settle it.")

if auth_hits:
    print("\nsample titles (proves the shape):")
    for h in auth_hits[:5]:
        print(f"  - {str(h.get('title'))[:58]}  (id {h.get('id')})")
    print(f"\nhit keys: {sorted(auth_hits[0].keys())[:18]}")
