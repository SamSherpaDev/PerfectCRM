#!/usr/bin/env bash
# Deploy operator-tooling tests. Run: bash test/deploy/test_deploy.sh
# Needs: shellcheck, docker (with compose v2), python3. Missing Docker skips its section.
# Missing ShellCheck skips its section cleanly; CI installs both tools.
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

# Shared-server layout: PerfectCRM publishes no web ports (the system Caddy owns
# 80/443) and joins the shared external "apps" network. Source-level check on the
# repo files so it runs even without Docker.
if grep -vE '^\s*#' "$REPO_ROOT/deploy/compose.yml" | grep -qE '(^|\s)(ports|build):'; then
  fail "perfectcrm compose must not publish ports or build (system Caddy owns web ports; image comes from GHCR)"
else
  pass "perfectcrm compose publishes no ports and builds nothing"
fi
if grep -q "external: true" "$REPO_ROOT/deploy/compose.yml"; then
  pass "perfectcrm compose joins the shared external network"
else
  fail "perfectcrm compose must join the shared external network"
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
if app.get("build"):
    problems.append("app service must pull the CI image, not build")
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
print("ok: credential scoping (app has no LITESTREAM_*, litestream has no attachment/app secrets; image from GHCR, no build)")
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
