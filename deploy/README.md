# Deploy (homeserver.local)

Both stacks run on homeserver via Docker Compose, copied to `~/docker/bambuddy/`
and `~/docker/slicer-api/`. Tailnet-only; never exposed via cloudflared.

For push notifications / Live Activities, also deploy `la-push` — see
[docs/guides/push-notifications.md](../docs/guides/push-notifications.md).

## Slicer

    cd ~/docker/slicer-api && docker compose --profile bambu up -d

## Bambuddy

    cd ~/docker/bambuddy && docker compose up -d

After deploy: set `preferred_slicer = bambu_studio` and slicer URL
`http://localhost:3001` in Bambuddy Settings → Slicer. Front with
`tailscale serve --bg 8000`.

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

    BB_ADMIN_USER=max BB_ADMIN_PW="$(cat ~/.config/bambu-phase0/bb_admin_pw)" \
      BAMBUDDY_URL=http://localhost:8000 python3 ensure-support-profiles.py

(From a non-homeserver host it defaults to `https://bambuddy.example.com` and prompts for the password; it
sends a browser UA so Cloudflare doesn't 1010-block it.) Verified end-to-end: a slice with the twin
yields `enable_support = 1` + real `FEATURE: Support` toolpath, with the base settings inherited.

## Update

Bump `BAMBUDDY_TAG` / `SIDECAR_TAG` in `.env`, then `docker compose pull && up -d`.
**Then re-run `ensure-support-profiles.py`** (above) — it's idempotent, so it only recreates twins that
a fresh volume would be missing.
