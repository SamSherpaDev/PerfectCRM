#!/usr/bin/env bash
# Hourly encrypted Google Drive mirror of ordinary CRM email attachments.
# The app's database allowlist (bin/rails backup:attachment_manifest) alone
# decides what may be copied; held identity documents never qualify, and a
# copy whose key leaves the allowlist is permanently deleted on the next run.
# Setup, access choice, retention, and restore: docs/operations.md,
# "Attachments backup".
set -euo pipefail

cd "$(dirname "$0")"
export LC_ALL=C

DEST=sherpa-backup:perfectcrm/attachments
KEY_FORMAT='^[0-9a-z]{28}$'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "Attachments backup FAILED: $*" >&2
  exit 1
}

# One KEY=value line of .env.app, read as data and never sourced, so the
# app's other secrets stay out of this job's environment.
app_setting() {
  local line value
  line="$(grep -E "^$1=" .env.app | tail -n 1 || true)"
  value="${line#*=}"
  value="${value%$'\r'}"
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  [ -n "$value" ] || fail ".env.app has no $1."
  printf '%s' "$value"
}

# How this job reads the attachments bucket; the owner picks one.
case "${ATTACHMENTS_ACCESS:-}" in
  remote)
    # A dedicated perfectcrm-attachments remote in root's rclone
    # configuration, created with a read-only token for this one bucket.
    [ -n "${ATTACHMENTS_BUCKET:-}" ] || fail "set ATTACHMENTS_BUCKET in .env.nightly-backup."
    SRC="perfectcrm-attachments:$ATTACHMENTS_BUCKET"
    ;;
  app-keys)
    # The app's own read-write attachment keys from .env.app, as
    # deploy/bucket-smoke.sh uses them, held only in rclone's environment.
    [ -r .env.app ] || fail "app-keys access needs .env.app beside this script."
    endpoint="$(app_setting SPACES_ENDPOINT)"
    region="$(app_setting SPACES_REGION)"
    bucket="$(app_setting SPACES_BUCKET)"
    key_id="$(app_setting SPACES_ACCESS_KEY_ID)"
    secret="$(app_setting SPACES_SECRET_ACCESS_KEY)"
    export RCLONE_CONFIG_APPKEYS_TYPE=s3 RCLONE_CONFIG_APPKEYS_PROVIDER=Other
    export RCLONE_CONFIG_APPKEYS_ENDPOINT="$endpoint" RCLONE_CONFIG_APPKEYS_REGION="$region"
    export RCLONE_CONFIG_APPKEYS_ACCESS_KEY_ID="$key_id" RCLONE_CONFIG_APPKEYS_SECRET_ACCESS_KEY="$secret"
    unset key_id secret
    SRC="appkeys:$bucket"
    ;;
  *)
    fail "set ATTACHMENTS_ACCESS to remote or app-keys in .env.nightly-backup."
    ;;
esac

# The allowlist: an exact header, N keys in Active Storage's format, then
# "end N". Production logs share STDOUT, so anything else fails the run
# before any Drive call.
RAW="$WORK/manifest.raw"
ALLOW="$WORK/allow"
docker exec -e RAILS_LOG_LEVEL=error perfectcrm-app bin/rails backup:attachment_manifest > "$RAW" ||
  fail "the app did not print the attachment manifest."
[ "$(head -n 1 "$RAW")" = "perfectcrm-attachment-manifest v1" ] || fail "the manifest header is wrong."
TRAILER="$(tail -n 1 "$RAW")"
[[ "$TRAILER" =~ ^end\ (0|[1-9][0-9]*)$ ]] || fail "the manifest has no end line."
COUNT="${BASH_REMATCH[1]}"
sed '1d;$d' "$RAW" > "$ALLOW"
if grep -qvE "$KEY_FORMAT" "$ALLOW"; then
  fail "the manifest holds a line that is not a key."
fi
sort -o "$ALLOW" "$ALLOW"
if [ "$(wc -l < "$ALLOW")" -ne "$COUNT" ] || [ "$(uniq "$ALLOW" | wc -l)" -ne "$COUNT" ]; then
  fail "the manifest count does not match its keys."
fi

drive_keys() {
  rclone lsf --files-only "$DEST" > "$WORK/listing"
  grep -E "$KEY_FORMAT" "$WORK/listing" | sort -u || true
}
rclone mkdir "$DEST"
drive_keys > "$WORK/drive"

# Deletes first, so a later upload failure never delays a removal. Only the
# database drives deletion: a key missing from the bucket stays on Drive.
comm -13 "$ALLOW" "$WORK/drive" > "$WORK/gone"
comm -23 "$ALLOW" "$WORK/drive" > "$WORK/new"
if [ -s "$WORK/gone" ]; then
  rclone delete --drive-use-trash=false --files-from "$WORK/gone" "$DEST"
fi
if [ -s "$WORK/new" ]; then
  rclone copy --files-from "$WORK/new" --no-traverse --ignore-existing "$SRC" "$DEST"
  # Decrypts what landed on Drive and compares it with the bucket's bytes.
  rclone cryptcheck --one-way --files-from "$WORK/new" "$SRC" "$DEST"
fi

drive_keys > "$WORK/after"
KEPT="$(comm -12 "$ALLOW" "$WORK/drive" | wc -l)"
ADDED="$(comm -12 "$WORK/new" "$WORK/after" | wc -l)"
MISSING="$(comm -23 "$WORK/new" "$WORK/after" | wc -l)"
REMOVED="$(wc -l < "$WORK/gone")"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Attachments backup: kept $((KEPT)), new $((ADDED)), removed $((REMOVED)), not in bucket $((MISSING))."
