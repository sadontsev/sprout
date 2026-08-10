#!/usr/bin/env python3
"""Spike 1b — try DEDICATED requests for the trusted-cert list.

pushall (spike 1) did not surface a security block. The list may need its own command. This tries a
few plausible ones and reports which, if any, the printer answers — and whether any cert/secur/trust
key appears in the replies. Still read-only; these are query commands, not writes.

    docker exec -i bambuddy python3 - < cert_cmd_probe.py
"""
import json
import re
import sqlite3
import ssl
import time

import paho.mqtt.client as mqtt

c = sqlite3.connect("/app/data/bambuddy.db")
serial, ip, code = c.execute(
    "SELECT serial_number, ip_address, access_code FROM printers WHERE id=2"
).fetchone()
c.close()

CANDIDATES = [
    {"security": {"sequence_id": "1", "command": "app_cert_list"}},
    {"security": {"sequence_id": "2", "command": "get_cert_list"}},
    {"security": {"sequence_id": "3", "command": "get_app_cert_list"}},
    {"info": {"sequence_id": "4", "command": "get_accessory"}},
    {"system": {"sequence_id": "5", "command": "get_access_code"}},
]

reports = []


def on_connect(client, _u, _f, rc, _p=None):
    print(f"connect rc={rc}", flush=True)
    client.subscribe(f"device/{serial}/report")
    for cmd in CANDIDATES:
        client.publish(f"device/{serial}/request", json.dumps(cmd))
        time.sleep(0.5)


def on_message(_c, _u, msg):
    try:
        reports.append(json.loads(msg.payload))
    except Exception:
        pass


def keypaths(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            here = f"{prefix}.{k}" if prefix else k
            yield here
            yield from keypaths(v, here)
    elif isinstance(obj, list) and obj:
        yield from keypaths(obj[0], prefix + "[]")


client = mqtt.Client(client_id="sprout-certspike2", protocol=mqtt.MQTTv311)
client.username_pw_set("bblp", code)
client.tls_set(cert_reqs=ssl.CERT_NONE)
client.tls_insecure_set(True)
client.on_connect = on_connect
client.on_message = on_message
client.connect(ip, 8883, keepalive=30)
client.loop_start()
time.sleep(9)
client.loop_stop()
client.disconnect()

# What command REPLIES came back (the printer echoes command names in acks/reports)?
echoes = set()
allkeys = set()
for r in reports:
    if not isinstance(r, dict):
        continue
    for top, v in r.items():
        if isinstance(v, dict) and "command" in v:
            echoes.add(f"{top}.{v['command']}")
    for k in keypaths(r):
        allkeys.add(k)

strict = sorted(k for k in allkeys if re.search(r"cert|secur|trust", k, re.I))

print(f"\ndistinct messages: {len(reports)}")
print(f"command echoes seen: {sorted(echoes) or 'NONE'}")
print(f"strict cert/secur/trust keys: {strict or 'NONE'}")
if strict:
    print("\n*** a cert-related reply exists — the path has a target ***")
else:
    print("\nRESULT: none of the tried commands produced a cert list. Either the command name is "
          "different (undocumented) or the firmware does not expose it to LAN clients at all. The "
          "cheap reads are exhausted; going further means guessing command names or reversing the "
          "official app, which is exactly the low-certainty territory the design flagged.")
