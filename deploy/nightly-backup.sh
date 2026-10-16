#!/usr/bin/env bash
# Nightly second-line backup. Scope, retention, cron setup, and prerequisites:
# docs/operations.md, "Nightly backup".
set -euo pipefail

cd "$(dirname "$0")"

: "${BACKUP_RCLONE_REMOTE:?Set BACKUP_RCLONE_REMOTE to the rclone S3 remote}"
: "${LITESTREAM_BUCKET:?Set LITESTREAM_BUCKET}"

IMAGE="ghcr.io/samsherpadev/perfectcrm:${IMAGE_TAG:-latest}"
STAMP="$(date -u +%Y-%m-%d)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for DB in production.sqlite3 production_queue.sqlite3; do
  NAME="${DB%.sqlite3}"
  docker run --rm --user 0:0 \
    -v perfectcrm_storage:/rails/storage:ro \
    -v "$TMPDIR:/out" \
    "$IMAGE" sqlite3 "/rails/storage/$DB" ".backup '/out/$NAME-$STAMP.sqlite3'"
  gzip -f "$TMPDIR/$NAME-$STAMP.sqlite3"
  rclone copyto "$TMPDIR/$NAME-$STAMP.sqlite3.gz" \
    "$BACKUP_RCLONE_REMOTE:$LITESTREAM_BUCKET/nightly/perfectcrm/$NAME-$STAMP.sqlite3.gz"
done

# Retain 30 days of nightlies.
rclone delete --min-age 30d "$BACKUP_RCLONE_REMOTE:$LITESTREAM_BUCKET/nightly/perfectcrm/"

if [ -n "${HEALTHCHECKS_URL:-}" ]; then
  curl --fail --silent --show-error --max-time 30 "$HEALTHCHECKS_URL"
else
  printf '%s\n' 'WARNING: HEALTHCHECKS_URL is unset; backup completed without a healthchecks ping.' >&2
fi
