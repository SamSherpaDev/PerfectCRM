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

if command -v rclone >/dev/null 2>&1; then
  drive_backup_checks
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
