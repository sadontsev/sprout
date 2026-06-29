#!/usr/bin/env python3
"""
Ensure a support-enabled twin of each A1 quality profile exists in Bambuddy.

WHY: the app's scoped API key cannot create presets (admin-only, 403), and Bambuddy's slice API has
no per-setting override — so the only way to slice *with supports* from the app is to have a
support-enabled *process profile* already present. This creates one per A1 0.4-nozzle quality preset
by INHERITING the standard profile and flipping `enable_support` on (Bambuddy resolves `inherits`
against its cached base presets, so we only store the delta). The app then offers a "Supports" toggle
that selects the matching twin.

IDEMPOTENT: skips twins that already exist, so it's safe to re-run after every Bambuddy update
(`docker compose pull && up -d`). Wire it into the deploy as the last step.

AUTH: admin login. Creds come from, in order: BB_ADMIN_USER/BB_ADMIN_PW env vars, then --password-file,
then an interactive prompt. The password is never logged. On homeserver the secret already lives at
~/.config/bambu-phase0/ — e.g.  BB_ADMIN_PW="$(cat ~/.config/bambu-phase0/bb_admin_pw)" ./ensure-support-profiles.py

USAGE:
  BAMBUDDY_URL=http://localhost:8000 BB_ADMIN_USER=admin BB_ADMIN_PW=... python3 ensure-support-profiles.py
  python3 ensure-support-profiles.py            # prompts for creds, hits https://bambuddy.example.com
"""
import argparse, getpass, json, os, re, sys, urllib.error, urllib.request

BASE = os.environ.get("BAMBUDDY_URL", "https://bambuddy.example.com").rstrip("/")
SUFFIX = " @BBL A1"
TWIN_INSERT = " + Supports"  # "0.20mm Standard @BBL A1" -> "0.20mm Standard + Supports @BBL A1"


def req(method, path, token=None, body=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or "{}")
        except Exception:
            return e.code, {}


def is_a1(name):
    return "A1" in name and "A1M" not in name and "mini" not in name.lower()


def twin_name(base_name):
    return base_name.replace(SUFFIX, TWIN_INSERT + SUFFIX) if base_name.endswith(SUFFIX) else base_name + TWIN_INSERT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--password-file", help="file containing the admin password")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    user = os.environ.get("BB_ADMIN_USER") or input("Bambuddy admin username: ").strip()
    pw = os.environ.get("BB_ADMIN_PW")
    if not pw and args.password_file:
        pw = open(args.password_file).read().strip()
    if not pw:
        pw = getpass.getpass("Bambuddy admin password (hidden): ")

    st, login = req("POST", "/api/v1/auth/login", body={"username": user, "password": pw})
    token = login.get("access_token")
    if not token:
        if login.get("requires_2fa"):
            sys.exit("Admin account has 2FA enabled — run this where you can complete 2FA, or disable it for this service account.")
        sys.exit(f"Login failed (HTTP {st}): {json.dumps(login)[:300]}")

    st, presets = req("GET", "/api/v1/slicer/presets", token)
    if st != 200:
        sys.exit(f"Couldn't read presets (HTTP {st})")

    std = (presets.get("standard") or {}).get("process") or []
    # the same A1 0.4-nozzle quality set the app shows (exclude 0.2/0.6/0.8-nozzle variants and existing support twins)
    qualities = [
        p for p in std
        if is_a1(p.get("name", "")) and re.search(r"0\.\d+mm .*@BBL A1", p["name"]) and not re.search(r"0\.[268] nozzle", p["name"]) and not re.search(r"support|tree", p["name"], re.I)
    ]

    # existing local presets, to skip twins we already made
    existing = set()
    for group in ("process",):
        st, loc = req("GET", "/api/v1/local-presets/", token)
        if st == 200:
            items = loc if isinstance(loc, list) else (loc.get(group) or loc.get("items") or [])
            for it in items if isinstance(items, list) else []:
                if isinstance(it, dict) and it.get("name"):
                    existing.add(it["name"])

    created, skipped, failed = [], [], []
    for q in qualities:
        name = twin_name(q["name"])
        if name in existing:
            skipped.append(name)
            continue
        setting = {
            "inherits": q["name"],
            "enable_support": "1",
            "support_type": "tree(auto)",
            "support_threshold_angle": "30",
        }
        if args.dry_run:
            created.append(name + "  (dry-run)")
            continue
        st, resp = req("POST", "/api/v1/local-presets/", token, {"name": name, "preset_type": "process", "setting": setting})
        (created if st in (200, 201) else failed).append(name if st in (200, 201) else f"{name}  -> HTTP {st}: {json.dumps(resp)[:160]}")

    print(f"\nBase A1 qualities found: {len(qualities)}")
    print(f"Created : {len(created)}")
    for n in created:
        print("   +", n)
    if skipped:
        print(f"Already present (skipped): {len(skipped)}")
    if failed:
        print(f"FAILED: {len(failed)}")
        for n in failed:
            print("   x", n)
        sys.exit(1)
    print("\nDone. In the app the 'Supports' toggle will now pick these when you enable it.")


if __name__ == "__main__":
    main()
