#!/usr/bin/env bash
# Daily encrypted Google Drive backup. Setup, layout, retention, and restore:
# docs/operations.md, "Drive backup".
set -euo pipefail

cd "$(dirname "$0")"

APP=perfectcrm
REMOTE="${DRIVE_BACKUP_REMOTE:-sherpa-backup}"
IMAGE="ghcr.io/samsherpadev/perfectcrm:${IMAGE_TAG:-latest}"
# DRIVE_BACKUP_DATE exists for tests only; production always uses today (UTC).
STAMP="${DRIVE_BACKUP_DATE:-$(date -u +%Y-%m-%d)}"
if [[ ! "$STAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Drive backup FAILED: date must be YYYY-MM-DD, got: $STAMP" >&2
  exit 1
fi
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

TARGETS=(daily)
if [ "${STAMP:8:2}" = 01 ]; then
  TARGETS+=(monthly)
fi

# One consistent snapshot per database per run, shared by every target.
snapshot() {
  local name="$1"
  [ -f "$TMPDIR/$name-$STAMP.sqlite3.gz" ] && return 0
  docker run --rm --user 0:0 \
    -v perfectcrm_storage:/rails/storage:ro \
    -v "$TMPDIR:/out" \
    "$IMAGE" sqlite3 "/rails/storage/$name.sqlite3" ".backup '/out/$name-$STAMP.sqlite3'"
  gzip -f "$TMPDIR/$name-$STAMP.sqlite3"
}

for TARGET in "${TARGETS[@]}"; do
  DEST="$REMOTE:$APP/$TARGET"
  STAGE="$TMPDIR/stage-$TARGET"
  mkdir "$STAGE"
  rclone mkdir "$DEST"
  EXISTING="$(rclone lsf --files-only "$DEST")"
  for NAME in production production_queue; do
    FILE="$NAME-$STAMP.sqlite3.gz"
    # A same-day rerun keeps the copy already verified on Drive.
    if grep -qxF -- "$FILE" <<<"$EXISTING"; then
      echo "$TARGET/$FILE is already on Drive; left untouched."
      continue
    fi
    snapshot "$NAME"
    cp "$TMPDIR/$FILE" "$STAGE/$FILE"
  done
  if [ -n "$(ls -A "$STAGE")" ]; then
    rclone copy --ignore-existing "$STAGE" "$DEST"
    # Decrypts what landed on Drive and compares it with the local copy.
    rclone cryptcheck --one-way "$STAGE" "$DEST"
    echo "Uploaded and verified $TARGET copies for $STAMP."
  fi
done

# Keep 30 days of daily copies and 12 months of monthly copies.
rclone delete --min-age 30d "$REMOTE:$APP/daily"
if rclone lsf --dirs-only "$REMOTE:$APP" | grep -qxF 'monthly/'; then
  rclone delete --min-age 365d "$REMOTE:$APP/monthly"
fi
echo "Drive backup complete for $STAMP."
