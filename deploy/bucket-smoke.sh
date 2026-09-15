#!/usr/bin/env bash
# Smoke-test the S3-compatible bucket credentials: lists the attachment bucket and
# the backup bucket with the same variables the containers read. Run on the box
# in /opt/apps/perfectcrm after creating the buckets and keys
# (docs/operations.md, Deployment checklist). Requires rclone on the host;
# uses a throwaway config file, so no rclone remote setup is needed.
set -euo pipefail

cd "$(dirname "$0")"

set -a
# shellcheck source=/dev/null
[ -f .env.app ] && . ./.env.app
# shellcheck source=/dev/null
[ -f .env.litestream ] && . ./.env.litestream
set +a

: "${SPACES_ENDPOINT:?Set SPACES_ENDPOINT (R2: https://<accountid>.r2.cloudflarestorage.com)}"
: "${SPACES_REGION:?Set SPACES_REGION (use 'auto' for R2)}"
: "${SPACES_BUCKET:?Set SPACES_BUCKET}"
: "${SPACES_ACCESS_KEY_ID:?Set SPACES_ACCESS_KEY_ID}"
: "${SPACES_SECRET_ACCESS_KEY:?Set SPACES_SECRET_ACCESS_KEY}"
: "${LITESTREAM_BUCKET:?Set LITESTREAM_BUCKET}"
: "${LITESTREAM_ACCESS_KEY_ID:?Set LITESTREAM_ACCESS_KEY_ID}"
: "${LITESTREAM_SECRET_ACCESS_KEY:?Set LITESTREAM_SECRET_ACCESS_KEY}"

CONF="$(mktemp)"
chmod 600 "$CONF"
trap 'rm -f "$CONF"' EXIT

write_remote() {
  local name="$1" key_id="$2" secret="$3"
  cat >> "$CONF" <<EOF
[$name]
type = s3
provider = Other
endpoint = $SPACES_ENDPOINT
region = $SPACES_REGION
access_key_id = $key_id
secret_access_key = $secret
acl = private

EOF
}

write_remote attachments "$SPACES_ACCESS_KEY_ID" "$SPACES_SECRET_ACCESS_KEY"
write_remote backups "$LITESTREAM_ACCESS_KEY_ID" "$LITESTREAM_SECRET_ACCESS_KEY"

rclone --config "$CONF" lsd "attachments:$SPACES_BUCKET" --max-depth 1
rclone --config "$CONF" lsd "backups:$LITESTREAM_BUCKET" --max-depth 1
echo "Both buckets reachable."
