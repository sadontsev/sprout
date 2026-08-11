#!/usr/bin/env bash
# Deploy Canopy to the host that runs it.
#
# This exists because `rsync -a --delete` to <deploy-dir>/canopy is a loaded gun. The excludes are
# anchored with a leading slash, which in rsync means "relative to the TRANSFER ROOT" — here that is
# this directory, so the live data directory is `/data`, NOT `/canopy/data`. Getting that wrong
# deletes the SQLite database holding every binding and attest key, and those are the one piece of
# Canopy's state a client cannot reconstruct on demand: a device cannot re-attest because a server
# lost its key. It also deletes `.env`, which is not in git.
#
# It has been gotten wrong. Recovery was possible only because the container was still running and
# still held the deleted inodes open (/proc/<pid>/fd). Do not rely on that a second time.
set -euo pipefail

HOST="${CANOPY_HOST:-gem}"
DEST="${CANOPY_DEST:-\$HOME/docker/canopy}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

remote() { ssh "$HOST" "$@"; }

echo "==> ensuring the data directory exists and is owned by the deploying user"
# Docker creates a MISSING bind source as root, and the container (which runs as the deploying
# user) then cannot create its SQLite file: it exits and restart:unless-stopped loops it. Creating
# it here, before compose ever sees it, is what keeps a first deploy from crash-looping.
remote "mkdir -p \$HOME/docker/canopy/data
  cd \$HOME/docker/canopy
  grep -q '^CANOPY_UID=' .env 2>/dev/null || printf 'CANOPY_UID=%s\nCANOPY_GID=%s\n' \$(id -u) \$(id -g) >> .env"

echo "==> backing up live state on $HOST first"
remote "set -e
  cd \$HOME/docker/canopy
  mkdir -p \$HOME/backups/canopy
  stamp=\$(date +%Y%m%d-%H%M%S)
  if [ -f data/canopy.db ]; then
    # SQLite is in WAL mode, so the .db file alone is usually one page and the rows live in the
    # -wal. .backup takes a consistent copy of both without stopping the container.
    python3 -c \"
import sqlite3, sys
src = sqlite3.connect('data/canopy.db')
dst = sqlite3.connect(sys.argv[1])
src.backup(dst)
dst.close(); src.close()
\" \$HOME/backups/canopy/canopy.db.\$stamp
    echo \"    db  -> \$HOME/backups/canopy/canopy.db.\$stamp\"
  fi
  [ -f .env ] && cp .env \$HOME/backups/canopy/env.\$stamp && echo \"    env -> \$HOME/backups/canopy/env.\$stamp\"
  true"

echo "==> syncing source"
# --exclude paths are anchored to THIS directory. /data and /.env are the two that must never be
# deleted; both are absent from git, so without these excludes --delete removes them.
rsync -az --delete \
  --exclude='/data' \
  --exclude='/.env' \
  --exclude='/.git' \
  --exclude='/canopy.db' \
  "$HERE/" "$HOST:\$HOME/docker/canopy/"

echo "==> rebuilding"
remote "cd \$HOME/docker/canopy && docker compose up -d --build" >/dev/null

echo "==> verifying"
sleep 3
remote "docker logs canopy --tail 5"
remote "curl -fsS http://127.0.0.1:8914/v1/health" && echo
# A binding count of zero after a deploy that previously had bindings means the data directory was
# lost. Print it every time so that is noticed now rather than when a push silently stops arriving.
remote "python3 -c \"
import sqlite3
c = sqlite3.connect('\$HOME/docker/canopy/data/canopy.db')
print('bindings:', c.execute('SELECT count(*) FROM bindings').fetchone()[0],
      '| attest keys:', c.execute('SELECT count(*) FROM attest_keys').fetchone()[0])
\""
echo "==> done"
