#!/usr/bin/env bash
# Deploy (or update) PerfectCRM on the VPS. Run in /opt/apps/perfectcrm.
# Pulls the CI-built image, applies migrations via the entrypoint db:prepare,
# restarts services, and prunes superseded images. Deliberate only, never automatic.
# The system Caddy in /opt/apps/caddy is separate and keeps routing to this app.
set -euo pipefail

cd "$(dirname "$0")"

docker compose -f compose.yml pull
docker compose -f compose.yml up -d
docker image prune -f

docker compose -f compose.yml ps
