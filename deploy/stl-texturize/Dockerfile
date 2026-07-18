# stl-texturize sidecar. Node service that vendors CNCKitchen/stlTexturizer (AGPL-3.0) at a PINNED
# commit and runs its export pipeline headless. The AGPL code lives ONLY in this image's ./vendor —
# it is never committed to the app repo, linked into Bambuddy, or bundled into the app. See README.
FROM node:24-slim

# libvips is bundled with sharp's prebuilt binaries; curl/tar for the pinned-source fetch.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates tar \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ---- vendor the texturizer at a pinned SHA (no releases/tags exist; the API is not stable) ----
ARG TEXTURIZER_SHA=80b471c1029046cdec684495611dcd4aa6744933
RUN mkdir -p vendor textures \
 && curl -fsSL "https://github.com/CNCKitchen/stlTexturizer/archive/${TEXTURIZER_SHA}.tar.gz" -o /tmp/src.tgz \
 && tar xz --strip-components=1 -C vendor -f /tmp/src.tgz \
 && rm /tmp/src.tgz \
 # Best-effort seed of the bundled texture set (custom uploads work regardless; ./textures is also a
 # mounted volume you can drop images into without rebuilding).
 && (cp -r vendor/textures/* textures/ 2>/dev/null || true)

# ---- our deps + code ----
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY *.mjs ./

EXPOSE 8912
CMD ["node", "--max-old-space-size=4096", "server.mjs"]
