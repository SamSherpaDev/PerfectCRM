#!/usr/bin/env bash
# Deploy operator-tooling tests. Run: bash test/deploy/test_deploy.sh
# Needs: shellcheck, rclone, docker (with compose v2), python3, and systemd-analyze for the
# timer checks. Missing Docker, ShellCheck, rclone, or systemd-analyze skips its section
# cleanly; CI provides all of them.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILURES=0

pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
skip() { echo "skip: $1"; }

# 1. ShellCheck every operator and test script.
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$REPO_ROOT/deploy/"*.sh "$REPO_ROOT/test/deploy/"*.sh; then
    pass "shellcheck clean on deploy and test scripts"
  else
    fail "shellcheck reported warnings"
  fi
else
  skip "shellcheck not installed"
fi

if python3 "$REPO_ROOT/test/deploy/test_restore_drill.py"; then
  pass "restore drill lifecycle"
else
  fail "restore drill lifecycle"
fi

if python3 "$REPO_ROOT/test/deploy/test_backup_schedule.py"; then
  pass "Drive backup timer and service"
else
  fail "Drive backup timer and service"
fi

# 2. Drive backup against a real rclone crypt remote over a local folder.
# A throwaway rclone config defines sherpa-backup with a test-only password, and
# a date shim pins the script's UTC day while rclone keeps real file ages.
drive_backup_checks() {
  local work drive stamp listing real_date gzipped december
  work="$(mktemp -d)"
  drive="$work/drive"
  mkdir -p "$drive" "$work/bin"
  cat > "$work/bin/docker" <<'SHIM'
#!/usr/bin/env bash
# Writes a small stand-in database where the real sqlite3 .backup would.
out=""
for arg in "$@"; do
  case "$arg" in *:/out) out="${arg%:/out}" ;; esac
done
target="${*: -1}"
target="${target#.backup \'/out/}"
target="${target%\'}"
printf 'SQLite format 3 stand-in %s\n' "$target" > "$out/$target"
printf '%s\n' "$*" >> "$DOCKER_LOG"
SHIM
  real_date="$(command -v date)"
  cat > "$work/bin/date" <<SHIM
#!/usr/bin/env bash
if [ "\$*" = "-u +%Y-%m-%d" ]; then
  printf '%s\n' "\$FAKE_TODAY"
else
  exec "$real_date" "\$@"
fi
SHIM
  chmod 700 "$work/bin/docker" "$work/bin/date"
  cat > "$work/rclone.conf" <<CONF
[sherpa-drive]
type = local

[sherpa-backup]
type = crypt
remote = sherpa-drive:$drive
password = $(printf 'throwaway-test-only' | rclone obscure -)
filename_encryption = standard
directory_name_encryption = true
CONF

  run_backup() {
    env PATH="$work/bin:$PATH" DOCKER_LOG="$work/docker.log" FAKE_TODAY="$1" \
      RCLONE_CONFIG="$work/rclone.conf" \
      bash "$REPO_ROOT/deploy/drive-backup.sh" > "$work/out.log" 2>&1
  }
  plain() { RCLONE_CONFIG="$work/rclone.conf" rclone "$@"; }

  # Seed an expired daily, a kept eleven-month-old monthly, and an expired monthly.
  printf 'old\n' > "$work/old.gz"
  touch -t "$(date -u -v-40d +%Y%m%d%H%M 2>/dev/null || date -u -d '40 days ago' +%Y%m%d%H%M)" "$work/old.gz"
  plain copyto "$work/old.gz" sherpa-backup:perfectcrm/daily/production-2000-01-02.sqlite3.gz
  touch -t "$(date -u -v-330d +%Y%m%d%H%M 2>/dev/null || date -u -d '330 days ago' +%Y%m%d%H%M)" "$work/old.gz"
  plain copyto "$work/old.gz" sherpa-backup:perfectcrm/monthly/production-2000-01-01.sqlite3.gz
  touch -t "$(date -u -v-400d +%Y%m%d%H%M 2>/dev/null || date -u -d '400 days ago' +%Y%m%d%H%M)" "$work/old.gz"
  plain copyto "$work/old.gz" sherpa-backup:perfectcrm/monthly/production-1999-12-01.sqlite3.gz

  # No run on November 1, so the 2nd is the month's first run.
  stamp=2026-11-02
  if run_backup "$stamp"; then
    pass "Drive backup runs against the sherpa-backup crypt remote"
  else
    fail "Drive backup failed: $(cat "$work/out.log")"
  fi
  listing="$(plain lsf -R sherpa-backup:perfectcrm)"
  for want in "daily/production-$stamp.sqlite3.gz" "daily/production_queue-$stamp.sqlite3.gz" \
      "monthly/production-$stamp.sqlite3.gz" "monthly/production_queue-$stamp.sqlite3.gz" \
      "monthly/production-2000-01-01.sqlite3.gz"; do
    if grep -qxF "$want" <<<"$listing"; then
      pass "Drive backup holds $want"
    else
      fail "Drive backup is missing $want"
    fi
  done
  if grep -qF 'production-2000-01-02' <<<"$listing"; then
    fail "Drive backup kept a daily copy older than 30 days"
  else
    pass "Drive backup pruned the expired daily copy"
  fi
  if grep -qF 'production-1999-12-01' <<<"$listing"; then
    fail "Drive backup kept a monthly copy older than 365 days"
  else
    pass "Drive backup pruned the expired monthly copy"
  fi
  if [ "$(plain cat "sherpa-backup:perfectcrm/daily/production-$stamp.sqlite3.gz" | gzip -dc)" = \
      "SQLite format 3 stand-in production-$stamp.sqlite3" ]; then
    pass "Drive backup decrypts to the database snapshot"
  else
    fail "Drive backup content does not round-trip"
  fi
  # Unencrypted gzip starts with 1f 8b and names the archive in its header.
  gzipped=false
  while IFS= read -r -d '' file; do
    if [ "$(head -c 2 "$file" | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then
      gzipped=true
    fi
  done < <(find "$drive" -type f -print0)
  if find "$drive" | grep -qiE 'perfect|production|sqlite|daily|monthly'; then
    fail "Drive backup left plain-text names on disk"
  elif [ "$gzipped" = true ] || grep -raqF "production-$stamp" "$drive"; then
    fail "Drive backup left plain-text content on disk"
  else
    pass "Drive backup stores only encrypted names and content"
  fi

  # Same-day rerun: no new snapshot, encrypted files byte-for-byte unchanged.
  find "$drive" -type f -exec shasum {} + | sort > "$work/before"
  : > "$work/docker.log"
  if run_backup "$stamp" && [ ! -s "$work/docker.log" ]; then
    find "$drive" -type f -exec shasum {} + | sort > "$work/after"
    if cmp -s "$work/before" "$work/after"; then
      pass "Drive backup same-day rerun leaves files untouched"
    else
      fail "Drive backup same-day rerun changed files"
    fi
  else
    fail "Drive backup same-day rerun took a new snapshot or failed: $(cat "$work/out.log")"
  fi

  # A later run that month adds daily copies only.
  if run_backup 2026-11-03; then
    listing="$(plain lsf -R sherpa-backup:perfectcrm)"
    if grep -qxF daily/production-2026-11-03.sqlite3.gz <<<"$listing" &&
        grep -qxF daily/production_queue-2026-11-03.sqlite3.gz <<<"$listing" &&
        [ "$(grep -F -- '-2026-11-' <<<"$listing" | grep '^monthly/' | sort)" = \
          $'monthly/production-2026-11-02.sqlite3.gz\nmonthly/production_queue-2026-11-02.sqlite3.gz' ]; then
      pass "Drive backup keeps one monthly copy per month"
    else
      fail "Drive backup monthly rule broken: $listing"
    fi
  else
    fail "Drive backup later run failed: $(cat "$work/out.log")"
  fi

  # A partial first December run left only the queue's monthly copy.
  printf 'partial\n' > "$work/partial.gz"
  plain copyto "$work/partial.gz" sherpa-backup:perfectcrm/monthly/production_queue-2026-12-01.sqlite3.gz
  if run_backup 2026-12-02; then
    december="$(plain lsf sherpa-backup:perfectcrm/monthly | grep -F -- '-2026-12-' | sort)"
    if [ "$december" = $'production-2026-12-02.sqlite3.gz\nproduction_queue-2026-12-01.sqlite3.gz' ]; then
      pass "Drive backup adds a monthly copy only for a database the month lacks"
    else
      fail "Drive backup December monthly copies wrong: $december"
    fi
  else
    fail "Drive backup December run failed: $(cat "$work/out.log")"
  fi
  rm -rf "$work"
}

# 3. Drive attachment mirror against real rclone: a local folder stands in for
# the attachments bucket, a docker shim prints the app's manifest, and an
# rclone shim logs every call before running the real rclone.
attachments_backup_checks() {
  local work drive bucket real_rclone listing held ordinary photo letter lost added call
  work="$(mktemp -d)"
  drive="$work/drive"
  bucket="$work/bucket"
  mkdir -p "$drive" "$bucket" "$work/bin" "$work/app"
  cp "$REPO_ROOT/deploy/drive-attachments-backup.sh" "$work/app/"
  real_rclone="$(command -v rclone)"
  cat > "$work/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
cat "$MANIFEST"
exit "${DOCKER_STATUS:-0}"
SHIM
  cat > "$work/bin/rclone" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$RCLONE_LOG"
if [ -n "\${RCLONE_CONFIG_APPKEYS_TYPE:-}" ]; then
  # app-keys access: record what reached rclone's environment, then read
  # the stand-in bucket through a local remote of the same name.
  printf '%s|%s|%s|%s|%s|%s|%s\n' "\$RCLONE_CONFIG_APPKEYS_TYPE" "\$RCLONE_CONFIG_APPKEYS_PROVIDER" \\
    "\$RCLONE_CONFIG_APPKEYS_ENDPOINT" "\$RCLONE_CONFIG_APPKEYS_REGION" \\
    "\$RCLONE_CONFIG_APPKEYS_ACCESS_KEY_ID" "\$RCLONE_CONFIG_APPKEYS_SECRET_ACCESS_KEY" \\
    "\${SECRET_KEY_BASE:-}" >> "\$APPKEYS_LOG"
  unset RCLONE_CONFIG_APPKEYS_PROVIDER RCLONE_CONFIG_APPKEYS_ENDPOINT RCLONE_CONFIG_APPKEYS_REGION \\
    RCLONE_CONFIG_APPKEYS_ACCESS_KEY_ID RCLONE_CONFIG_APPKEYS_SECRET_ACCESS_KEY
  export RCLONE_CONFIG_APPKEYS_TYPE=local
fi
exec "$real_rclone" "\$@"
SHIM
  chmod 700 "$work/bin/docker" "$work/bin/rclone"
  cat > "$work/rclone.conf" <<CONF
[perfectcrm-attachments]
type = local

[sherpa-drive]
type = local

[sherpa-backup]
type = crypt
remote = sherpa-drive:$drive
password = $(printf 'throwaway-test-only' | "$real_rclone" obscure -)
filename_encryption = standard
directory_name_encryption = true
CONF

  key() { printf '%s%0*d' "$1" $((28 - ${#1})) "$2"; }
  ordinary="$(key ordinary 1)"
  photo="$(key photo 2)"
  held="$(key held 3)"
  letter="$(key letter 4)"
  lost="$(key lost 5)"
  added="$(key added 6)"
  for name in "$ordinary" "$photo" "$held" "$letter" "$added"; do
    printf 'attachment bytes of %s\n' "$name" > "$bucket/$name"
  done
  manifest() {
    { printf 'perfectcrm-attachment-manifest v1\n'; [ "$#" -eq 0 ] || printf '%s\n' "$@"; printf 'end %s\n' "$#"; } > "$work/manifest"
  }
  run_mirror() {
    : > "$work/rclone.log"
    : > "$work/docker.log"
    env -u ATTACHMENTS_ACCESS -u ATTACHMENTS_BUCKET PATH="$work/bin:$PATH" RCLONE_CONFIG="$work/rclone.conf" \
      RCLONE_LOG="$work/rclone.log" DOCKER_LOG="$work/docker.log" APPKEYS_LOG="$work/appkeys.log" \
      MANIFEST="$work/manifest" "$@" bash "$work/app/drive-attachments-backup.sh" > "$work/out.log" 2>&1
  }
  remote_mirror() { run_mirror ATTACHMENTS_ACCESS=remote ATTACHMENTS_BUCKET="$bucket" "$@"; }
  plain() { RCLONE_CONFIG="$work/rclone.conf" "$real_rclone" "$@"; }
  drive_listing() { plain lsf --files-only sherpa-backup:perfectcrm/attachments | sort; }
  drive_hashes() { find "$drive" -type f -exec shasum {} + | sort; }

  # First run copies exactly the manifest; the held key in the bucket stays out.
  manifest "$photo" "$ordinary"
  if remote_mirror && [ "$(drive_listing)" = "$(printf '%s\n' "$ordinary" "$photo")" ]; then
    pass "attachment mirror copies exactly the manifest's keys and never the held file"
  else
    fail "attachment mirror first run wrong: $(cat "$work/out.log") $(drive_listing)"
  fi
  if grep -qxF "$(printf 'kept 0, new 2, removed 0, not in bucket 0.')" <(sed 's/^[^ ]* Attachments backup: //' "$work/out.log"); then
    pass "attachment mirror logs counts only"
  else
    fail "attachment mirror log line wrong: $(cat "$work/out.log")"
  fi
  if [ "$(plain cat "sherpa-backup:perfectcrm/attachments/$ordinary")" = "attachment bytes of $ordinary" ]; then
    pass "attachment mirror copy decrypts to the stored bytes"
  else
    fail "attachment mirror content does not round-trip"
  fi
  if find "$drive" | grep -qiE 'perfect|attach|ordinary|photo'; then
    fail "attachment mirror left plain-text names on disk"
  elif grep -raqF 'attachment bytes' "$drive"; then
    fail "attachment mirror left plain-text content on disk"
  else
    pass "attachment mirror stores only encrypted names and content"
  fi
  if [ "$(cat "$work/docker.log")" = "exec -e RAILS_LOG_LEVEL=error perfectcrm-app bin/rails backup:attachment_manifest" ]; then
    pass "attachment mirror reads the manifest from the running app"
  else
    fail "attachment mirror docker call wrong: $(cat "$work/docker.log")"
  fi

  # A rerun uploads nothing and leaves every encrypted file untouched.
  drive_hashes > "$work/before"
  if remote_mirror && ! grep -qE '^(copy|delete) ' "$work/rclone.log" && drive_hashes | cmp -s "$work/before" -; then
    pass "attachment mirror rerun uploads nothing and changes no file"
  else
    fail "attachment mirror rerun changed Drive: $(cat "$work/out.log")"
  fi

  # A key that leaves the allowlist is permanently deleted, nothing else is.
  manifest "$ordinary" "$letter"
  if remote_mirror && [ "$(drive_listing)" = "$(printf '%s\n' "$letter" "$ordinary")" ]; then
    pass "attachment mirror deletes a copy whose key left the manifest"
  else
    fail "attachment mirror removal wrong: $(cat "$work/out.log") $(drive_listing)"
  fi
  if grep -q '^delete ' "$work/rclone.log" && ! grep '^delete ' "$work/rclone.log" | grep -qv -- '--drive-use-trash=false'; then
    pass "attachment mirror deletes bypass the Drive trash"
  else
    fail "attachment mirror delete without --drive-use-trash=false: $(cat "$work/rclone.log")"
  fi
  if grep -qE '^(lsf|lsl|ls|lsjson|size) .*(perfectcrm-attachments|appkeys):' "$work/rclone.log"; then
    fail "attachment mirror listed the attachments bucket"
  else
    pass "attachment mirror never lists the attachments bucket"
  fi

  # Losing a file from the bucket never deletes its Drive copy.
  rm "$bucket/$ordinary"
  manifest "$ordinary" "$letter" "$lost" "$added"
  if remote_mirror && [ "$(drive_listing)" = "$(printf '%s\n' "$added" "$letter" "$ordinary")" ] &&
      grep -qF 'kept 2, new 1, removed 0, not in bucket 1.' "$work/out.log"; then
    pass "attachment mirror keeps copies of files missing from the bucket"
  else
    fail "attachment mirror bucket loss wrong: $(cat "$work/out.log") $(drive_listing)"
  fi

  # Any manifest that is not exactly header, keys, trailer changes nothing.
  drive_hashes > "$work/before"
  for case_name in 'stray log line' 'leading log line' 'missing trailer' 'count mismatch' 'bad key' \
      'uppercase key' 'duplicate key' 'empty output' 'failed docker exec'; do
    local status=0
    manifest "$ordinary" "$letter"
    case "$case_name" in
      'stray log line') printf 'perfectcrm-attachment-manifest v1\n%s\nI, [x] INFO -- : boot\nend 1\n' "$ordinary" > "$work/manifest" ;;
      'leading log line') { printf 'W, [x] WARN -- : boot\n'; cat "$work/manifest"; } > "$work/m" && mv "$work/m" "$work/manifest" ;;
      'missing trailer') printf 'perfectcrm-attachment-manifest v1\n%s\n' "$ordinary" > "$work/manifest" ;;
      'count mismatch') printf 'perfectcrm-attachment-manifest v1\n%s\nend 2\n' "$ordinary" > "$work/manifest" ;;
      'bad key') manifest "$ordinary" "../$(key held 3)" ;;
      'uppercase key') manifest "$ordinary" "$(key HELD 3)" ;;
      'duplicate key') manifest "$ordinary" "$ordinary" ;;
      'empty output') : > "$work/manifest" ;;
      'failed docker exec') status=1 ;;
    esac
    if ! remote_mirror DOCKER_STATUS="$status" && [ ! -s "$work/rclone.log" ] && drive_hashes | cmp -s "$work/before" - &&
        grep -qE 'Attachments backup FAILED: the (app did not print|manifest)' "$work/out.log"; then
      pass "attachment mirror refuses a manifest with $case_name before any rclone call"
    else
      fail "attachment mirror accepted a manifest with $case_name: $(cat "$work/out.log")"
    fi
  done

  # An empty allowlist against a non-empty Drive means the wrong database.
  manifest
  if ! remote_mirror && ! grep -qE '^(copy|delete) ' "$work/rclone.log" && drive_hashes | cmp -s "$work/before" - &&
      grep -qF 'manifest is empty while Drive holds copies' "$work/out.log"; then
    pass "attachment mirror refuses an empty manifest while Drive holds copies"
  else
    fail "attachment mirror emptied Drive from an empty manifest: $(cat "$work/out.log")"
  fi

  # Missing access settings fail before any work.
  manifest "$ordinary"
  for setting in 'ATTACHMENTS_ACCESS=remote' 'ATTACHMENTS_ACCESS=r2' 'ATTACHMENTS_BUCKET=unused'; do
    if ! run_mirror "$setting" && [ ! -s "$work/docker.log" ] && [ ! -s "$work/rclone.log" ] &&
        grep -q 'Attachments backup FAILED: set ATTACHMENTS_' "$work/out.log"; then
      pass "attachment mirror fails before any work with only $setting"
    else
      fail "attachment mirror ran with only $setting: $(cat "$work/out.log")"
    fi
  done

  # app-keys access reads only the five bucket settings from .env.app as data.
  rm -rf "$drive"
  mkdir "$drive"
  cat > "$work/app/.env.app" <<ENV
\$(touch "$work/sourced")
SECRET_KEY_BASE=not-for-the-backup
SPACES_ENDPOINT=https://fixture-account.r2.cloudflarestorage.com
SPACES_REGION=auto
SPACES_BUCKET=$bucket
SPACES_ACCESS_KEY_ID="fixture-key-id"
SPACES_SECRET_ACCESS_KEY='fixture \$ecret; value'
ENV
  : > "$work/appkeys.log"
  manifest "$letter" "$added"
  if run_mirror ATTACHMENTS_ACCESS=app-keys && [ "$(drive_listing)" = "$(printf '%s\n' "$added" "$letter")" ]; then
    pass "attachment mirror copies through the app's bucket keys"
  else
    fail "attachment mirror app-keys run failed: $(cat "$work/out.log") $(drive_listing)"
  fi
  call="s3|Other|https://fixture-account.r2.cloudflarestorage.com|auto|fixture-key-id|fixture \$ecret; value|"
  if [ -s "$work/appkeys.log" ] && [ "$(sort -u "$work/appkeys.log")" = "$call" ] && [ ! -e "$work/sourced" ] &&
      ! grep -qF 'fixture' "$work/rclone.log"; then
    pass "attachment mirror passes app keys only through rclone's environment"
  else
    fail "attachment mirror app-keys environment wrong: $(sort -u "$work/appkeys.log")"
  fi
  sed -i.bak '/^SPACES_SECRET_ACCESS_KEY=/d' "$work/app/.env.app"
  if ! run_mirror ATTACHMENTS_ACCESS=app-keys && [ ! -s "$work/docker.log" ] && [ ! -s "$work/rclone.log" ]; then
    pass "attachment mirror app-keys access fails before any work without a bucket key"
  else
    fail "attachment mirror app-keys ran without a bucket key: $(cat "$work/out.log")"
  fi
  rm -rf "$work"
}

if command -v rclone >/dev/null 2>&1; then
  drive_backup_checks
  attachments_backup_checks
else
  skip "rclone not installed (Drive backup checks)"
fi

# Remaining sections need Docker.
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  skip "docker compose not available (compose config and caddy validate checks)"
  exit "$FAILURES"
fi

# Sample env proving the production Compose file is valid.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cp "$REPO_ROOT/deploy/compose.yml" "$REPO_ROOT/deploy/litestream.yml" "$WORKDIR/"
cp "$REPO_ROOT/deploy/Caddyfile.snippet" "$WORKDIR/Caddyfile"

cat > "$WORKDIR/.env.app" <<'EOF'
SECRET_KEY_BASE=test-only-not-a-production-secret
GOOGLE_CLIENT_ID=test-client-id
GOOGLE_CLIENT_SECRET=test-client-secret
ALLOWED_GOOGLE_EMAILS=captain@example.test
SPACES_REGION=auto
SPACES_ENDPOINT=https://test-account.r2.cloudflarestorage.com
SPACES_BUCKET=test-attachments
SPACES_ACCESS_KEY_ID=test-attachments-key
SPACES_SECRET_ACCESS_KEY=test-attachments-secret
EOF
cat > "$WORKDIR/.env.litestream" <<'EOF'
SPACES_REGION=auto
SPACES_ENDPOINT=https://test-account.r2.cloudflarestorage.com
LITESTREAM_BUCKET=test-backups
LITESTREAM_ACCESS_KEY_ID=test-backup-key
LITESTREAM_SECRET_ACCESS_KEY=test-backup-secret
EOF

CONFIG_JSON="$WORKDIR/config.json"
if (cd "$WORKDIR" && docker compose -f compose.yml config --format json > "$CONFIG_JSON" 2>"$WORKDIR/config.err"); then
  pass "docker compose config valid"
else
  fail "docker compose config invalid: $(cat "$WORKDIR/config.err")"
  exit "$FAILURES"
fi

if python3 - "$CONFIG_JSON" <<'PYEOF'
import json, sys
config = json.load(open(sys.argv[1]))
services = config.get("services", {})
problems = []

app = services.get("app", {})
for name, service in services.items():
    if service.get("ports"):
        problems.append(f"{name} service must not publish ports")
    if "build" in service:
        problems.append(f"{name} service must pull its image, not build")
if "apps" not in (app.get("networks") or {}):
    problems.append("app service must join the shared apps network")
apps_network = config.get("networks", {}).get("apps", {})
if apps_network.get("external") is not True or apps_network.get("name") != "apps":
    problems.append("apps network must use the external network named apps")
image = app.get("image", "")
if not image.startswith("ghcr.io/"):
    problems.append(f"app image must come from GHCR, got: {image!r}")
app_env = app.get("environment", {}) or {}
leaked = sorted(k for k in app_env if k.startswith("LITESTREAM_"))
if leaked:
    problems.append(f"app environment leaks backup keys: {leaked}")
app_files = " ".join(str(f) for f in (app.get("env_file") or []))
if ".env.litestream" in app_files:
    problems.append("app service must not read .env.litestream")

lite = services.get("litestream", {})
lite_env = lite.get("environment", {}) or {}
for key in ("SPACES_SECRET_ACCESS_KEY", "SPACES_ACCESS_KEY_ID", "SPACES_BUCKET",
            "SECRET_KEY_BASE", "GOOGLE_CLIENT_SECRET"):
    if key in lite_env:
        problems.append(f"litestream environment contains {key}")
lite_files = " ".join(str(f) for f in (lite.get("env_file") or []))
if ".env.app" in lite_files:
    problems.append("litestream service must not read .env.app")

if problems:
    print("\n".join(f"FAIL: {p}" for p in problems))
    sys.exit(1)
print("ok: credential scoping, GHCR app image, no builds or published ports, shared apps network membership")
PYEOF
then
  true
else
  FAILURES=$((FAILURES + 1))
fi

# 3. Validate the Caddy snippet inside the pinned Caddy image.
if docker run --rm -v "$WORKDIR/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.11.2-alpine \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  pass "Caddyfile snippet validates"
else
  fail "Caddyfile snippet failed caddy validate"
fi

exit "$FAILURES"
