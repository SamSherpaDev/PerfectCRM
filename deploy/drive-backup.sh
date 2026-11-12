#!/usr/bin/env bash
# Daily encrypted Google Drive backup. Setup, layout, retention, and restore:
# docs/operations.md, "Drive backup".
set -euo pipefail

cd "$(dirname "$0")"

APP=perfectcrm
REMOTE=sherpa-backup
IMAGE="ghcr.io/samsherpadev/perfectcrm:${IMAGE_TAG:-latest}"
STAMP="$(date -u +%Y-%m-%d)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

for TARGET in daily monthly; do
  # A daily copy is due once per day; a monthly copy on the month's first run.
  case "$TARGET" in
    daily) PERIOD="$STAMP" DAY='' ;;
    monthly) PERIOD="${STAMP:0:7}" DAY='-[0-9]{2}' ;;
  esac
  DEST="$REMOTE:$APP/$TARGET"
  STAGE="$TMPDIR/stage-$TARGET"
  mkdir "$STAGE"
  rclone mkdir "$DEST"
  EXISTING="$(rclone lsf --files-only "$DEST")"
  for NAME in production production_queue; do
    # A copy already on Drive for this period stays untouched.
    if grep -qE -- "^$NAME-$PERIOD$DAY\.sqlite3\.gz\$" <<<"$EXISTING"; then
      echo "$TARGET already holds a $NAME copy for $PERIOD; left untouched."
      continue
    fi
    snapshot "$NAME"
    cp "$TMPDIR/$NAME-$STAMP.sqlite3.gz" "$STAGE/"
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
rclone delete --min-age 365d "$REMOTE:$APP/monthly"
echo "Drive backup complete for $STAMP."
