#!/usr/bin/env python3
"""Spike — is there a WRITE endpoint for adding a design to a collection, or creating one?

Discovery without mutation. Every request below is sent with an EMPTY body, so a route that exists
answers 400/422 (validation) while a route that does not answers 404 (Go's "page not found"). Nothing
reaches the point of changing the account.

Read this before extending it: the moment a probe sends a *valid* body it is editing the owner's real
MakerWorld collections, which is a different kind of act and needs to be deliberate.

    docker exec -i bambuddy python3 - < mw_collection_write_probe.py
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


def probe(method, path, bearer, body=None):
    data = json.dumps(body).encode() if body is not None else b""
    req = urllib.request.Request(f"{API}{path}", data=data, method=method,
                                 headers={"Authorization": f"Bearer {bearer}",
                                          "User-Agent": UA,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, (r.read()[:160] or b"").decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, (e.read()[:160] or b"").decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)[:80]


t = token()
if not t:
    raise SystemExit("no cloud token stored")

print("EMPTY-BODY probes. 404 = no such route. 400/422 = the route EXISTS.\n")

print("-- add a design to a collection --")
for method, path in (
    ("POST", "/design-service/favorites/9100001/designs"),
    ("PUT", "/design-service/favorites/9100001/designs"),
    ("POST", "/design-service/my/favorites/9100001/designs"),
    ("POST", "/design-service/design/1286770/favorite"),
    ("POST", "/design-service/design/1286770/collect"),
    ("POST", "/design-service/my/favorites/design"),
):
    status, body = probe(method, path, t)
    print(f"  {method:5} {path:52} -> {status}  {body[:70]}")

print("\n-- create a collection --")
for method, path in (
    ("POST", "/design-service/my/favorites"),
    ("POST", "/design-service/favorites"),
    ("POST", "/design-service/my/favorites/listlite"),
):
    status, body = probe(method, path, t)
    print(f"  {method:5} {path:52} -> {status}  {body[:70]}")

print("\n-- remove (needed before any add can be tested safely) --")
for method, path in (
    ("DELETE", "/design-service/favorites/9100001/designs"),
    ("DELETE", "/design-service/design/1286770/favorite"),
):
    status, body = probe(method, path, t)
    print(f"  {method:6} {path:52} -> {status}  {body[:70]}")
