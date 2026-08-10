# 16 — Controlling the printer without LAN Developer Mode

**Status: research + design. No code written. Researched 2026-08-10.**

The H2C refuses nine of the app's actions because its firmware rejects unsigned MQTT commands
(`"mqtt message verify failed"`) while status keeps flowing. `native/Sprout/Domain/LanMode.swift`
exists to stop the app lying about that. This document establishes whether routing those actions
through **Bambu's cloud** — from the server, never the phone — would restore them.

## Verdict first

**The hypothesis is mostly false, and the part of it that is true points somewhere else.**

The premise was: *"the cloud path authenticates and signs commands with the user's own Bambu
account, which is how Handy drives this printer."* The first half is wrong and the second half is
right for the wrong reason.

Bambu's Authorization Control does not gate on **transport**. It gates on a **per-message RSA-SHA256
signature** carried in a `header` object inside the MQTT payload, verified by the printer firmware.
The researcher who extracted Bambu Connect's key describes it signing MQTT messages for critical
operations *"during both local network and cloud connections"*
([Hackaday, 2025-01-19](https://hackaday.com/2025/01/19/bambu-connects-authentication-x-509-certificate-and-private-key-extracted/)).
Handy works because Handy holds a signing identity, not because it speaks over the cloud broker.

So: **publishing the same nine commands to `us.mqtt.bambulab.com` instead of the printer's IP would
change nothing.** The rejection would follow the message. The Home Assistant integration's own
documentation says this in plain words for the cloud-connected case:

> If you choose to update a locked down firmware version and wish to keep your printer connected to
> Bambu Cloud, the majority of the write functionality will no longer work. The functionality to read
> sensor information is not impacted.
>
> — [ha-bambulab docs, `docs/index.mdx`](https://github.com/greghesp/ha-bambulab/blob/main/docs/index.mdx)

The kernel of truth is that the **cloud account is the issuing authority for the signing identity**.
The official client asks the cloud for a device certificate scoped to the printer, and then signs
local MQTT with it. That is a real, account-derived path — and it is the only honest place a
"cloud unlocks control" design could stand. It also happens to be the least documented thing in the
whole ecosystem. See [The one path that could actually work](#the-one-path-that-could-actually-work).

**Recommendation up front:** do not build a cloud transport. Run the three cheap spikes in
[Spike plan](#spike-plan) — the first one is likely to improve the app on its own, and the second
kills or confirms the cloud hypothesis in an afternoon — and only then decide between (a) accepting
the limits with honest UI, (b) enabling Developer Mode, or (c) a time-boxed certificate-enrolment
investigation.

---

## 1. What the printer is actually doing

Probed live from the server on 2026-08-10 (printer id 2, `GET /api/v1/printers/2/status`):

| Field | Value |
|---|---|
| `model` | `H2C` |
| `firmware_version` | `01.02.00.00` |
| `connected` | `true` |
| `state` | `RUNNING` |
| `developer_mode` | `false` |

Bambuddy derives that flag two ways, both in `/app/backend/app/services/bambu_mqtt.py`:

1. From the status report's `fun` bitfield — `self.state.developer_mode = (fun_int & 0x20000000) == 0`.
   Bit 29 set means "authorization required".
2. When `fun` is absent (A1/P1 never send it), by **active probe**: publish a no-op
   `print.ams_filament_setting` for the external slot and read the reply —
   `result == "failed"` and `"verify failed" in reason` → Developer Mode off.

The nine blocked actions map to these MQTT commands, all published to `device/<SERIAL>/request`:

| `ActionId` | MQTT command |
|---|---|
| `pause` | `print.pause` |
| `resume` | `print.resume` |
| `speed` | `print.print_speed` |
| `amsLoad` / `amsUnload` | `print.ams_change_filament`, `print.ams_control` |
| `dryStart` / `dryStop` | `print.ams_filament_drying`, `print.auto_stop_ams_dry` |
| `startPrint` / `printAgain` | `print.project_file` |

> **A latent bug in `LanMode.swift` worth fixing regardless of any cloud work.** The ha-bambulab
> maintainer reports that recent A1 firmware **stopped emitting the `fun` field**, so his integration
> lost the signal and *"a bunch of controls that cannot work since Bambu blocks them reappeared"*
> ([greghesp/ha-bambulab#1851](https://github.com/greghesp/ha-bambulab/issues/1851)). That is this
> repo's recurring bug, arriving from the firmware side. Our tri-state resolves a missing flag to
> `.unknown`, which un-dims everything — correct on cold start, wrong forever if a firmware update
> deletes the field. Bambuddy's active probe is the mitigation; the app should prefer a probed
> answer over an inferred one and should not treat "we never heard" as "probably fine" indefinitely.

---

## 2. Bambu cloud auth, as it actually works today

### Endpoints

| Purpose | Endpoint |
|---|---|
| Login (password **or** code, not both) | `POST /v1/user-service/user/login` |
| TOTP second factor | `POST https://bambulab.com/api/sign-in/tfa` (**not** on `api.`) |
| Email code request | `POST /v1/user-service/user/sendemail/code` |
| SMS code request (CN) | `POST /api/v1/user-service/user/sendsmscode` |
| Refresh | `POST /v1/user-service/user/refreshtoken` — **documented as returning 401** |
| User id / `u_<n>` | `GET /v1/design-user-service/my/preference` |
| Bound devices | `GET /v1/iot-service/api/user/bind` |
| Camera stream auth | `POST /v1/iot-service/api/user/ttcode` |
| **App certificate exchange** | `GET /v1/iot-service/api/user/applications/{appToken}/cert?aes256={encrypted}` |

Bases: `https://api.bambulab.com` (global) and `https://api.bambulab.cn` (China).
Sources: [OpenBambuAPI `cloud-http.md`](https://github.com/Doridian/OpenBambuAPI/blob/main/cloud-http.md),
[pybambu `const.py`](https://github.com/greghesp/ha-bambulab/blob/main/custom_components/bambu_lab/pybambu/const.py),
[bambu-mcp `docs/cloud-api-reference.md`](https://github.com/schwarztim/bambu-mcp/blob/main/docs/cloud-api-reference.md),
and Bambuddy's own `bambu_cloud.py` (read from the running container).

### The flow

`login` returns one of three things: an `accessToken` outright (rare), `loginType: "verifyCode"`
(a 6-digit code goes to email/SMS; resubmit to the same login endpoint as `{account, code}`), or
`loginType: "tfa"` plus a `tfaKey` (submit `{tfaKey, tfaCode}` to the `bambulab.com/api/sign-in/tfa`
endpoint; the token may come back in a **cookie** rather than the body — Bambuddy checks both).

### Token lifetime and refresh — the weak spot

- The access token is a JWT whose payload carries the username as `u_<digits>`; pybambu decodes it
  rather than calling the preference endpoint.
- OpenBambuAPI states tokens *"typically remain valid approximately 3 months"*. Bambuddy hardcodes a
  30-day expiry assumption (`timedelta(days=30)`) because it has nothing better.
- **There is no working refresh.** OpenBambuAPI annotates `refreshtoken` with "⚠️ returns 401".
  Bambuddy stores `refreshToken` and never uses it. A Bambuddy user notes the cookie comes in short
  and long forms and *"using short tokens doesn't seem to be effective for a long period"*
  ([maziggy/bambuddy#1396](https://github.com/maziggy/bambuddy/issues/1396)).

So the realistic model is: **a long-lived bearer token that silently dies and must be re-minted by a
human doing a 2FA dance.** Any design that puts a print control behind it must treat expiry as a
normal, expected state — not an error path.

### Cloudflare

Bambu's edge intermittently serves Cloudflare interstitials to non-browser clients. Bambuddy has a
dedicated `_detect_cloudflare_challenge()` that triggers on `"Just a moment..."`,
`challenges.cloudflare.com`, `403 + cf-mitigated`, or `503 + cf-ray`, and tells the user to sign in
from a browser on the same network to clear it. pybambu goes further and ships three transports —
plain `requests`, `cloudscraper`, and `curl_cffi` with `impersonate='chrome'` — and identifies as
`bambu_network_agent/01.09.05.01` with `X-BBL-*` headers copied from the official client.

That impersonation is exactly what Bambu publicly objected to (§6). Bambuddy deliberately does the
opposite and identifies as `Bambuddy/1.0 (+https://github.com/maziggy/bambuddy)`, with a comment in
the source explaining the choice. **Any code we add must follow Bambuddy's convention, not
pybambu's.**

---

## 3. Cloud MQTT: endpoints, topics, and why they don't help

| | Cloud | LAN |
|---|---|---|
| Host | `us.mqtt.bambulab.com` (global) / `cn.mqtt.bambulab.com` (China) | printer IP |
| Port | 8883, TLS | 8883, TLS (self-signed) |
| Username | `u_<USER_ID>` | `bblp` |
| Password | the full access token | the LAN access code |
| Subscribe | `device/<SERIAL>/report` | *same* |
| Publish | `device/<SERIAL>/request` | *same* |

Sources: [OpenBambuAPI `mqtt.md`](https://github.com/Doridian/OpenBambuAPI/blob/main/mqtt.md);
pybambu's `cloud_mqtt_host` property (`"cn.mqtt.bambulab.com" if self._region == "China" else
"us.mqtt.bambulab.com"`) and `bambu_client.py`, which uses **identical topic strings in both modes**.

The topics are the same, the payloads are the same, and the firmware's verification is applied to the
payload. The cloud broker adds reachability from outside the LAN — which we do not need, because the
Bambuddy server sits on the same network as the printer. It adds nothing else.

### The signature that actually matters

A signed command looks like this (captured from Handy v3.x against a P1S,
[bambu-mcp `docs/mqtt-protocol.md`](https://github.com/schwarztim/bambu-mcp/blob/main/docs/mqtt-protocol.md)):

```json
{
  "user_id": "<numeric user id>",
  "print": { "command": "push_status", "sequence_id": "2039" },
  "header": {
    "sign_ver": "v1.0",
    "sign_alg": "RSA_SHA256",
    "sign_string": "<base64 RSA signature over the payload, header excluded>",
    "cert_id": "<hex fingerprint>CN=<SERIAL>.bambulab.com",
    "payload_len": 225
  }
}
```

Two things to notice. The `cert_id` is **scoped to the printer's serial** — this is not one global
key waved at every machine; it names a certificate the *printer* recognises. And the printer exposes
`{"security": {"command": "app_cert_list", "type": "app"}}`, which returns the `cert_ids` it will
currently accept. That last one is a **read** we can perform today over the existing LAN connection,
and it is the cheapest possible probe of whether this scheme is even live on H2C firmware.

---

## 4. Which of the nine the cloud path can genuinely perform

Being blunt, because the whole point of `LanMode.swift` is to stop guessing:

| Action | Cloud transport alone | With a valid signing identity |
|---|---|---|
| `pause`, `resume`, `speed` | **No** | Likely yes |
| `amsLoad`, `amsUnload` | **No** | Likely yes |
| `dryStart`, `dryStop` | **No** | Likely yes |
| `startPrint`, `printAgain` (`project_file`) | **No** | **Probably still no** |

"Likely yes" rests on bambu-mcp's explicit claim, which is the only source that states the split:

> **Limitations without Developer Mode:** Printing `.3mf` files via `project_file` command requires
> Developer Mode. `.gcode` files and all other commands (stop, pause, resume, status, speed, G-code,
> camera, AMS) work without it.
>
> — [bambu-mcp README](https://github.com/schwarztim/bambu-mcp/blob/main/README.md)

Two caveats that must not be glossed over. First, bambu-mcp lists its supported models as
**P1P, P1S, X1C, A1, A1 Mini** — no H2 series. Second, that project achieves its signing by using
the **publicly extracted Bambu Connect private key**, which is a different thing from an
account-derived certificate and carries different consequences (§6).

There is a second-order cloud path for starting prints that does not need `project_file` over LAN at
all: upload the sliced 3MF to Bambu's cloud (`POST /v1/user-service/my/upload`), create a task
(`POST /v1/user-service/my/task`), and let the printer fetch it — which is what Handy does when you
print from your phone. Whether a third-party client can create a task that the printer will accept is
untested by any project I found, and it would mean our sliced files leave the house, which cuts
against the entire premise of this setup. Noted for completeness; not recommended.

---

## 5. What already exists — repo, backend, and the ecosystem

### Bambuddy: cloud login exists, cloud *control* does not

Probed on the server. Bambuddy exposes 548 paths, of which these are cloud:

```
POST   /api/v1/cloud/login      POST   /api/v1/cloud/verify     POST /api/v1/cloud/token
POST   /api/v1/cloud/logout     GET    /api/v1/cloud/status     GET  /api/v1/cloud/devices
GET    /api/v1/cloud/settings   GET    /api/v1/cloud/filaments  GET  /api/v1/cloud/firmware-updates
GET    /api/v1/cloud/builtin-filaments  /cloud/fields  /cloud/filament-id-map  /cloud/filament-info
```

`CloudLoginRequest`/`CloudVerifyRequest`/`CloudTokenRequest` all carry `region: "global" | "china"`,
and `CloudAuthStatus` returns `{is_authenticated, email, region}`. Bambuddy's own wiki is explicit
that this is for *"cloud profiles, MakerWorld imports, slicer presets and printer firmware checks"* —
[Cloud Profiles (Bambu)](https://wiki.bambuddy.cool/features/cloud-profiles/) — and describes the
integration as read-only against Bambu Cloud.

The MQTT service confirms it. In `/app/backend/app/services/bambu_mqtt.py`:

```python
MQTT_PORT = 8883
self._client.username_pw_set("bblp", self.access_code)
self._client.connect_async(self.ip_address, self.MQTT_PORT, keepalive=30)
```

Hardcoded LAN, hardcoded `bblp`. Nothing in the file references `mqtt.bambulab.com`, `sign_string`,
`cert_id`, or `header`. A repo-wide search of Bambuddy's issue tracker for `sign_string`, `cert_id`
and `signed command` returns **zero** results. **Bambuddy has no cloud transport and no command
signing, and nobody has asked it for one.**

Two live facts to build on: our API key is currently **not** authorised for cloud data
(`/cloud/status` → *"This API key is not authorised to access Bambu Cloud data. Enable 'Allow cloud
access' on the key"*), and Phase 0 already proved a **second MQTT client can coexist** with Bambuddy
against the same printer with no telemetry flap (`docs/phase0-results.md` §5) — so a sidecar that
publishes signed commands would not have to displace Bambuddy's connection.

### The app

`mobile/src/capabilities/lanMode.ts` and `native/Sprout/Domain/LanMode.swift` are the two
implementations of the gate; `native/SproutTests/LanModeTests.swift` and
`mobile/src/capabilities/__tests__/lanMode.test.ts` are their tests. Nothing else in the repo knows
about transports.

### The ecosystem, and what each project had to do

| Project | What it does | What it had to do |
|---|---|---|
| [ha-bambulab / pybambu](https://github.com/greghesp/ha-bambulab) | HA integration; LAN, cloud, and hybrid modes | Cloudflare evasion (cloudscraper / `curl_cffi` impersonation) and an official-client User-Agent. Tells users plainly that **cloud-connected + locked firmware = reads only**, and that restoring writes means LAN Mode + Developer Mode and losing Handy. |
| [OpenBambuAPI](https://github.com/Doridian/OpenBambuAPI) | Protocol documentation | Nothing — it is the reference both for topics and for the cloud HTTP surface. |
| [bambu-mcp](https://github.com/schwarztim/bambu-mcp) | MCP server, local MQTT only | Signs every command RSA-SHA256 with the **extracted Bambu Connect key**; also offers a browser-login mode "if you don't want to enable Developer Mode (e.g. to keep Bambu Handy working)". Cloud API used only for discovery. |
| [coelacant1/Bambu-Lab-Cloud-API](https://github.com/coelacant1/Bambu-Lab-Cloud-API) | Python cloud+MQTT library, self-described as *"API access without developer mode"* | Its own docs make **no claim** about controlling without Developer Mode and document no command list; treat the tagline as aspirational. |
| [bambulabs_api](https://pypi.org/project/bambulabs-api/) | Python printer API | LAN-oriented; no evidence of a signing or cloud-control story. |
| SimplyPrint, 3DPrinterOS (commercial) | Cloud print management | Both require **Developer Mode**. 3DPrinterOS's help centre states the integration shows "MQTT command verification failed" without it. |

The pattern is unambiguous: **everyone who genuinely controls a locked-down printer either turns on
Developer Mode or signs with the extracted key. Nobody restores control by switching transport.**

---

## 6. The one path that could actually work

`GET /v1/iot-service/api/user/applications/{appToken}/cert?aes256={encrypted}` exchanges an
application token for an X.509 device certificate — described as *"used for MQTT authentication"*,
with the note that *"the app token and AES payload are generated client-side"*
([bambu-mcp cloud API reference](https://github.com/schwarztim/bambu-mcp/blob/main/docs/cloud-api-reference.md)).
The printer then lists the certificates it trusts via `security.app_cert_list`, keyed
`CN=<SERIAL>.bambulab.com`.

If a third party can enrol a certificate **for the owner's own account and the owner's own printer**,
that is a legitimate, account-derived signing identity: no impersonation, no extracted key, no
circumvention — the same authorisation Handy has, obtained the same way, for the same account.

That is the design worth wanting. It is also the one with the least public documentation of anything
in this document: the `appToken` derivation and the `aes256` payload format are unknown, likely
obfuscated inside the official apps, and plausibly bound to a client identity we do not have and
should not fake. **Assume this fails until a spike says otherwise.** Do not put it on a roadmap.

### The other path, stated honestly and not recommended

The Bambu Connect private key was extracted and published in January 2025 and works because the
printer verifies against a key embedded in every copy of a shipping application. Signing with it
would very likely restore seven of the nine actions today. It is:

- **impersonating an official client**, which Bambu has publicly and specifically said is not
  allowed — *"Modifying and distributing AGPL code – absolutely. But impersonating official clients
  in communication with our cloud infrastructure is not allowed"*
  ([Bambu Lab, 2026-05-07](https://blog.bambulab.com/setting-the-record-straight-on-cloud-access-and-community/));
- **circumvention of a technical protection measure** using a key the owner has no licence to use,
  with the legal exposure that implies;
- **one firmware release from dying**, since revoking a compromised, publicly-known key is the
  obvious move and costs Bambu nothing;
- and it puts the owner's warranty and account on the wrong side of a line for a pause button.

It belongs in this document because leaving it out would misrepresent the state of the art. It does
not belong in this app. If the owner disagrees, that is the owner's call to make explicitly — not
something to arrive at by implementation drift.

---

## 7. The owner's suggestion: the Bambu Studio / OrcaSlicer CLI

**Not viable. There is no device-control surface to use.**

Run against the owner's actual sidecar (`bambu-studio-api`, `BambuStudio-02.07.01.57`), the complete
option list is: `--allow-*`, `--arrange`, `--assemble`, `--camera-view`, `--clone-objects`,
`--convert-unit`, `--curr-bed-type`, `--debug`, `--downward-*`, `--enable-timelapse`,
`--ensure-on-bed`, `--estimate-mode`, `--export-3mf`, `--export-png`, `--export-settings`,
`--export-slicedata`, `--export-stl(s)`, `--help`, `--info`, `--load-*`, `--makerlab-*`,
`--metadata-*`, `--min-save`, `--mstpp`, `--mtcpp`, `--no-check`, `--normative-check`, `--orient`,
`--outputdir`, `--pipe`, `--repetitions`, `--rotate*`, `--scale`, `--skip-*`, `--slice`,
`--uptodate*`. The same is true of the OrcaSlicer sidecar: grepping its `--help` for
`upload|send|host|device|network|url` returns only a description mentioning network *storage* and
`--pipe` for progress. This matches the upstream
[Command Line Usage wiki](https://github.com/bambulab/BambuStudio/wiki/Command-Line-Usage).

The reason is structural, not an oversight. Bambu Studio's device control lives in a **closed-source
network plugin** downloaded at runtime — the same plugin Bambu withdrew from third parties in
January 2025 and replaced with Bambu Connect. A search of the sidecar image for anything
network-plugin-shaped finds one SVG icon. The CLI is a slicer; the part that talks to printers was
never in it and is not in the container.

The sidecars are excellent at what Phase 0 proved they are for — headless slicing — and should keep
doing exactly that.

---

## 8. The China-region caveat

This is a China-market machine, and the two clouds are **not** the same system.

- Data is not shared between `bambulab.com` and `bambulab.cn`
  ([maziggy/bambuddy#1396](https://github.com/maziggy/bambuddy/issues/1396)).
- **China accounts are bound to phone numbers, not email.** Bambuddy's email/password form cannot
  authenticate them at all; the maintainer's guidance is that *"token login is the only path"* — mint
  the token by logging into MakerWorld China in a browser and copying the `token` cookie. Bambuddy's
  `POST /api/v1/cloud/token` with `region: "china"` exists precisely for this.
- MQTT would be `cn.mqtt.bambulab.com`; API `api.bambulab.cn`; TOTP `bambulab.cn/api/sign-in/tfa`.
- China-region **printers** are reported to be region-locked and unbindable to global accounts
  ([forum thread](https://forum.bambulab.com/t/bambu-lab-region-lock-china/6602)).

Practical consequences for any design here:

1. **We do not currently know which cloud, if either, this printer is bound to.** Bambuddy's printer
   record has no cloud/bind field, and none of its status, diagnostic or runtime-debug payloads
   contains one. This must be established empirically before anything else (Spike 1).
2. If the answer is the **China** cloud, then the auth story degrades from "2FA once every three
   months" to "copy a cookie out of a browser every time it rotates", and the short-vs-long token
   problem from #1396 lands on us.
3. If the printer turns out **not to be cloud-bound at all**, the entire cloud branch is moot and the
   only remaining choices are Developer Mode or honest UI.

---

## 9. Recommended architecture

Conditional on the spikes. The shape below is what to build **if and only if** Spike 3 finds a
legitimate certificate path; otherwise stop at "Phase 0" and ship the honesty.

### Phase 0 — do this regardless (no cloud involved)

1. **Replace the assumed nine with a measured list.** `Lan.blocked` currently asserts that all nine
   fail because they are all `print.*` on one topic. That is a proxy predicate — the exact shape this
   codebase keeps getting wrong. Measure it (Spike 1a) and encode what the printer actually said.
2. **Harden the tri-state against a firmware that stops reporting.** Prefer Bambuddy's probed answer
   over the inferred `fun` bit, and give `.unknown` a lifetime: if we have been connected for N status
   frames with no probe result, that is not "probably fine".
3. **Name the reason in the UI, not the mode.** Today the copy says "turn on LAN Developer Mode".
   That is one remedy for one cause. The gate should carry a reason enum so the sentence can change
   without touching every call site.

### Phase 1 — server-side signing service (only if Spike 3 succeeds)

```
iOS app ──HTTPS + X-API-Key──▶ Bambuddy ──LAN MQTT (unsigned)──▶ printer   [status, light, camera]
   │                                                                 ▲
   └──HTTPS + X-API-Key──▶ sprout-cmd (new sidecar) ──LAN MQTT (SIGNED)──┘   [the 9 actions]
```

- **`sprout-cmd`** is a small service on the home server, beside Bambuddy in the same compose
  project. It holds the Bambu account credential and the enrolled device certificate, connects to
  the printer's LAN broker as a *second* client (Phase 0 proved coexistence is safe), publishes
  signed commands, and correlates replies by `sequence_id`.
- **Transport does not change.** We keep speaking to the printer over the LAN. The cloud is used
  once, at enrolment time, to obtain the certificate — and then periodically to renew it. This is the
  key architectural consequence of §3: the cloud is an *authority*, not a *pipe*.
- **The app never learns any of this.** It calls one endpoint per action and gets back a typed
  result. Nothing about tokens, certificates, or regions crosses the network boundary to the phone.

### Data shapes

The one thing the app needs is a truthful answer to *"will this work, and how do I say so?"*.
Extend the existing gate rather than adding a parallel one:

```
GET /commands/capabilities  →  { "actions": [
      { "id": "pause",  "availability": "available",   "transport": "lanSigned" },
      { "id": "startPrint", "availability": "unavailable",
        "reason": "needsDeveloperMode",
        "detail": "The printer only accepts print-start commands in Developer Mode." },
      { "id": "dryStart", "availability": "degraded", "reason": "credentialExpiring",
        "detail": "Bambu sign-in expires in 6 days." } ] }
```

- `availability` is the only thing that gates a control. `transport` is **presentation** — a caption,
  never a predicate. Deriving availability from transport would be the exact mistake this codebase
  keeps making: "we have a cloud session" and "the printer will accept this" are different questions.
- `reason` is a closed enum so the Swift side can switch exhaustively; `detail` is server-authored
  copy for the sheet.
- Poll it on the same cadence as status, and invalidate it whenever `developer_mode` changes or a
  command comes back refused.

### Where credentials live

**On the server. Never in the app, never in the Keychain, never over the wire to the phone.**

- Bambu account email/password: **never stored.** Used once, in memory, during the interactive login;
  only the resulting token is persisted. (Bambuddy already works this way, and coelacant1's project
  makes the same commitment.)
- Token and certificate: encrypted at rest in `sprout-cmd`'s own store, file mode 600, alongside the
  existing `~/.config/bambu-phase0/` secrets. Not in the repo, not in compose env, not in logs.
- The **enrolment ceremony is a human, out-of-band act** — SSH to the server, run one command, type
  the 2FA code. It happens roughly quarterly. It must not be reachable from the app, because an
  endpoint that accepts a Bambu password is an endpoint that can be phished through the app.
- On expiry the correct behaviour is `availability: "unavailable", reason: "credentialExpired"` — a
  dimmed control with a sentence, not a spinner and not a 500.

### How the app should surface transport

One line of caption under the control group, driven by `transport`, and a single sheet reachable from
any dimmed control. Suggested copy, matching the register already in `LanMode.swift`:

- `lan` → nothing. The default needs no explanation.
- `lanSigned` → "Sent using your Bambu account." Plus, in the sheet: what that means, when it
  expires, and that it happens on the server.
- `bookkeeping` (`plateCleared`, `queueRemove`, `maintenance`) → "Recorded here only — the printer
  isn't told." That sentence is missing today and is arguably the most honest addition in this whole
  document.
- `unavailable` → keep the existing 0.4-opacity treatment and the tap-to-explain sheet, with the
  reason-specific text.

---

## 10. Risks, stated plainly

**Credential storage.** A Bambu account token is a bearer credential for the owner's whole Bambu
identity — printers, MakerWorld, order history, uploaded models. It is strictly more sensitive than
the Bambuddy API key the app already holds. Compromise of the home server would expose it. This is
the single strongest argument for keeping it off the phone and out of the repo, and for scoping the
Bambuddy API key so the app cannot read it back (`/cloud/status` already refuses our key today —
keep it that way).

**Token expiry.** Not an edge case; the steady state. No working refresh endpoint, ~3-month nominal
lifetime, shorter in practice for China cookies, and a 2FA-gated re-mint. Every control that depends
on it must degrade to a dimmed, explained state. A design that assumes a live token is a design that
will silently regress into exactly the "offered but refused" bug this app was built to eliminate —
except now the lie is on the server side, where the app cannot see it.

**Account security.** Automated login attempts hit Cloudflare and, if retried aggressively, look like
credential stuffing against the owner's own account. Rate-limit login attempts hard (one, then
manual), never retry a failed password automatically, and never log tokens or the `Authorization`
header.

**Terms of service.** Bambu's May 2026 post is the clearest statement available: modifying and
distributing AGPL code is fine, **impersonating official clients to their cloud is not**, and their
stated concern is infrastructure load from many clients pretending to be Bambu Studio. Reading a
personal account's own data with an honest User-Agent — what Bambuddy already does — sits on the
right side of that. Faking `bambu_network_agent/…` or reusing Bambu Connect's key does not. There is
no published rule that settles the certificate-enrolment path either way; if a spike gets that far,
the honest move is to ask Bambu rather than assume.

**API fragility.** Every endpoint in §2 is undocumented and unversioned. `refreshtoken` already
returns 401. The `fun` field already vanished from A1 firmware. The TOTP endpoint is on a different
host from the rest of the API for no stated reason. Assume any of it breaks without notice, and make
breakage visible as a capability change rather than a crash: the fallback for every action is the
LAN path we already have, and the fallback for the whole feature is Phase 0's honest UI.

**Physical risk.** Low but non-zero. A signing implementation that gets `payload_len` or the signed
byte range wrong produces refusals, not wrong commands — the failure mode is inert. The real hazard
is a **retry loop** on a command the printer partially accepted (AMS load is the obvious one).
Idempotency by `sequence_id`, no automatic retries on control commands, and never a retry on
`startPrint`.

**The alternative's cost, for fairness.** Turning on Developer Mode is a supported, documented,
one-time action that restores all nine actions immediately and permanently. It costs: a new access
code (re-entered once in Bambuddy), and **the printer leaving Bambu Cloud entirely** — no Handy, no
remote monitoring, no MakerWorld send-to-printer, per both Bambu's own framing and
[ha-bambulab's docs](https://github.com/greghesp/ha-bambulab/blob/main/docs/index.mdx). If the owner
does not actually use Handy or remote monitoring, that price is close to zero and this entire
document is an expensive way to avoid a settings toggle. That comparison should be made honestly
before any code is written.

---

## Spike plan

Ordered cheapest-and-most-informative first. Each is a throwaway script on the server; none of them
is application code. **Run every printer-touching step while the printer is idle** — it is currently
mid-print.

### Spike 1a — measure the refusal, don't assume it *(≈30 min, no cloud, no risk)*

Publish each of the nine commands to `device/<SERIAL>/request` over the existing LAN broker with a
unique `sequence_id`, and record the exact `result` and `reason` from `…/report`. Use no-op forms
wherever possible (`print_speed` set to the current level; the same `ams_filament_setting` shape
Bambuddy's own probe uses). `pause`/`resume`/`project_file` are the only ones with real side effects —
test those last, on an idle machine, with the owner watching.

**Answers:** are all nine actually refused, or only some? **Payoff regardless of outcome:** the
result belongs in `Lan.blocked` either way, and if the list shrinks, the app gets better this week
with no cloud, no credentials and no risk. This is the highest expected-value hour in the plan.

### Spike 1b — ask the printer what certificates it trusts *(≈10 min, no cloud, read-only)*

Publish `{"security": {"sequence_id": "<n>", "command": "app_cert_list", "type": "app"}}` and read
the reply.

**Answers:** does the H2C implement the certificate scheme at all, and are any certificates currently
enrolled (i.e. has Handy ever been paired)? A non-empty `cert_ids` list is strong evidence the whole
signing design is live on this machine; no response at all means H2C firmware does something else
entirely and §6 needs re-researching before anything is built.

### Spike 2 — kill or confirm the cloud hypothesis *(≈2–3 h, needs the owner's credentials once)*

1. From the server, authenticate: `POST /v1/cloud/login` via Bambuddy with `region: "global"`, and if
   that fails the way #1396 describes, mint a China token from a browser cookie and
   `POST /api/v1/cloud/token` with `region: "china"`. Note whether Cloudflare interferes.
2. `GET /api/v1/cloud/devices` (Bambuddy's wrapper over `/v1/iot-service/api/user/bind`).
   **Is the H2C listed? Is it `online: true`? Which region?**
3. If and only if it is: connect a throwaway MQTT client to `us.` or `cn.mqtt.bambulab.com:8883` as
   `u_<uid>` / token, subscribe to `device/<SERIAL>/report`, and publish **one unsigned no-op** — the
   same `ams_filament_setting` probe. Read the reply.

**Answers the riskiest assumption in one shot.** Expected result: `result: "failed"`,
`reason: "mqtt message verify failed"` — identical to LAN, proving the transport is irrelevant and
closing the question for good. If instead it succeeds, everything in §3 is wrong, this document needs
rewriting, and the architecture becomes far simpler. Either way it costs an afternoon.

Note that step 2 alone is worth doing: if the printer is not cloud-bound, or is bound to a cloud we
cannot log into, the branch ends there.

### Spike 3 — is there a legitimate certificate path? *(time-boxed to one day; do not exceed it)*

Only if Spike 2 fails as expected *and* Spike 1b showed the scheme is live *and* the owner wants to
keep going. Attempt `GET /v1/iot-service/api/user/applications/{appToken}/cert?aes256=…` with an
honest User-Agent and see what a well-formed request even looks like. The `appToken` derivation and
the AES payload format are the unknowns; if an hour of probing does not produce a shape that returns
anything but 4xx, **stop**. The exit criterion is written down in advance on purpose: this is the
step where a research task turns into a reverse-engineering project, and it should not do so by
accident.

**Do not spike the extracted-key path.** Trying it is not a neutral experiment — it is the thing
itself, against the owner's printer, on the owner's account.

### Decision gate

| Spike outcome | Do this |
|---|---|
| 1a shrinks the blocked list | Ship it. Update `Lan.blocked` + tests in both apps. |
| 2 shows the printer is not cloud-bound, or the region is unreachable | Stop. Phase 0 only. |
| 2 shows unsigned cloud commands are refused (expected) | Stop the transport idea. Phase 0, then the Developer Mode conversation. |
| 2 shows unsigned cloud commands **succeed** | Rewrite §3 and design a cloud transport — it just became easy. |
| 3 produces a working enrolment | Build `sprout-cmd` per §9 Phase 1, and consider telling Bambu. |
| 3 hits its time box | Stop. Write down what was learned. Phase 0. |

---

## Sources

- Bambu Lab — [Setting the Record Straight on Cloud Access and Community](https://blog.bambulab.com/setting-the-record-straight-on-cloud-access-and-community/) (2026-05-07)
- Bambu Lab — [Firmware Update Introducing New Authorization Control System](https://blog.bambulab.com/firmware-update-introducing-new-authorization-control-system-2/)
- Bambu Lab Wiki — [HMS 0500-0500-0001-0007, "MQTT Command verification failed"](https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/0500_0500_0001_0007)
- Hackaday — [Bambu Connect's Authentication X.509 Certificate and Private Key Extracted](https://hackaday.com/2025/01/19/bambu-connects-authentication-x-509-certificate-and-private-key-extracted/) (2025-01-19)
- Doridian — [OpenBambuAPI: `mqtt.md`](https://github.com/Doridian/OpenBambuAPI/blob/main/mqtt.md), [`cloud-http.md`](https://github.com/Doridian/OpenBambuAPI/blob/main/cloud-http.md)
- greghesp — [ha-bambulab `docs/index.mdx`](https://github.com/greghesp/ha-bambulab/blob/main/docs/index.mdx), [`docs/setup.mdx`](https://github.com/greghesp/ha-bambulab/blob/main/docs/setup.mdx), [pybambu `const.py`](https://github.com/greghesp/ha-bambulab/blob/main/custom_components/bambu_lab/pybambu/const.py), [`bambu_cloud.py`](https://github.com/greghesp/ha-bambulab/blob/main/custom_components/bambu_lab/pybambu/bambu_cloud.py), [`bambu_client.py`](https://github.com/greghesp/ha-bambulab/blob/main/custom_components/bambu_lab/pybambu/bambu_client.py), [issue #1851](https://github.com/greghesp/ha-bambulab/issues/1851)
- schwarztim — [bambu-mcp README](https://github.com/schwarztim/bambu-mcp/blob/main/README.md), [`docs/mqtt-protocol.md`](https://github.com/schwarztim/bambu-mcp/blob/main/docs/mqtt-protocol.md), [`docs/cloud-api-reference.md`](https://github.com/schwarztim/bambu-mcp/blob/main/docs/cloud-api-reference.md)
- coelacant1 — [Bambu-Lab-Cloud-API](https://github.com/coelacant1/Bambu-Lab-Cloud-API)
- maziggy — [Bambuddy wiki: Cloud Profiles](https://wiki.bambuddy.cool/features/cloud-profiles/), [issue #1396 (China login)](https://github.com/maziggy/bambuddy/issues/1396); plus `backend/app/services/bambu_cloud.py` and `bambu_mqtt.py` read from the running container on 2026-08-10
- bambulab — [BambuStudio Command Line Usage wiki](https://github.com/bambulab/BambuStudio/wiki/Command-Line-Usage); plus `BambuStudio-02.07.01.57 --help` run in the owner's `bambu-studio-api` sidecar, 2026-08-10
- 3DPrinterOS — [Bambu Lab 3D Printers Troubleshooting Guide](https://intercom.help/3DPrinterOS/en/articles/11382779-bambu-lab-3d-printers-troubleshooting-guide)
- Bambu Lab forum — [Bambu Lab Region Lock (China)](https://forum.bambulab.com/t/bambu-lab-region-lock-china/6602)
- This repo — `docs/phase0-results.md`, `native/Sprout/Domain/LanMode.swift`, `mobile/src/capabilities/lanMode.ts`

---

## Review

**Second author. Adversarial pass, 2026-08-10.** Everything above is the first author's text and is left
intact. This section disagrees with parts of it. Where I re-probed the live system or re-read a cited
source, I say so; where I am asserting rather than verifying, I say that too.

**Summary of the disagreement:** the *verdict* is right and well-defended — transport is not the gate,
signing is, and a cloud pipe buys nothing. What does not hold up is (a) several load-bearing claims
about Bambuddy and about the ecosystem projects, which are wrong on the evidence; (b) the Phase 0
plan, which is not implementable against today's Bambuddy; (c) the spike plan, which measures the
wrong half of the problem; and (d) the framing of §6, which draws a legitimacy line the evidence does
not support. Two things that are already true and already shippable are missing entirely.

### What I re-verified and what held

Stated so the disagreements below are read against a fair baseline. All re-probed on the server today.

| Claim | Status |
|---|---|
| Printer id 2 is an H2C, fw `01.02.00.00`, `connected: true`, `state: RUNNING`, `developer_mode: false` | **Confirmed** (`GET /api/v1/printers/2/status`) |
| Bambuddy exposes 548 paths | **Confirmed** — 548 paths / 685 operations |
| `developer_mode = (fun_int & 0x20000000) == 0`, and an `ams_filament_setting` active probe | **Confirmed** — `bambu_mqtt.py:1047`, `:3129`, `:3422–3490` |
| The nine `ActionId` → MQTT command mappings in §1 | **Confirmed** — all nine command strings exist in `bambu_mqtt.py` (`stop`/`pause`/`resume`, `print_speed:4760`, `ams_change_filament:4981,5036`, `ams_control:5075`, `ams_filament_drying:4160`, `auto_stop_ams_dry:5697`, `project_file:3744`) |
| Bambuddy has no cloud MQTT and no signing | **Confirmed** — grep for `mqtt.bambulab`, `sign_string`, `cert_id`, `sign_alg`, `app_cert_list` across `/app/backend/app/` returns **zero** hits |
| `/cloud/status` refuses the app's key | **Confirmed**, HTTP 403, verbatim as quoted |
| TOTP is on a different host — `https://bambulab.com/api/sign-in/tfa`, CN variant `bambulab.cn` | **Confirmed** — `bambu_cloud.py:262–264` |
| Honest User-Agent `Bambuddy/1.0 (+…)` | **Confirmed** — `bambu_cloud.py:23` |
| 30-day hardcoded expiry; `refreshToken` stored and never used | **Confirmed** — `bambu_cloud.py:310,332,337`; no `refreshtoken` request anywhere |
| `/v1/design-user-service/my/preference`, `/v1/iot-service/api/user/bind` | **Confirmed** — `bambu_cloud.py:352`, `:587` |
| ha-bambulab's write-lockout quote | **Confirmed verbatim**, `docs/index.mdx:18` |
| bambu-mcp's model list and its "Limitations without Developer Mode" paragraph | **Confirmed verbatim**; and its README does say every command is auto-signed with the extracted cert |
| Bambu's May 2026 blog quote and its 2026-05-07 date | **Confirmed** |
| §7 — the slicer CLI has no device-control surface | **Confirmed** — re-ran `--help` in the `bambu-studio-api` sidecar (`BambuStudio-02.07.01.57`); grep for `upload\|send\|host\|device\|network\|url` returns only `--pipe` and unrelated print-setting text |

§7 is the strongest section in the document and I have nothing to add to it.

---

### 1. Wrong on the evidence

**1.1 — "Bambuddy … read-only against Bambu Cloud" is false, and it is load-bearing.**
§5 says the wiki "describes the integration as read-only against Bambu Cloud," and §10's ToS argument
rests on "reading a personal account's own data … is what Bambuddy already does." Bambuddy **writes**
to Bambu Cloud: `bambu_cloud.py:450` and `:535` POST to
`https://api.bambulab.com/v1/iot-service/api/slicer/setting`, and `:564` DELETEs from it. Its own API
surface confirms it — `POST /api/v1/cloud/settings` and `GET/PUT/DELETE /api/v1/cloud/settings/{setting_id}`,
both of which §5's path listing omits. This does not overturn the ToS conclusion (writing your own
slicer presets is still your own data with an honest UA), but the sentence as written is wrong, and
"read-only" is doing rhetorical work it hasn't earned.

**1.2 — §5's cloud inventory is incomplete in a way that matters.** It misses
`/api/v1/cloud/settings/{setting_id}` and the entire **`/api/v1/orca-cloud/*` subtree** — seven paths
including `auth/start`, `auth/password`, `auth/finish`, `logout`, `status`, `profiles`. That is a
**second, independent cloud-credential store already running on the same box**. §10's credential-blast-radius
paragraph is written as if `sprout-cmd` would be introducing the first such secret to that host. It
would be the third.

**1.3 — §4 and §5 contradict each other about coelacant1.**
§5 dismisses it: *"Its own docs make no claim about controlling without Developer Mode and document no
command list."* §4 then says of the cloud upload-and-task path: *"Whether a third-party client can
create a task that the printer will accept is untested by any project I found."* That project ships
`API_FILES_PRINTING.md`, which documents exactly that workflow —
`upload_file(...)` → `get_cloud_files()` → `start_cloud_print(device_id=…, filename=…)` — and states
its own limitation as *"Can't perform real-time print control (use MQTT for monitoring)."* So: the
project was dismissed in §5 and then, in §4, cited-by-absence as evidence nobody had done the thing it
does. The dismissal is half-right (no Developer-Mode claim, no *printer command* list) but the
conclusion drawn from it is not. To be fair to the first author: that doc contains **no** verification
evidence either — no statement of having run it against hardware. "One unverified implementation
exists" is a different sentence from "untested by any project I found," and it is the one the evidence
supports.

**1.4 — §2's endpoint table smears its citations.** One blanket "Sources:" line covers four sources for
nine rows. Checked individually: `sendemail/code`, `sendsmscode`, `refreshtoken` and `ttcode` appear
**nowhere** in Bambuddy's `bambu_cloud.py` (grep across `/app/backend/app/` returns zero), so the
"and Bambuddy's own `bambu_cloud.py`" attribution does not cover them. OpenBambuAPI's `cloud-http.md`
documents `sendsmscode` and `refreshtoken` but **not** `sendemail/code`, and documents the
applications endpoint as `GET /v1/iot-service/api/user/applications/{id}` — *not* the
`/{appToken}/cert?aes256=` form. That form comes from bambu-mcp alone. The table reads as four
corroborating sources; it is in places one source with three bystanders. Rows should be cited
individually.

**1.5 — the #1851 quote is real but has been trimmed of the part that undercuts the argument.**
The quote checks out (`AdrianGarside`, 2026-01-23; the doc silently fixes his typo "Bamby"→"Bambu" and
drops "for you" — fine). But his follow-up comment the same day says: *"it appears that with (at least)
the latest A1 firmware **(in at least cloud mode)** it has stopped populating the 'is mqtt encryption
disabled' bit… **What I don't know is if it was just the latest firmware or previously no one had
complained or if they still populate that bit when in lan mode or developer lan mode.**"* The
observation is scoped to cloud mode on an A1, and the maintainer explicitly does not know whether it
generalises. The doc drops both qualifiers and promotes it to a Phase 0 work item. It is still a
legitimate worry; it is not the settled fact the blockquote implies. And it is directly checkable here
in thirty seconds — our H2C *is* currently populating the field, which is why `developer_mode` resolves
to `false` at all (see 2.1).

**1.6 — minor.** §1's table is headed "Probed live … `GET /api/v1/printers/2/status`". `model` is not in
that payload; it comes from `GET /api/v1/printers/`. Everything else in the table is exactly right. In a
table whose whole point is "measured, not assumed," one unmeasurable row is worth fixing.

---

### 2. The Phase 0 plan does not work as written

**2.1 — "Prefer Bambuddy's probed answer over the inferred `fun` bit" is not implementable today, on
this printer, from the app.** Bambuddy's logic (`bambu_mqtt.py:3125–3145`) is:

```
if "fun" in data:                                   -> derive from the bit
elif developer_mode is None and not _dev_mode_probed -> probe
```

The probe is in the **`elif`**. The H2C sends `fun`. Therefore the probe **never runs on this machine**,
and there is no probed answer to prefer. Worse, the REST API exposes a single `developer_mode` boolean
with **no provenance field**, so even if both mechanisms ran, the client could not tell which one
answered. As written, Phase 0 item 2 is not an app change — it is an unscoped Bambuddy change (add
provenance, or force a probe alongside the bit). That should be stated, because "do this regardless, no
cloud involved" currently reads as cheap and it isn't.

**2.2 — the probe is not the safe, preferable oracle the doc treats it as.** Two problems, both visible
in Bambuddy's own source:

- **It is deliberately one-shot for a reason.** `_on_connect` (`bambu_mqtt.py:~789`): *"The probe
  (ams_filament_setting to ext slot) can destabilize some firmware MQTT brokers, causing a reconnect →
  probe → disconnect feedback loop (#887). Only probe once when developer_mode is truly unknown."* It is
  additionally gated on a >30-key pushall and a 5-second post-connect delay. Phase 0 item 2 proposes
  giving `.unknown` "a lifetime" — i.e. re-probing — which is precisely the behaviour upstream
  engineered against. If you want that, say so and own the #887 risk explicitly.
- **Its classifier is over-permissive.** `_handle_dev_mode_probe_response`: anything that is not
  (`result == "failed"` **and** `"verify failed" in reason`) sets `developer_mode = True`. An unrelated
  failure — bad parameter, wrong slot, firmware quirk — is read as "commands are accepted." That is a
  predicate answering a nearby question, the exact pattern CLAUDE.md's table is about. The doc quotes
  that rule at the firmware and then recommends preferring the predicate that breaks it.

**2.3 — Bambuddy already ships a developer-mode capability endpoint, and neither app nor document knows
it exists.** `GET /api/v1/printers/developer-mode-warnings` returns, live, right now:

```json
[{"printer_id": 2, "name": "H2C"}]
```

Grepping the repo: no `.swift`, `.ts` or `.tsx` outside tests references it; both apps read
`developer_mode` from REST status only (`native/Sprout/Api/Models.swift:192`,
`mobile/src/api/types.ts:116`). This is a second, server-authored signal that already answers "does
this printer need Developer Mode?" as a first-class question rather than as a bitfield inference. It
does not replace the flag and it has its own provenance question — but the brief's "check whether
Bambuddy already exposes an endpoint for part of this" turns up a hit that §5 misses, and §5 is the
section whose job that was.

---

### 3. The spike plan measures the wrong half

**3.1 — Spike 1a tests the nine assumed-blocked actions and none of the assumed-*working* ones. That is
backwards on both cost and consequence.** `LanMode.swift` exempts `.stop`, `.light` and `.camera` with
comments, not measurements:

- **`.stop` is the dangerous one.** Bambuddy sends `{"print": {"command": "stop", "sequence_id": "0"}}`
  (`bambu_mqtt.py:3838`) — same `print.*` namespace, same `device/<SERIAL>/request` topic, same
  verification path as `print.pause`. The code's justification for exempting it is a *safety* argument
  ("a Stop that might fail is strictly better than one that cannot be pressed") and I agree with the
  argument. But it is an argument about **what to render**, not evidence about **what the printer
  does**. If `stop` is refused, this app currently renders a full-brightness emergency stop that
  silently does nothing on a print that is failing — the highest-consequence instance of the exact bug
  the subsystem exists to prevent, and the one case where the honest answer ("this may not work — cut
  power at the plug") is materially different from the dishonest one. §1's own quote of Bambuddy's
  probe semantics gives no reason to think `stop` is special.
- **`.light`** is exempted because it "publishes system/ledctrl, which the firmware does not verify the
  same way." I can confirm the payload (`system.ledctrl`, `bambu_mqtt.py:4841`). I can find **no source
  anywhere** for the claim that the firmware verifies `system.*` differently from `print.*`. Bambu's
  own framing is "critical operations," which is not a namespace. And this is falsifiable **by eye in
  ten seconds** — toggle it and look at the printer.
- Note also that `set_chamber_light`, `stop_print` and `pause_print` all `return True` immediately after
  `publish()`. The belief that light works comes from the same non-checking code path that produced the
  original lie. It is not independent evidence.

**Reorder the plan:** measure the *unblocked* three first. Cheaper (light is free and visual), lower
risk (no `pause`/`resume`/`project_file`), and the only branch with a safety consequence.

**3.2 — Spike 1a won't measure the bytes production sends.** Bambuddy hardcodes `sequence_id: "0"` on
pause, resume, stop, `print_speed`, `ams_control` and `auto_stop_ams_dry`. Spike 1a specifies "a unique
`sequence_id`"; §10 specifies "idempotency by `sequence_id`". Both are correct for a purpose-built
`sprout-cmd`, and both are unavailable on today's Bambuddy — where every pause and every stop share
sequence id `0` and replies cannot be attributed. Worth one line, because a reader could take §10's
idempotency requirement as satisfiable now.

**3.3 — Spike 1b's inference is under-determined, and it is not a read.** Publishing
`{"security": {"command": "app_cert_list"}}` is a **write to the request topic** — the same topic whose
messages this firmware refuses. Only the *effect* is read-only. Consequently "no response at all means
H2C firmware does something else entirely and §6 needs re-researching" does not follow: silence is
equally consistent with (a) the scheme isn't implemented, (b) the request was itself verify-refused, and
(c) unknown commands are dropped without reply. Only a **non-empty `cert_ids` list** is informative;
every other outcome is null. Say that, or the spike will be over-read.

**3.4 — Spike 2 step 1 cannot run as specified.** It routes login through Bambuddy's
`POST /api/v1/cloud/login`, which sits behind the same authorization that makes `/cloud/status` return
403 for the app's key — re-confirmed today. So the spike needs the admin JWT or a cloud-enabled key,
while §10 argues that key **must stay** unauthorized. The resolution is easy (do it out of band as
admin, never via the app's key) but it must be written down, because "the spike goes through Bambuddy's
API" and "the app's key must never see cloud data" are the same near-synonym collision the document
warns about elsewhere.

**3.5 — the cheapest spike in the plan is missing.** §8 says, correctly, "we do not currently know which
cloud, if either, this printer is bound to," and then routes that answer through Spike 2 — which costs
the owner's Bambu credentials, a 2FA dance, and a Cloudflare fight. But if the printer is in **LAN Only
Mode**, the whole cloud branch is dead and nobody needs to type a password. That is answerable with zero
credentials and zero cloud contact: the printer's own LCD states it; `GET /api/v1/printers/2/status`
carries `wired_network`, `wifi_signal`, `ipcam`, `sdcard`; and Bambuddy retains the full
`state.raw_data` blob. **Make that Spike 0.** §8's decision consequence 3 ("if not cloud-bound at all,
the entire branch is moot") deserves the cheapest possible test, not the most expensive one.

**3.6 — "run every printer-touching step while the printer is idle" is a sentence, not a gate.** The
printer was `RUNNING` at 16% when I re-probed today, as it was when this was written. Spike 1a includes
`print.pause`, `print.resume` and `print.project_file`. Put `state != RUNNING` in the script as a hard
precondition.

---

### 4. §6 draws a line the evidence does not support

**4.1 — the certificate path's single source has never been shown to work.** bambu-mcp's
`cloud-api-reference.md` describes itself as *reverse-engineered from Bambu Handy v3.x* by jadx APK
decompilation plus Dio interceptor logs. There is **no evidence in it that the author ever called the
cert endpoint successfully** — the endpoint is an observed/inferred URL shape, not a tested call. §6
hedges well ("assume this fails", "do not put it on a roadmap") and I would keep that hedging. But §9
then makes the entire Phase 1 architecture conditional on Spike 3 succeeding, and the decision-gate row
"3 produces a working enrolment → build `sprout-cmd`" gives that outcome the same table weight as the
others. On the evidence it is far and away the least likely row in the table.

**4.2 — "legitimate account-derived enrolment" and "impersonating an official client" are probably the
same act.** §6's own quoted source says *"the app token and AES payload are generated client-side."*
Client-side means inside Handy. There is no published `appToken` derivation and no published AES key;
obtaining either means extracting client secrets from the official application — which is the thing the
second half of §6 correctly refuses. So the bright line between §6's two halves is likely not a line at
all: the "clean" path's *first step* is the "dirty" path's method. §6 presents Spike 3 as an open
legitimacy question. It should present it as: *the only known way to formulate this request is to
extract client credentials from Handy, which we have already ruled out; the spike exists solely to
confirm that and close the branch.* That is a materially different instruction to whoever runs it.

**4.3 — "There is no published rule that settles the certificate-enrolment path either way" is not
right.** Bambu has published a position on third-party access, and this document does not engage with
it. Their wiki's *Third-party Integration* page and the *Updates and Third-Party Integration with Bambu
Connect* blog post direct third-party software to **Bambu Connect** and the
`bambu-connect://import-file?path=…&name=…&version=…` URL scheme, with the stated rationale that it lets
everyone interact with printers **without requiring "complex verification or certification"** — and
Bambu extended that invitation to OrcaSlicer's developers along with a new network plugin. That is a
published answer to §6's question, and the answer is *no, third parties do not get certificates; they
get Connect.* The doc mentions Bambu Connect exactly once, in §7, as the thing that replaced the network
plugin, and never evaluates it.

To be clear, I am **not** proposing Bambu Connect: it is a desktop GUI app, so it cannot serve a
headless home server or an iPhone, and its file-import scheme addresses only `startPrint` — not pause,
speed, AMS or drying. Those are good reasons to reject it. They are also reasons the document should
state, because "we evaluated the official path and it doesn't fit our topology" is a much stronger
position than "there is no published rule." As a bonus, this is a *second* independent argument that
§4's `project_file` conclusion is right: Bambu's sanctioned print-start path for third parties is
explicitly not MQTT.

---

### 5. Things treated as safer or more valuable than they are

**5.1 — the coexistence claim is generalised off-model and off-firmware, and it is exactly the bug
CLAUDE.md describes.** §5: *"Phase 0 already proved a second MQTT client can coexist with Bambuddy
against the same printer with no telemetry flap (`docs/phase0-results.md` §5) — so a sidecar that
publishes signed commands would not have to displace Bambuddy's connection."* What Phase 0 §5 actually
proved: **Bambuddy + ha-bambulab, on the A1, firmware `01.08.00.00`.** Three gaps:

- **Different machine.** The target is an H2C on `01.02.00.00`. The A1 is not even registered in
  Bambuddy any more — `GET /api/v1/printers/` returns only id 2. `docs/phase0-results.md` is stale on
  this point and should carry a note.
- **Known to be firmware-dependent, by that same document.** Phase 0 §1: *"The old single-MQTT-client
  reports were firmware `01.04`; they do not apply here."* The Phase 0 author explicitly flagged
  coexistence as firmware-scoped. Generalising it across a model boundary and six major firmware
  versions discards their own caveat.
- **Contradicted by Bambuddy's source.** #887 is a report of extra publishes destabilising a firmware
  broker into a reconnect loop.

"Phase 0 proved coexistence is safe" → "Phase 0 observed coexistence on a different printer on
different firmware; it must be re-established on the H2C before a second publisher is introduced."

**5.2 — §9's diagram promises what §4 says is impossible.** The architecture diagram labels the
`sprout-cmd` path **"[the 9 actions]"**. §4's own table says `startPrint` / `printAgain` are "Probably
still no" *even with a valid signing identity* — a conclusion I think is correct and well-supported,
since bambu-mcp signs **every** command and still reports `project_file` as needing Developer Mode. So
the best possible outcome of the full Phase 1 build is **7 of 9**, missing precisely the two that the
app's primary loop (slice on the server → print) depends on. That belongs in the verdict at the top,
not in a table cell 200 lines above a diagram that contradicts it. It also reframes the whole
cost/benefit: a multi-week sidecar, a quarterly 2FA ceremony and a new credential store, to restore
pause/resume/speed/AMS/dry — while the app still cannot start a print.

**5.3 — every protocol detail in §3 comes from a different printer generation, and §4 only flags half of
it.** The signed-command example is from **Handy v3.x against a P1S**. bambu-mcp supports
P1P/P1S/X1C/A1/A1 Mini — **no H2 series**. The `fun`-field observation is A1. §4 correctly flags the
model gap against bambu-mcp's *capability* claim, but the same gap applies to the **wire format** in
§3: `sign_ver: "v1.0"`, the header field set, the `payload_len` semantics and the `CN=<SERIAL>` cert_id
convention are all unverified on H2 firmware. Bambuddy itself carries H2C-specific divergence in this
area (`bambu_mqtt.py:~3633`, *"project_file for H2C rack-swap (O1C2) (#1780)"*), which is direct
evidence that this model's command surface is not the P1S's. §3 should carry the same caveat §4 does.

**5.4 — the physical-risk paragraph understates the realistic failure mode.** §10 says a signing bug
"produces refusals, not wrong commands — the failure mode is inert," and names retry loops as the real
hazard. Both true. The one missing: an extra publisher that destabilises the broker (#887) does not
produce an inert refusal — it can drop **Bambuddy's** session, which takes out status, the Live
Activity, and the camera mid-print. That is the plausible bad day here, and it applies to Spike 1a and
Spike 1b as much as to `sprout-cmd`.

**5.5 — the credential blast radius is bigger than "compromise of the home server."** That host also
runs the cloudflared tunnel publishing Bambuddy to the public internet, gated only by Bambuddy's own
auth (`docs/phase0-results.md` §6). And per 1.2 it already stores two cloud credential sets. A third
store on a publicly-reachable host is a different sentence from "compromise of the home server would
expose it."

---

### 6. The buried lede

§10's last paragraph — *"if the owner does not actually use Handy or remote monitoring, that price is
close to zero and this entire document is an expensive way to avoid a settings toggle"* — is the most
important sentence in the document and it is in position 6 of 6 in the last section. It is a
**one-question decision gate with zero cost**: *does the owner use Handy, remote monitoring, or
MakerWorld send-to-printer on this machine?* If no, §§2–6 and §9 are moot before anyone opens a
terminal.

Two additions before that gate can be trusted:

1. **Verify it for a CN-market H2C.** "Developer Mode is a supported, documented, one-time action" is
   sourced from ha-bambulab and Bambu's general docs. This document's own §8 cites a region-lock thread
   for China machines. Whether LAN Only + Developer Mode is available, and what it costs, on a
   China-region H2C on `01.02.00.00` is not established anywhere above. That is Spike 0's second
   question, and it is free.
2. **Note the coupling.** Enabling Developer Mode issues a **new access code**, which must be re-entered
   in Bambuddy (the app never sees it — the code lives only in Bambuddy per `docs/phase0-results.md` §2).
   Cheap, but it is a step, and it is the kind of thing that turns "one toggle" into an evening.

### 7. Recommended edits, in order

1. Move the Developer Mode comparison (§10 last paragraph) above the verdict, with the CN-H2C caveat.
2. Add **Spike 0** (free, no credentials): is the printer cloud-bound or LAN-only, and is Developer Mode
   even offered on this firmware/region? It can kill the entire branch before Spike 2 costs anyone a
   password.
3. Reorder Spike 1a to measure `.light`, `.stop`, `.camera` **first**. Treat a refused `stop` as a
   safety finding, not a capability finding.
4. Fix 1.1 (read-only), 1.2 (missing paths incl. `orca-cloud`), 1.3 (coelacant1), 1.4 (per-row
   citations), 1.5 (restore #1851's cloud-mode scoping).
5. Rewrite Phase 0 item 2: it is a Bambuddy change (provenance on `developer_mode`), not an app change,
   and it must not reintroduce repeat probing without owning #887.
6. Add `GET /api/v1/printers/developer-mode-warnings` to §5 and to Phase 0.
7. Restate §5's coexistence claim as scoped to the A1 on `01.08.00.00`, and make re-establishing it on
   the H2C a precondition of any second publisher — including the spikes.
8. Fix §9's diagram to read "[7 of the 9 actions — not startPrint/printAgain]", and say so in the
   verdict.
9. Rewrite §6's framing per 4.2 and 4.3: Spike 3 is a confirm-and-close exercise, not an open
   legitimacy question, and Bambu's published third-party position should be cited and dismissed on
   topology grounds rather than described as absent.
10. Extend §3's P1S/Handy-v3.x caveat to the wire format itself, citing the H2C `project_file`
    divergence already in Bambuddy.

### Sources added by this review

- [Bambu Lab Wiki — Third-party Integration](https://wiki.bambulab.com/en/software/third-party-integration)
- [Bambu Lab — Updates and Third-Party Integration with Bambu Connect](https://blog.bambulab.com/updates-and-third-party-integration-with-bambu-connect/)
- [coelacant1 — `API_FILES_PRINTING.md`](https://github.com/coelacant1/Bambu-Lab-Cloud-API/blob/main/API_FILES_PRINTING.md)
- [greghesp/ha-bambulab#1851 — comments of 2026-01-23](https://github.com/greghesp/ha-bambulab/issues/1851) (the full maintainer comment, incl. the cloud-mode scoping)
- Bambuddy `backend/app/services/bambu_mqtt.py` (`:789`, `:1047`, `:3125–3145`, `:3422–3490`, `:3633`, `:3744`, `:3838`, `:4160`, `:4587`, `:4760`, `:4822`, `:4981`, `:5075`, `:5697`) and `bambu_cloud.py` (`:23`, `:262–264`, `:307–342`, `:352`, `:450`, `:535`, `:564`, `:587`), read from the running container 2026-08-10
- Live probes 2026-08-10: `GET /api/v1/printers/`, `GET /api/v1/printers/2/status`,
  `GET /api/v1/printers/developer-mode-warnings`, `GET /api/v1/cloud/status` (403), `openapi.json`
  (548 paths / 685 operations), `BambuStudio-02.07.01.57 --help` in the `bambu-studio-api` sidecar

---

## Spike 1 results (run 2026-08-10, read-only, no account)

Ran the cheapest kill-switch first — probe the printer's `security` subsystem over the EXISTING LAN
MQTT connection, using only the access code Bambuddy already holds. No Bambu account credentials
were involved at any point. Scripts: `deploy/spikes/cert_*.py`. All read-only (they publish query
commands and a `pushall`, which Bambuddy already does continuously; a second MQTT client coexists
fine, as Phase 0 established).

**Findings, in order:**

1. **`pushall` does not surface any security block.** 395 distinct key paths, all under `print.*`.
   The trusted-cert list is not in the standard report. (Two apparent matches — `design_id`,
   `wifi_signal` — were substring false positives on "sign".)

2. **The printer DOES have a `security` subsystem and answers `security.app_cert_list`.** It also
   recognises `security.get_app_cert_list`, `security.get_cert_list`, `info.get_accessory` and
   `system.get_access_code` — every command was echoed back, so the firmware knows them.

3. **But `security.app_cert_list` returns `{"result": "FAIL"}`** — no `reason`, no list — to a plain
   authenticated LAN client.

**Interpretation.** The subsystem the certificate-enrolment idea depends on exists, which is more
than the design assumed. But it will not hand its trusted-cert list to an ordinary LAN client. The
`FAIL` has no reason code, so it is ambiguous between (a) the request is missing required parameters
whose shape we do not have a source for, and (b) the command itself requires an
already-trusted/signed identity to issue — which would be circular: you would need the signing cert
in order to ask which certs are trusted.

**Verdict.** The cheap reads are exhausted and lean negative. Distinguishing (a) from (b) means
guessing the undocumented payload shape or reversing the official app — exactly the low-certainty
work the "one path that could actually work" section said to *assume fails until a spike says
otherwise*. This spike did not say otherwise. **Recommendation stands: do not build a cloud/cert
transport.** The pragmatic fork is unchanged — accept the limits with the honest UI the app already
has, or enable LAN Developer Mode (new access code, re-entered once; loses Handy).
