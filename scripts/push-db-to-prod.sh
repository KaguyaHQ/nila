#!/usr/bin/env bash
# Overwrite the PROD database with your LOCAL nila_dev.
#
# PRE-MVP ONLY. This DROPS the prod database and replaces it with a dump of
# your local dev DB. Everything currently in prod is destroyed. There is no
# undo. Do not run this once prod holds real data — use a real migration path.
#
# Local DB is native postgres (homebrew postgresql@17) on localhost:5432.
# Prod DB is the dockerized nila-postgres container on the Hetzner box.
#
# Requires: local postgres running, the `nila-prod` ssh Host alias
# (see hetzner/README.md), and key access already working.
#
# Usage (from repo root):
#   ./scripts/push-db-to-prod.sh
set -euo pipefail

SSH_HOST="nila-prod"
LOCAL_HOST="localhost"
LOCAL_PORT="5432"
LOCAL_USER="postgres"
LOCAL_DB="nila_dev"
PG_DUMP="${PG_DUMP:-/opt/homebrew/opt/postgresql@17/bin/pg_dump}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DUMP="$(mktemp -t nila_local_db.XXXXXX).dump"
REMOTE_DUMP="/tmp/nila_restore_$$.dump"
cleanup() { rm -f "$DUMP"; }
trap cleanup EXIT

echo "WARNING: this OVERWRITES the prod database with local '$LOCAL_DB'."
echo "         All data currently in prod will be permanently destroyed."
read -r -p "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "aborted."; exit 1; }

echo "==> Dumping local DB ($LOCAL_DB) from $LOCAL_HOST:$LOCAL_PORT..."
"$PG_DUMP" -h "$LOCAL_HOST" -p "$LOCAL_PORT" -U "$LOCAL_USER" -d "$LOCAL_DB" \
  --format=custom --no-owner --no-privileges > "$DUMP"
echo "    dump size: $(du -h "$DUMP" | cut -f1)"

echo "==> Copying dump to prod..."
scp -q "$DUMP" "$SSH_HOST:$REMOTE_DUMP"

echo "==> Restoring on prod (drop + recreate + load)..."
ssh "$SSH_HOST" REMOTE_DUMP="$REMOTE_DUMP" bash -s <<'REMOTE'
set -euo pipefail
cd /home/deploy/nila

# Prod DB credentials live only in the server-side .env.
set -a; source .env; set +a
: "${POSTGRES_USER:?missing in prod .env}"
: "${POSTGRES_DB:?missing in prod .env}"

echo "    stopping app container to release DB connections..."
docker compose stop nila

echo "    dropping & recreating $POSTGRES_DB..."
docker compose exec -T nila-postgres \
  psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS $POSTGRES_DB;
CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_USER;
SQL

echo "    restoring dump..."
docker compose exec -T nila-postgres \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --no-owner --no-privileges < "$REMOTE_DUMP"

echo "    restarting app..."
docker compose up -d nila

rm -f "$REMOTE_DUMP"
REMOTE

echo "==> Done. Prod now mirrors local '$LOCAL_DB'."
echo "    Verify: curl -s https://nila.tax/health"
