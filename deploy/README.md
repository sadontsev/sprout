# Deploy (<your-server>)

Both stacks run on <your-server> via Docker Compose, copied to `<deploy-dir>/bambuddy/`
and `<deploy-dir>/slicer-api/`. Tailnet-only; never exposed via cloudflared.

## Slicer

    cd <deploy-dir>/slicer-api && docker compose --profile bambu up -d

## Bambuddy

    cd <deploy-dir>/bambuddy && docker compose up -d

After deploy: set `preferred_slicer = bambu_studio` and slicer URL
`http://localhost:3001` in Bambuddy Settings → Slicer. Front with
`tailscale serve --bg 8000`.

## Support profiles (enables the app's "Supports" toggle)

The app's API key can't create slicer presets (admin-only), and the slice API has no per-setting
override — so to slice *with supports* the app needs a support-enabled **process profile** to exist.
`ensure-support-profiles.py` creates a `+ Supports` twin of each A1 quality profile (idempotent —
inherits the standard profile, just turns `enable_support` on). The app's Material step then shows a
**Supports** toggle that picks the twin. Run it once, and again after any Bambuddy update:

    BB_ADMIN_USER=<admin-user> BB_ADMIN_PW="$(cat <secrets-dir>/bb_admin_pw)" \
      BAMBUDDY_URL=http://localhost:8000 python3 ensure-support-profiles.py

(From a non-<your-server> host it defaults to `https://bambuddy.example.com` and prompts for the password; it
sends a browser UA so Cloudflare doesn't 1010-block it.) Verified end-to-end: a slice with the twin
yields `enable_support = 1` + real `FEATURE: Support` toolpath, with the base settings inherited.

## Update

Bump `BAMBUDDY_TAG` / `SIDECAR_TAG` in `.env`, then `docker compose pull && up -d`.
**Then re-run `ensure-support-profiles.py`** (above) — it's idempotent, so it only recreates twins that
a fresh volume would be missing.
