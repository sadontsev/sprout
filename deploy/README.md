# Deploy (<your-server>)

Both stacks run on <your-server> via Docker Compose, copied to `<deploy-dir>/bambuddy/`
and `<deploy-dir>/slicer-api/`. Tailnet-only; never exposed via cloudflared.

For push notifications / Live Activities — and for the native app's MakerWorld **collections** —
also deploy `la-push`: [deploy/la-push/README.md](la-push/README.md) for the service,
[docs/guides/push-notifications.md](../docs/guides/push-notifications.md) for the APNs walkthrough.

## Slicer

    cd <deploy-dir>/slicer-api && docker compose --profile bambu up -d

(The slicer's compose uses `${VAR:-default}` throughout, so it starts without a `.env`.)

## Bambuddy

    cd <deploy-dir>/bambuddy
    cp .env.example .env          # then set JWT_SECRET_KEY=$(openssl rand -hex 32)
    docker compose up -d

`JWT_SECRET_KEY` uses compose's fail-hard `${VAR:?}` form, so a missing or blank one aborts before
anything starts. `PORT` defaults to **8910** (8000 is usually taken).

After deploy: set `preferred_slicer = bambu_studio` and slicer URL
`http://localhost:3001` in Bambuddy Settings → Slicer. Front with
`tailscale serve --bg 8910` — the bare port is the proxy TARGET, so 8000 would serve whatever
else is on that port.

## Register the printer + mint the app's API key

1. Open Bambuddy's web UI → add the printer (LAN IP + access code from the printer's
   screen; give it a DHCP reservation — a lease change silently strands Bambuddy on the
   old IP and everything reads "offline").
2. Settings → enable authentication, set the admin password.
3. Settings → API keys → create a **scoped key** (`bb_…`) for the app: status, control,
   queue, and library scopes. This key + your Bambuddy URL are all the app's onboarding
   asks for. **Never commit it anywhere** — including test fixtures.

## Support profiles (enables the app's "Supports" toggle)

The app's API key can't create slicer presets (admin-only), and the slice API has no per-setting
override — so to slice *with supports* the app needs a support-enabled **process profile** to exist.
`ensure-support-profiles.py` creates a `+ Supports` twin of each A1 quality profile (idempotent —
inherits the standard profile, just turns `enable_support` on). The app's Material step then shows a
**Supports** toggle that picks the twin. Run it once, and again after any Bambuddy update:

    BB_ADMIN_USER=<admin-user> BB_ADMIN_PW="$(cat <secrets-dir>/bb_admin_pw)" \
      BAMBUDDY_URL=http://localhost:8910 python3 ensure-support-profiles.py

(From a non-<your-server> host it defaults to `https://bambuddy.example.com` and prompts for the password; it
sends a browser UA so Cloudflare doesn't 1010-block it.) Verified end-to-end: a slice with the twin
yields `enable_support = 1` + real `FEATURE: Support` toolpath, with the base settings inherited.

## Update

Bump `BAMBUDDY_TAG` / `SIDECAR_TAG` in `.env`, then `docker compose pull && up -d`.
**Then re-run `ensure-support-profiles.py`** (above) — it's idempotent, so it only recreates twins that
a fresh volume would be missing.
