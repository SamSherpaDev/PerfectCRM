#!/usr/bin/env bash
# Nightly second-line backup: sqlite3 .backup of both databases, gzip, rclone
# to the backup bucket under nightly/, prune older than 30 days, ping healthchecks.
# Cron on the VPS (root): 0 3 * * * /opt/apps/perfectcrm/nightly-backup.sh
# Requires: BACKUP_RCLONE_REMOTE (e.g. "s3-backup", an rclone S3 remote for the
# backup bucket; see docs/operations.md), LITESTREAM_BUCKET, HEALTHCHECKS_URL.
# Run from /opt/apps/perfectcrm.
set -euo pipefail

cd "$(dirname "$0")"

: "${BACKUP_RCLONE_REMOTE:?Set BACKUP_RCLONE_REMOTE to the rclone S3 remote}"
: "${LITESTREAM_BUCKET:?Set LITESTREAM_BUCKET}"
: "${HEALTHCHECKS_URL:?Set HEALTHCHECKS_URL}"

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
    "$BACKUP_RCLONE_REMOTE:$LITESTREAM_BUCKET/nightly/$NAME-$STAMP.sqlite3.gz"
done

# Retain 30 days of nightlies.
rclone delete --min-age 30d "$BACKUP_RCLONE_REMOTE:$LITESTREAM_BUCKET/nightly/"

curl --fail --silent --show-error --max-time 30 "$HEALTHCHECKS_URL"
