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

## Update

Bump `BAMBUDDY_TAG` / `SIDECAR_TAG` in `.env`, then `docker compose pull && up -d`.
