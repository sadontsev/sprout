#!/usr/bin/env python3
"""Spike 2 — the designs INSIDE a collection, and whether any of it is public.

Spike 1 established that `design-service/my/favorites/listlite` returns the owner's collections as
FOLDERS (id, title, designCnt). Two questions remain, and the second decides the architecture:

  1. Which endpoint lists the designs inside one collection?
  2. Is a collection readable ANONYMOUSLY given a user id? If yes, the app can read it the way it
     reads search — no token anywhere near the phone. If no, this needs server-side plumbing that
     Bambuddy does not currently have.

Read-only; prints shapes and titles, never the token.

    docker exec -i bambuddy python3 - < mw_collection_probe2.py
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
    except Exception:
        return -1, None


def line(label, status, body):
    n = "-"
    if isinstance(body, dict):
        h = body.get("hits")
        n = f"total={body.get('total')} hits={len(h) if isinstance(h, list) else h}"
    print(f"  {label:46} http={status} {n}")
    return body if isinstance(body, dict) else None


t = token()
s, cols = get("/design-service/my/favorites/listlite?offset=0&limit=10", bearer=t)
collections = (cols or {}).get("hits") or []
print(f"collections: {[(c.get('id'), c.get('title'), c.get('designCnt')) for c in collections]}\n")

# Pick a collection that actually has designs in it — an empty one proves nothing.
target = next((c for c in collections if (c.get("designCnt") or 0) > 0), None)
if not target:
    raise SystemExit("every collection is empty; add a model to one and re-run")
cid = target["id"]
print(f"probing collection {cid} ({target.get('title')}, {target.get('designCnt')} designs)\n")

print("1. WHICH ENDPOINT LISTS ITS DESIGNS (authenticated):")
found = None
for path in (
    f"/design-service/favorites/{cid}/designs?offset=0&limit=5",
    f"/design-service/my/favorites/{cid}?offset=0&limit=5",
    f"/design-service/my/favorites/{cid}/designs?offset=0&limit=5",
    f"/design-service/favorites/designs?favoriteId={cid}&offset=0&limit=5",
    f"/design-service/favorites/design/{cid}?offset=0&limit=5",
    f"/design-service/my/design/favoritelist?favoriteId={cid}&offset=0&limit=5",
):
    st, body = get(path, bearer=t)
    got = line(path.split("?")[0], st, body)
    if got and isinstance(got.get("hits"), list) and got["hits"]:
        found = (path, got)

# The owner's uid — needed to ask the public question at all.
uid = None
for path in ("/design-service/my/profile", "/user-service/my/profile",
             "/design-user-service/my/profile", "/user-service/my/preference"):
    st, body = get(path, bearer=t)
    if st == 200 and isinstance(body, dict):
        uid = body.get("uid") or (body.get("user") or {}).get("uid")
        print(f"\n  {path} -> uid found: {bool(uid)}  keys={sorted(body.keys())[:12]}")
        if uid:
            break

if found:
    path, body = found
    print(f"\n  WORKS: {path.split('?')[0]}")
    for h in body["hits"][:5]:
        print(f"    - {str(h.get('title'))[:52]}  (id {h.get('id')})")
    print(f"    hit keys: {sorted(body['hits'][0].keys())[:16]}")

    print("\n2. THE SAME CALL, ANONYMOUSLY:")
    st, anon = get(path)
    a = line("anonymous", st, anon)
    anon_hits = (a or {}).get("hits") or []
    print()
    if anon_hits:
        print("VERDICT: PUBLIC. The app can read collections with no token at all.")
    else:
        print("VERDICT: TOKEN-ONLY. The list exists but is invisible without a bearer, so a")
        print("         collection feature must be served by the machine that holds the token.")
else:
    print("\n  none of the tried paths listed designs — the endpoint name is still unknown")

if uid:
    print(f"\n3. PUBLIC FAVOURITES BY UID (anonymous), uid …{str(uid)[-4:]}:")
    st, body = get(f"/design-service/favorites/designs/{uid}?offset=0&limit=5")
    line("favorites/designs/<uid> anon", st, body)
    st, body = get(f"/design-service/favorites/designs/{uid}?offset=0&limit=5", bearer=t)
    line("favorites/designs/<uid> auth", st, body)
