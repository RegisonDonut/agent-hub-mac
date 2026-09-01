#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
target="${1:-}"
shift || true
expected_commit=""
runtime_smoke=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-commit)
      expected_commit="${2:-}"
      shift 2
      ;;
    --runtime-smoke)
      runtime_smoke=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "Usage: $0 <AgentHub.app|AgentHub-macOS.zip> [--expected-commit SHA] [--runtime-smoke]" >&2
  exit 2
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/agenthub-release-verify.XXXXXX")
smoke_project="agenthub-release-smoke-$$"
smoke_compose="$work_dir/docker-compose.yml"
cleanup() {
  if [[ -f "$smoke_compose" ]] && command -v docker >/dev/null 2>&1; then
    docker compose --project-name "$smoke_project" --file "$smoke_compose" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ -d "$target" ]]; then
  app_dir="${target:A}"
elif [[ -f "$target" ]]; then
  ditto -x -k "$target" "$work_dir/unpacked"
  app_dir="$work_dir/unpacked/AgentHub.app"
else
  echo "Release target does not exist: $target" >&2
  exit 1
fi

test -d "$app_dir" || { echo "Final package does not contain AgentHub.app" >&2; exit 1; }
manifest="$app_dir/Contents/Resources/AgentHubRelease.json"
main_binary="$app_dir/Contents/MacOS/AgentHub"
totp_binary="$app_dir/Contents/Helpers/agenthub-totp"
runtime_dir="$app_dir/Contents/Resources/BundledRuntime"

codesign --verify --deep --strict "$app_dir"

for binary in "$main_binary" "$totp_binary"; do
  test -x "$binary" || { echo "Missing executable: $binary" >&2; exit 1; }
  archs="$(lipo -archs "$binary")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || {
    echo "$binary is not universal: $archs" >&2
    exit 1
  }
done

test -f "$manifest" || { echo "Missing AgentHubRelease.json" >&2; exit 1; }
EXPECTED_COMMIT="$expected_commit" APP_DIR="$app_dir" MANIFEST="$manifest" python3 - <<'PY'
import hashlib
import json
import os
import plistlib
from pathlib import Path

app = Path(os.environ["APP_DIR"])
manifest = json.loads(Path(os.environ["MANIFEST"]).read_text(encoding="utf-8"))
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
expected_features = {
    "codex-account-management",
    "multi-account-routing",
    "quota-and-work-dashboard",
    "totp-manager",
    "touch-id-session-authorization",
    "agenthub-totp-cli",
    "offline-sub2api-runtime",
}
if manifest.get("schemaVersion") != 1:
    raise SystemExit("release manifest schemaVersion mismatch")
if manifest.get("version") != info.get("CFBundleShortVersionString"):
    raise SystemExit("release manifest version mismatch")
if manifest.get("buildNumber") != info.get("CFBundleVersion"):
    raise SystemExit("release manifest build number mismatch")
if set(manifest.get("features") or []) != expected_features:
    raise SystemExit("release manifest feature inventory mismatch")
if manifest.get("sourceDirty"):
    raise SystemExit("release manifest was built from a dirty worktree")
expected_commit = os.environ.get("EXPECTED_COMMIT")
if expected_commit and manifest.get("sourceCommit") != expected_commit:
    raise SystemExit("release manifest source commit mismatch")
for relative in manifest.get("requiredFiles") or []:
    if not (app / relative).is_file():
        raise SystemExit(f"required release file missing: {relative}")
for relative, expected in (manifest.get("sha256") or {}).items():
    path = app / relative
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise SystemExit(f"release artifact digest mismatch: {relative}")
runtime = manifest.get("runtime") or {}
if set(runtime.get("images") or []) != {
    "weishaw/sub2api:0.1.179",
    "postgres:18-alpine",
    "redis:8-alpine",
}:
    raise SystemExit("release runtime image inventory mismatch")
print(f"manifest ok: AgentHub {manifest['version']} ({manifest['sourceCommit']})")
PY

help_output="$($totp_binary --help)"
[[ "$help_output" == *"get-by-label"* ]] || { echo "agenthub-totp help is incomplete" >&2; exit 1; }
mkdir -p "$work_dir/home"
CFFIXED_USER_HOME="$work_dir/home" "$totp_binary" list >/dev/null

"$project_dir/scripts/verify-bundle.sh" "$app_dir"

if [[ "$runtime_smoke" -eq 1 ]]; then
  docker info >/dev/null
  case "$(uname -m)" in
    arm64) archive="$runtime_dir/docker-images-arm64.tar.gz" ;;
    x86_64) archive="$runtime_dir/docker-images-x86_64.tar.gz" ;;
    *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  gzip -dc "$archive" | docker load >/dev/null
  port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
  secret=$(openssl rand -hex 24)
  cat > "$smoke_compose" <<EOF
services:
  postgres:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: agenthub
      POSTGRES_PASSWORD: $secret
      POSTGRES_DB: agenthub
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U agenthub -d agenthub"]
      interval: 2s
      timeout: 3s
      retries: 30
  redis:
    image: redis:8-alpine
    command: ["redis-server", "--requirepass", "$secret"]
    environment:
      REDISCLI_AUTH: $secret
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 30
  sub2api:
    image: weishaw/sub2api:0.1.179
    ports:
      - "127.0.0.1:$port:8080"
    environment:
      AUTO_SETUP: "true"
      SERVER_HOST: "0.0.0.0"
      SERVER_PORT: "8080"
      SERVER_MODE: "release"
      RUN_MODE: "simple"
      SIMPLE_MODE_CONFIRM: "true"
      DATABASE_HOST: postgres
      DATABASE_PORT: "5432"
      DATABASE_USER: agenthub
      DATABASE_PASSWORD: $secret
      DATABASE_DBNAME: agenthub
      DATABASE_SSLMODE: disable
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_PASSWORD: $secret
      REDIS_DB: "0"
      ADMIN_EMAIL: admin@agenthub.local
      ADMIN_PASSWORD: $secret
      JWT_SECRET: $secret
      JWT_EXPIRE_HOUR: "24"
      TOTP_ENCRYPTION_KEY: $secret
      TZ: UTC
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
      interval: 3s
      timeout: 5s
      retries: 40
EOF
  if ! docker compose --project-name "$smoke_project" --file "$smoke_compose" up -d --pull never --wait --wait-timeout 180; then
    echo "Bundled runtime failed to become healthy. Container status:" >&2
    docker compose --project-name "$smoke_project" --file "$smoke_compose" ps >&2 || true
    echo "Bundled runtime logs (test secrets redacted):" >&2
    docker compose --project-name "$smoke_project" --file "$smoke_compose" \
      logs --no-color --tail 200 sub2api postgres redis 2>&1 \
      | sed "s/$secret/[REDACTED]/g" >&2 || true
    exit 1
  fi
  health_body=$(curl -fsS --retry 20 --retry-delay 2 --retry-all-errors "http://127.0.0.1:$port/health")
  [[ -n "$health_body" ]] || { echo "Sub2API health response is empty" >&2; exit 1; }
  docker compose --project-name "$smoke_project" --file "$smoke_compose" ps
  docker compose --project-name "$smoke_project" --file "$smoke_compose" down -v --remove-orphans >/dev/null
  [[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$smoke_project")" ]] || {
    echo "Runtime smoke containers were not cleaned up" >&2
    exit 1
  }
  echo "runtime smoke ok: bundled Sub2API/PostgreSQL/Redis healthy on 127.0.0.1:$port"
fi

echo "release verification passed: $app_dir"
