#!/usr/bin/env python3
"""Spike — does `PUT my/design/favoriteslist` ADD to a collection, or REPLACE the set?

The endpoint takes `favoritesIds` as an ARRAY, and PUT usually means "make it so". If it replaces,
then sending one collection id removes the design from every other collection it was in — and a
naive "Add to collection" button would silently un-collect things. That is the whole question.

**This spike WRITES to a real MakerWorld account.** It is built to be reversible:

  1. snapshot every collection's design ids,
  2. pick a design that is currently in NO collection, so any mistake is contained to it,
  3. add it to collection A, then PUT again naming only collection B,
  4. read back: in B only -> REPLACE. In A and B -> ADD.
  5. restore — remove it from everything — and diff against the snapshot.

If step 5's diff is not empty, it says so loudly rather than exiting quietly.

    docker exec -i bambuddy python3 - < mw_add_to_collection_probe.py
"""
import json
import sqlite3
import sys
import urllib.error
import urllib.request

API = "https://api.bambulab.com/v1/design-service"
UA = "Bambuddy/1.0 (+https://github.com/maziggy/bambuddy)"


def token():
    c = sqlite3.connect("/app/data/bambuddy.db")
    row = c.execute("SELECT cloud_token FROM users WHERE cloud_token IS NOT NULL LIMIT 1").fetchone()
    c.close()
    return row[0] if row else None


T = token()
if not T:
    sys.exit("no cloud token stored")


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method,
                                 headers={"Authorization": f"Bearer {T}", "User-Agent": UA,
                                          "Content-Type": "application/json",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else {}
        except Exception:
            return e.code, {"raw": raw[:120].decode("utf-8", "replace")}
    except Exception as e:
        return -1, {"err": str(e)[:80]}


def collections():
    _, b = call("GET", "/my/favorites/listlite?offset=0&limit=50")
    return [h for h in (b.get("hits") or []) if h.get("id")]


def design_ids(cid):
    """Every design id in one collection, paged out so a big collection is not truncated."""
    ids, offset = [], 0
    while True:
        s, b = call("GET", f"/favorites/{cid}/designs?offset={offset}&limit=50")
        hits = (b or {}).get("hits") or []
        ids += [h.get("id") for h in hits if h.get("id")]
        if len(hits) < 50:
            return ids
        offset += 50


def snapshot(cols):
    return {c["id"]: set(design_ids(c["id"])) for c in cols}


def show(label, snap, cols):
    names = {c["id"]: c.get("title") for c in cols}
    print(f"  {label}: " + ", ".join(f"{names[k]}={len(v)}" for k, v in sorted(snap.items())))


cols = collections()
if len(cols) < 2:
    sys.exit("need at least two collections to tell ADD from REPLACE")
print(f"collections: {[(c['id'], c.get('title'), c.get('designCnt')) for c in cols]}\n")

print("1. snapshot")
BEFORE = snapshot(cols)
show("before", BEFORE, cols)
collected = set().union(*BEFORE.values()) if BEFORE else set()

# 2. a design in NO collection, taken from a public search so nothing here depends on the account.
victim = None
sreq = urllib.request.Request(
    "https://api.bambulab.com/v1/search-service/search/design?keyword=benchy&offset=0&limit=20",
    headers={"User-Agent": UA})
with urllib.request.urlopen(sreq, timeout=25) as r:
    for h in (json.loads(r.read()).get("hits") or []):
        if h.get("id") and h["id"] not in collected:
            victim = h["id"]
            break
if not victim:
    sys.exit("could not find an uncollected design to test with")

A, B = cols[0]["id"], cols[1]["id"]
print(f"\n2. test design {victim} (in no collection). A={cols[0].get('title')} B={cols[1].get('title')}")

print("\n3. PUT favoritesIds=[A]")
print("   ->", call("PUT", "/my/design/favoriteslist",
                    {"designId": victim, "favoritesIds": [A]}))
after_a = snapshot(cols)
show("now", after_a, cols)
in_a = victim in after_a.get(A, set())
print(f"   in A? {in_a}")

print("\n4. PUT favoritesIds=[B]  <- the decisive call")
print("   ->", call("PUT", "/my/design/favoriteslist",
                    {"designId": victim, "favoritesIds": [B]}))
after_b = snapshot(cols)
show("now", after_b, cols)
still_a = victim in after_b.get(A, set())
in_b = victim in after_b.get(B, set())
print(f"   still in A? {still_a}   in B? {in_b}")

print("\nVERDICT:", end=" ")
if in_b and not still_a:
    print("REPLACE — favoritesIds is the COMPLETE set of collections for this design.")
    print("          An 'add' must therefore send existing ids + the new one, or it un-collects.")
elif in_b and still_a:
    print("ADD — each PUT appends; other collections are untouched.")
else:
    print("UNCLEAR — read the numbers above before writing any code.")

print("\n5. restore")
for method, body in (("PUT", {"designId": victim, "favoritesIds": []}),
                     ("DELETE", {"designId": victim, "favoritesIds": [A, B]})):
    s, b = call(method, "/my/design/favoriteslist", body)
    print(f"   {method} {body.get('favoritesIds')} -> {s} {b}")
    if victim not in set().union(*snapshot(cols).values()):
        break

AFTER = snapshot(cols)
show("after", AFTER, cols)
drift = {k: (BEFORE[k] ^ AFTER.get(k, set())) for k in BEFORE if BEFORE[k] != AFTER.get(k, set())}
print("\nRESTORED CLEANLY" if not drift else f"\n*** DRIFT — FIX BY HAND: {drift} ***")
