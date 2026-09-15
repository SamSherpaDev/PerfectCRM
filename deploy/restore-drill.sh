#!/usr/bin/env bash
# Quarterly restore drill: restore Litestream replica to /tmp, integrity-check
# it, boot a throwaway app container against it on a random port, curl /up.
# Run on the VPS in /opt/apps/perfectcrm.
set -euo pipefail

cd "$(dirname "$0")"

set -a
# shellcheck source=/dev/null
[ -f .env.app ] && . ./.env.app
# shellcheck source=/dev/null
[ -f .env.litestream ] && . ./.env.litestream
set +a

: "${LITESTREAM_BUCKET:?Set LITESTREAM_BUCKET}"
: "${SPACES_ENDPOINT:?Set SPACES_ENDPOINT}"
: "${SPACES_REGION:?Set SPACES_REGION}"

IMAGE="ghcr.io/samsherpadev/perfectcrm:${IMAGE_TAG:-latest}"
WORKDIR="$(mktemp -d)"
CONTAINER="perfectcrm-restore-drill-${WORKDIR##*/}"
CONTAINER_ID=""
cleanup() {
  if [ -n "$CONTAINER_ID" ]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || return
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
PORT="$(shuf -i 20000-39999 -n 1)"

# 1. Restore the primary database to /tmp via the Litestream image.
docker run --rm \
  --env-file .env.litestream \
  -e SPACES_REGION="$SPACES_REGION" \
  -e SPACES_ENDPOINT="$SPACES_ENDPOINT" \
  -v "$WORKDIR:/restore" \
  -v "$PWD/litestream.yml:/etc/litestream.yml:ro" \
  litestream/litestream:0.5.9 \
  restore -o "/restore/production.sqlite3" \
  "s3://$LITESTREAM_BUCKET/perfectcrm/primary"

# 2. Integrity check.
docker run --rm -v "$WORKDIR:/restore" "$IMAGE" \
  sqlite3 /restore/production.sqlite3 "PRAGMA integrity_check;"

# 3. Boot a throwaway app container against the restored file, probe /up.
CONTAINER_ID="$(docker run -d --name "$CONTAINER" \
  --env-file .env.app \
  -e RAILS_ENV=production -e SOLID_QUEUE_IN_PUMA=true \
  -v "$WORKDIR/production.sqlite3:/rails/storage/production.sqlite3:ro" \
  -p "127.0.0.1:$PORT:80" \
  "$IMAGE")"
for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:$PORT/up" >/dev/null; then
    trap - EXIT
    echo "Restored app is healthy; attachment verification is still required."
    echo "Server loopback URL: http://127.0.0.1:$PORT"
    echo "From your laptop: ssh -N -L 18080:127.0.0.1:$PORT root@<server-ip>"
    echo "Follow docs/operations.md for HTTPS and Google sign-in at https://localhost:8443."
    echo "After opening one page, run this cleanup command on the server:"
    printf 'docker rm -f %q && rm -rf -- %q\n' "$CONTAINER_ID" "$WORKDIR"
    exit 0
  fi
  sleep 2
done
echo "Restore drill FAILED: throwaway app never became healthy." >&2
exit 1
