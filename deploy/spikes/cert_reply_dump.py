#!/usr/bin/env python3
"""Spike 1c — the printer ANSWERS security.app_cert_list. Capture the actual reply.

Shows the result/reason codes and the SHAPE of any cert list (entry count and field names, with the
identifying CN masked), so we learn whether the list is populated, empty, or gated — without dumping
anything sensitive.

    docker exec -i bambuddy python3 - < cert_reply_dump.py
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

security_replies = []


def mask_cn(s):
    return re.sub(r"[0-9A-Za-z]{8,}", lambda m: m.group()[:2] + "…" + m.group()[-2:], str(s))


def on_connect(client, _u, _f, rc, _p=None):
    client.subscribe(f"device/{serial}/report")
    client.publish(f"device/{serial}/request",
                   json.dumps({"security": {"sequence_id": "1", "command": "app_cert_list"}}))


def on_message(_c, _u, msg):
    try:
        r = json.loads(msg.payload)
    except Exception:
        return
    if isinstance(r, dict) and "security" in r:
        security_replies.append(r["security"])


client = mqtt.Client(client_id="sprout-certspike3", protocol=mqtt.MQTTv311)
client.username_pw_set("bblp", code)
client.tls_set(cert_reqs=ssl.CERT_NONE)
client.tls_insecure_set(True)
client.on_connect = on_connect
client.on_message = on_message
client.connect(ip, 8883, keepalive=30)
client.loop_start()
time.sleep(8)
client.loop_stop()
client.disconnect()

print(f"security replies: {len(security_replies)}\n")
for rep in security_replies:
    scalar = {k: v for k, v in rep.items() if not isinstance(v, (list, dict))}
    print("scalars:", scalar)
    for k, v in rep.items():
        if isinstance(v, list):
            print(f"\n  '{k}' is a LIST of {len(v)} entries")
            if v and isinstance(v[0], dict):
                print(f"    entry field names: {list(v[0].keys())}")
                # Show one entry with any long identifier masked.
                masked = {fk: mask_cn(fv) for fk, fv in v[0].items()}
                print(f"    first entry (masked): {masked}")
            elif v:
                print(f"    first entry (masked): {mask_cn(v[0])}")
        elif isinstance(v, dict):
            print(f"  '{k}' is an object with keys: {list(v.keys())}")

if not security_replies:
    print("no security reply captured this run — retry; the earlier probe proved it answers.")
