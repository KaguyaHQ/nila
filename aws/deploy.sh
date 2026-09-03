#!/bin/bash
set -euo pipefail

cd /opt/nila

echo "==> Pulling images..."
docker compose --env-file .stack.env pull

echo "==> Running migrations..."
docker compose --env-file .stack.env run --rm nila /app/bin/migrate

echo "==> Starting services..."
docker compose --env-file .stack.env up -d --remove-orphans

echo "==> Waiting for Nila health..."
for attempt in $(seq 1 18); do
  if docker compose --env-file .stack.env exec -T nila \
    curl -sf -H "X-Forwarded-Proto: https" http://127.0.0.1:8080/health | grep -q healthy; then
    docker compose --env-file .stack.env ps
    docker image prune -f
    echo "==> Deploy complete."
    exit 0
  fi

  sleep 5
done

docker compose --env-file .stack.env ps
docker compose --env-file .stack.env logs nila --tail=100
echo "Nila did not become healthy" >&2
exit 1
