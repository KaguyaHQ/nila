#!/bin/bash
# /home/deploy/nila/deploy.sh
# Called by GitHub Actions after the ops files are scp'd to the server.
set -euo pipefail

cd /home/deploy/nila

echo "==> Pulling latest image..."
docker compose pull nila

echo "==> Running Ecto migrations..."
# `run` starts nila-postgres (depends_on: service_healthy) and waits for it.
docker compose run --rm nila /app/bin/migrate

echo "==> Starting/Restarting services..."
docker compose up -d --remove-orphans

echo "==> Waiting for health..."
sleep 10
docker compose ps

docker image prune -f
echo "==> Deploy complete!"
