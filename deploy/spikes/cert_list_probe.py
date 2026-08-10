#!/usr/bin/env python3
"""Spike 1 — the free read that can kill the cloud-signing idea before any credentials.

Question it answers: does the printer expose `security.app_cert_list` (or anything like it) over
the EXISTING LAN MQTT connection? If the printer never reports a trusted-certificate list, then the
"enrol a device certificate for the owner's account" path has nothing to target and the whole idea
is dead — at zero cost and with no Bambu account touched.

This is read-only. It publishes exactly one `pushall`, which is the same benign "report your full
state" request Bambuddy already sends continuously; the design doc confirmed a second MQTT client
coexists with Bambuddy fine. It changes nothing on the printer.

Run inside the bambuddy container (has paho, can reach the printer, and holds the creds):
    docker exec -i bambuddy python3 - < cert_list_probe.py

Nothing secret is printed: the serial is masked, and only KEY NAMES of any security block are shown,
never values.
"""
import json
import re
import sqlite3
import ssl
import sys
import time

import paho.mqtt.client as mqtt

DB = "/app/data/bambuddy.db"
PRINTER_ID = 2
COLLECT_SECONDS = 10


def load_printer():
    c = sqlite3.connect(DB)
    row = c.execute(
        "SELECT serial_number, ip_address, access_code FROM printers WHERE id=?",
        (PRINTER_ID,),
    ).fetchone()
    c.close()
    if not row or not all(row):
        sys.exit("printer 2 missing serial/ip/access_code in the DB")
    return {"serial": row[0], "ip": row[1], "code": row[2]}


def mask(s: str) -> str:
    s = str(s)
    return s[:2] + "…" + s[-2:] if len(s) > 4 else "…"


def walk_keys(obj, prefix=""):
    """Yield dotted key paths, so we can spot a security/cert branch wherever it hides."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            here = f"{prefix}.{k}" if prefix else k
            yield here
            yield from walk_keys(v, here)
    elif isinstance(obj, list) and obj:
        yield from walk_keys(obj[0], prefix + "[]")


def main():
    p = load_printer()
    serial = p["serial"]
    print(f"printer 2: model H2C, serial {mask(serial)}, ip {mask(p['ip'])}", flush=True)

    reports = []

    def on_connect(client, _u, _f, rc, _props=None):
        print(f"mqtt connect rc={rc} (0=ok)", flush=True)
        client.subscribe(f"device/{serial}/report")
        # The one publish: ask the printer to report everything it knows.
        client.publish(
            f"device/{serial}/request",
            json.dumps({"pushing": {"sequence_id": "0", "command": "pushall"}}),
        )

    def on_message(_c, _u, msg):
        try:
            reports.append(json.loads(msg.payload))
        except Exception:
            pass

    client = mqtt.Client(client_id="sprout-certspike", protocol=mqtt.MQTTv311)
    client.username_pw_set("bblp", p["code"])
    # The printer serves a self-signed cert on 8883; Bambuddy itself does not verify it.
    client.tls_set(cert_reqs=ssl.CERT_NONE)
    client.tls_insecure_set(True)
    client.on_connect = on_connect
    client.on_message = on_message

    client.connect(p["ip"], 8883, keepalive=30)
    client.loop_start()
    time.sleep(COLLECT_SECONDS)
    client.loop_stop()
    client.disconnect()

    if not reports:
        print("\nRESULT: no report received. Either the LAN connection failed or the printer sent "
              "nothing in the window. Not a verdict on the cert list yet — check the connect rc.")
        return

    merged = {}
    for r in reports:
        if isinstance(r, dict):
            merged.update(r)

    all_paths = sorted(set(walk_keys(merged)))
    hits = [k for k in all_paths if re.search(r"cert|secur|trust|sign", k, re.I)]

    print(f"\n{len(reports)} report message(s); {len(all_paths)} distinct key paths.")
    print("\nTOP-LEVEL keys pushall surfaced:")
    print("  " + ", ".join(sorted(merged.keys())))

    if hits:
        print("\n*** SECURITY / CERT-RELATED KEY PATHS FOUND (this is the encouraging result) ***")
        for h in hits:
            print("  " + h)
        # Show the shape of the security block, KEY NAMES ONLY.
        for top in merged:
            if re.search(r"secur", top, re.I) and isinstance(merged[top], dict):
                print(f"\n  '{top}' block, keys only:")
                for k, v in merged[top].items():
                    kind = type(v).__name__
                    size = f"[{len(v)}]" if isinstance(v, (list, dict)) else ""
                    print(f"    {k}: {kind}{size}")
    else:
        print("\nRESULT: no security/cert/trust/sign key anywhere in pushall.")
        print("The trusted-cert list is NOT exposed via pushall on this firmware. That does not "
              "fully kill the path — the list may need a dedicated command (e.g. a 'security' or "
              "'get_accessory' request) — but it means the cheapest read failed, and the next step "
              "is a targeted command whose name we do not yet have a source for. Stop here and "
              "decide whether the certificate path is worth a deeper, less certain spike.")


if __name__ == "__main__":
    main()
