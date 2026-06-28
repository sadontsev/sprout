# Deploy (homeserver.local)

Both stacks run on homeserver via Docker Compose, copied to `~/docker/bambuddy/`
and `~/docker/slicer-api/`. Tailnet-only; never exposed via cloudflared.

## Slicer

    cd ~/docker/slicer-api && docker compose --profile bambu up -d

## Bambuddy

    cd ~/docker/bambuddy && docker compose up -d

After deploy: set `preferred_slicer = bambu_studio` and slicer URL
`http://localhost:3001` in Bambuddy Settings → Slicer. Front with
`tailscale serve --bg 8000`.

## Update

Bump `BAMBUDDY_TAG` / `SIDECAR_TAG` in `.env`, then `docker compose pull && up -d`.
