#!/usr/bin/env bash
# Restore the primary database and boot the running production image offline.
# Run with Docker access on the VPS; optional argument is the app config directory.
# RESTORE_SOURCE=litestream (default) or drive; see docs/operations.md, "Restore drill".
set -euo pipefail

cd -- "${1:-$(dirname "$0")}"

RESTORE_SOURCE="${RESTORE_SOURCE:-litestream}"
case "$RESTORE_SOURCE" in
  litestream) ;;
  drive) DRIVE_DAILY="${DRIVE_BACKUP_REMOTE:-sherpa-backup}:perfectcrm/daily" ;;
  *)
    echo "Restore drill FAILED: RESTORE_SOURCE must be litestream or drive." >&2
    exit 1
    ;;
esac

# Pin the actual running image, not a tag that may now point at another release.
IMAGE="$(docker inspect --format '{{if .State.Running}}{{.Image}}{{end}}' perfectcrm-app)"
if [[ "$IMAGE" != sha256:* ]]; then
  echo "Restore drill FAILED: perfectcrm-app must be running." >&2
  exit 1
fi
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/perfectcrm-restore-drill.XXXXXX")"
CONTAINER="${WORKDIR##*/}"
BOOT_ATTEMPTED=false
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$BOOT_ATTEMPTED" = true ]; then
    if ! docker rm -f "$CONTAINER" >/dev/null; then
      echo "Restore drill cleanup FAILED: could not remove container $CONTAINER." >&2
      status=1
    fi
  fi
  if ! rm -rf -- "$WORKDIR"; then
    echo "Restore drill cleanup FAILED: could not remove scratch $WORKDIR." >&2
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    echo "Restore drill passed: integrity ok, /up HTTP 200, restored User read; container and scratch removed."
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RESTORED_DATABASES=(production)
case "$RESTORE_SOURCE" in
  litestream)
    # Only this read-only restore has network access and backup credentials.
    # Do not source either environment file as shell code or load .env.app.
    docker run --rm \
      --env-file .env.litestream \
      -v "$WORKDIR:/restore" \
      -v "$PWD/litestream.yml:/etc/litestream.yml:ro" \
      litestream/litestream:0.5.9 \
      restore -config /etc/litestream.yml -o /restore/production.sqlite3 \
      /rails/storage/production.sqlite3
    ;;
  drive)
    # Host rclone reads only; the newest daily archive of each database wins.
    DRIVE_LISTING="$(rclone lsf --files-only "$DRIVE_DAILY")"
    for NAME in production production_queue; do
      ARCHIVE="$(grep -E "^$NAME-[0-9]{4}-[0-9]{2}-[0-9]{2}\.sqlite3\.gz\$" <<<"$DRIVE_LISTING" | sort | tail -n 1 || true)"
      if [ -z "$ARCHIVE" ]; then
        echo "Restore drill FAILED: no $NAME archive in the Drive daily backups." >&2
        exit 1
      fi
      echo "Restoring Drive archive $ARCHIVE"
      if ! rclone cat "$DRIVE_DAILY/$ARCHIVE" | gzip -dc > "$WORKDIR/$NAME.sqlite3"; then
        echo "Restore drill FAILED: Drive archive $ARCHIVE did not download and decompress." >&2
        exit 1
      fi
    done
    RESTORED_DATABASES=(production production_queue)
    ;;
esac

# The Rails app UID needs a writable scratch directory for SQLite sidecars.
docker run --rm --network none --user 0:0 --entrypoint chown \
  -v "$WORKDIR:/restore" "$IMAGE" -R 1000:1000 /restore

for NAME in "${RESTORED_DATABASES[@]}"; do
  INTEGRITY_RESULT="$(docker run --rm --network none --entrypoint sqlite3 \
    -v "$WORKDIR:/restore" "$IMAGE" \
    "/restore/$NAME.sqlite3" 'PRAGMA integrity_check;')"
  if [ "$INTEGRITY_RESULT" != "ok" ]; then
    printf 'Restore drill FAILED: %s database integrity check returned:\n%s\n' "$NAME" "$INTEGRITY_RESULT" >&2
    exit 1
  fi
  echo "Restored $NAME database integrity: ok"
done

# Keep drill-only configuration out of the image and normal production boot.
# No db:prepare, migrations, seeds, queue recovery, or job supervisor is run.
cat > "$WORKDIR/boot.rb" <<'RUBY'
ENV.delete("SOLID_QUEUE_IN_PUMA") # Even "false" would enable the Puma plugin.
require "/rails/config/application"

Rails.application.class.initializer "restore_drill.offline",
    after: :load_environment_config, before: :load_environment_hook do |app|
  app.config.active_job.queue_adapter = :test
  app.config.action_mailer.perform_deliveries = false
  app.config.action_mailer.delivery_method = :test
  app.config.active_storage.service = :local
  app.config.cache_store = :memory_store
end

if ARGV.delete("--probe")
  require "/rails/config/environment"
  User.connection.execute("PRAGMA query_only = ON")
  User.select(:id).readonly.first!
  puts "Restored User record read (no fields logged)."
else
  ARGV.replace(["server", "-b", "127.0.0.1", "-p", "3000"])
  load "/rails/bin/rails"
end
RUBY
chmod 644 "$WORKDIR/boot.rb"

# Use only the image's base environment and a throwaway Rails session secret.
# No production volume, integration credentials, host ports, or external network.
BOOT_ATTEMPTED=true
docker run -d --name "$CONTAINER" --network none --no-healthcheck \
  -e RAILS_ENV=production -e SECRET_KEY_BASE_DUMMY=1 \
  -v "$WORKDIR:/rails/storage" \
  --entrypoint ruby "$IMAGE" /rails/storage/boot.rb >/dev/null

for _ in {1..30}; do
  if HEALTH_STATUS="$(docker exec "$CONTAINER" curl --fail --silent --max-time 2 \
      --output /dev/null --write-out '%{http_code}' http://127.0.0.1:3000/up 2>/dev/null)" && [ "$HEALTH_STATUS" = 200 ]; then
    echo "Restored app /up: HTTP 200"
    if ! docker exec "$CONTAINER" ruby /rails/storage/boot.rb --probe; then
      echo "Restore drill FAILED: Rails could not read a restored User record." >&2
      exit 1
    fi
    exit 0
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" != true ]; then
    echo "Restore drill FAILED: throwaway app exited during boot." >&2
    docker logs --tail 40 "$CONTAINER" >&2 || true
    exit 1
  fi
  sleep 2
done
echo "Restore drill FAILED: throwaway app never became healthy." >&2
exit 1
