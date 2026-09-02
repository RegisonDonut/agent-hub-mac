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
smoke_env="$work_dir/runtime.env"
cleanup() {
  if [[ -f "$smoke_compose" && -f "$smoke_env" ]] && command -v docker >/dev/null 2>&1; then
    docker compose --project-name "$smoke_project" --env-file "$smoke_env" --file "$smoke_compose" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ -d "$target" ]]; then
  app_dir="${target:A}"
elif [[ -f "$target" ]]; then
  ZIP_TARGET="$target" python3 - <<'PY'
import os
import stat
import zipfile
from pathlib import PurePosixPath

archive = os.environ["ZIP_TARGET"]
seen = set()
seen_casefolded = set()
total_size = 0
with zipfile.ZipFile(archive) as bundle:
    for entry in bundle.infolist():
        name = entry.filename
        if not name or "\\" in name or name.startswith("/"):
            raise SystemExit(f"unsafe ZIP path: {name!r}")
        normalized = name[:-1] if name.endswith("/") else name
        parts = normalized.split("/")
        if any(part in ("", ".", "..") for part in parts):
            raise SystemExit(f"unsafe ZIP path: {name!r}")
        if PurePosixPath(normalized).parts[0] != "AgentHub.app":
            raise SystemExit(f"unexpected top-level ZIP entry: {name}")
        if "__MACOSX" in parts:
            raise SystemExit(f"AppleDouble metadata is not allowed in release ZIP: {name}")
        if any(part.startswith("._") for part in parts):
            raise SystemExit(f"AppleDouble sidecar is not allowed in release ZIP: {name}")
        if normalized in seen or normalized.casefold() in seen_casefolded:
            raise SystemExit(f"duplicate ZIP path: {name}")
        seen.add(normalized)
        seen_casefolded.add(normalized.casefold())
        if entry.flag_bits & 0x1:
            raise SystemExit(f"encrypted ZIP entries are not allowed: {name}")
        mode = entry.external_attr >> 16
        kind = stat.S_IFMT(mode)
        expected_kind = stat.S_IFDIR if entry.is_dir() else stat.S_IFREG
        if entry.create_system != 3 or kind != expected_kind:
            raise SystemExit(f"symlink or special ZIP entry is not allowed: {name}")
        total_size += entry.file_size
        if entry.file_size > 2 * 1024**3 or total_size > 4 * 1024**3:
            raise SystemExit("release ZIP expands beyond the allowed size")
PY
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
task_binary="$app_dir/Contents/Helpers/agenthub-task"
runtime_dir="$app_dir/Contents/Resources/BundledRuntime"

codesign --verify --deep --strict "$app_dir"
codesign --verify --strict "$totp_binary"
codesign --verify --strict "$task_binary"
for signed_target in "$app_dir" "$totp_binary"; do
  signature_details="$(codesign -dv --verbose=4 "$signed_target" 2>&1)"
  [[ "$signature_details" == *"Signature=adhoc"* && "$signature_details" == *"TeamIdentifier=not set"* ]] || {
    echo "Release signature does not match manifest requirement for $signed_target: expected ad-hoc with no TeamIdentifier" >&2
    exit 1
  }
done

for binary in "$main_binary" "$totp_binary" "$task_binary"; do
  test -x "$binary" || { echo "Missing executable: $binary" >&2; exit 1; }
  archs="$(lipo -archs "$binary")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || {
    echo "$binary is not universal: $archs" >&2
    exit 1
  }
done
test -x "$task_binary" || { echo "Missing executable: $task_binary" >&2; exit 1; }

test -f "$manifest" || { echo "Missing AgentHubRelease.json" >&2; exit 1; }
EXPECTED_COMMIT="$expected_commit" APP_DIR="$app_dir" MANIFEST="$manifest" python3 - <<'PY'
import hashlib
import json
import os
import plistlib
import re
import stat
from pathlib import Path

app = Path(os.environ["APP_DIR"])
manifest = json.loads(Path(os.environ["MANIFEST"]).read_text(encoding="utf-8"))
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
expected_features = {
    "codex-account-management",
    "multi-account-routing",
    "sub2api-compliance-acknowledgement",
    "quota-and-work-dashboard",
    "totp-manager",
    "touch-id-session-authorization",
    "agenthub-totp-cli",
    "offline-sub2api-runtime",
    "sub2api-compliance-onboarding",
    "task-observation",
}
expected_inventory_files = {
    "Contents/Info.plist",
    "Contents/MacOS/AgentHub",
    "Contents/Helpers/agenthub-totp",
    "Contents/Helpers/agenthub-task",
    "Contents/Resources/BundledRuntime/VERSIONS.txt",
    "Contents/Resources/BundledRuntime/docker-compose.yml",
    "Contents/Resources/BundledRuntime/docker-images-arm64.tar.gz",
    "Contents/Resources/BundledRuntime/docker-images-x86_64.tar.gz",
    "Contents/Resources/BundledRuntime/arm64/codex",
    "Contents/Resources/BundledRuntime/x86_64/codex",
    "Contents/Resources/BundledRuntime/ThirdPartyLicenses/OpenAI-Codex-Apache-2.0.txt",
    "Contents/Resources/BundledRuntime/ThirdPartyLicenses/PostgreSQL.txt",
    "Contents/Resources/BundledRuntime/ThirdPartyLicenses/Redis.txt",
    "Contents/Resources/BundledRuntime/ThirdPartyLicenses/Sub2API-LGPL-3.0.txt",
}
executable_inventory = {
    "Contents/MacOS/AgentHub",
    "Contents/Helpers/agenthub-totp",
    "Contents/Helpers/agenthub-task",
}
generated_files = {
    "Contents/Resources/AgentHubRelease.json",
    "Contents/_CodeSignature/CodeResources",
}
if manifest.get("schemaVersion") != 2:
    raise SystemExit("release manifest schemaVersion mismatch")
if manifest.get("version") != info.get("CFBundleShortVersionString"):
    raise SystemExit("release manifest version mismatch")
if manifest.get("buildNumber") != info.get("CFBundleVersion"):
    raise SystemExit("release manifest build number mismatch")
if set(manifest.get("features") or []) != expected_features:
    raise SystemExit("release manifest feature inventory mismatch")
if manifest.get("signing") != {"kind": "adhoc"}:
    raise SystemExit("release manifest signing requirement mismatch")
if manifest.get("sourceDirty"):
    raise SystemExit("release manifest was built from a dirty worktree")
expected_commit = os.environ.get("EXPECTED_COMMIT")
if expected_commit and manifest.get("sourceCommit") != expected_commit:
    raise SystemExit("release manifest source commit mismatch")

inventory = manifest.get("fileInventory")
if not isinstance(inventory, dict) or set(inventory) != expected_inventory_files:
    raise SystemExit("release manifest fileInventory mismatch")
for relative in executable_inventory:
    if inventory.get(relative) != {"validation": "codesign+lipo"}:
        raise SystemExit(f"release executable validation mismatch: {relative}")

actual_files = set()
for path in (app / "Contents").rglob("*"):
    if path.is_symlink():
        raise SystemExit(f"release app contains a symlink: {path}")
    if path.is_dir():
        continue
    if not path.is_file():
        raise SystemExit(f"release app contains a special file: {path}")
    actual_files.add(f"Contents/{path.relative_to(app / 'Contents').as_posix()}")
if actual_files != set(inventory) | generated_files:
    missing = sorted((set(inventory) | generated_files) - actual_files)
    extra = sorted(actual_files - (set(inventory) | generated_files))
    raise SystemExit(f"release app fileInventory mismatch: missing={missing}, extra={extra}")

for relative, expected in inventory.items():
    path = app / relative
    if relative in executable_inventory:
        continue
    if not isinstance(expected, dict) or set(expected) != {"size", "mode", "sha256"}:
        raise SystemExit(f"release file metadata is incomplete: {relative}")
    if expected["size"] != path.stat().st_size:
        raise SystemExit(f"release artifact size mismatch: {relative}")
    actual_mode = format(stat.S_IMODE(path.stat().st_mode), "04o")
    if expected["mode"] != actual_mode:
        raise SystemExit(f"release artifact mode mismatch: {relative}")
    if not isinstance(expected["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", expected["sha256"]):
        raise SystemExit(f"release artifact SHA-256 is invalid: {relative}")
    path = app / relative
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected["sha256"]:
        raise SystemExit(f"release artifact digest mismatch: {relative}")
runtime = manifest.get("runtime") or {}
if runtime.get("codex") != "0.149.0":
    raise SystemExit("release Codex version mismatch")
if runtime.get("sub2api") != "0.1.179" or runtime.get("postgresql") != "18-alpine" or runtime.get("redis") != "8-alpine":
    raise SystemExit("release runtime version mismatch")
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
task_help_output="$($task_binary --help 2>&1 || true)"
[[ "$task_help_output" == *"session-start"* && "$task_help_output" == *"heartbeat"* ]] || { echo "agenthub-task help is incomplete" >&2; exit 1; }
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
  secret=$(openssl rand -hex 32)
  cp "$runtime_dir/docker-compose.yml" "$smoke_compose"
  cat > "$smoke_env" <<EOF
SUB2API_VERSION=0.1.179
SERVER_PORT=$port
RUN_MODE=simple
SIMPLE_MODE_CONFIRM=true
POSTGRES_USER=agenthub
POSTGRES_PASSWORD=$secret
POSTGRES_DB=agenthub
REDIS_PASSWORD=$secret
ADMIN_EMAIL=admin@agenthub.local
ADMIN_PASSWORD=$secret
JWT_SECRET=$secret
TOTP_ENCRYPTION_KEY=$secret
TZ=UTC
CONTAINER_PREFIX=$smoke_project
EOF
  docker compose --project-name "$smoke_project" --env-file "$smoke_env" --file "$smoke_compose" config >/dev/null
  if ! docker compose --project-name "$smoke_project" --env-file "$smoke_env" --file "$smoke_compose" up -d --pull never --wait --wait-timeout 180; then
    echo "Bundled runtime failed to become healthy. Container status:" >&2
    docker compose --project-name "$smoke_project" --env-file "$smoke_env" --file "$smoke_compose" ps >&2 || true
    echo "Bundled runtime logs (test secrets redacted):" >&2
    docker compose --project-name "$smoke_project" --env-file "$smoke_env" --file "$smoke_compose" \
      logs --no-color --tail 200 sub2api postgres redis 2>&1 \
      | sed "s/$secret/[REDACTED]/g" >&2 || true
    exit 1
  fi
  health_body=$(curl -fsS --retry 20 --retry-delay 2 --retry-all-errors "http://127.0.0.1:$port/health")
  [[ -n "$health_body" ]] || { echo "Sub2API health response is empty" >&2; exit 1; }
  docker compose --project-name "$smoke_project" --env-file "$smoke_env" --file "$smoke_compose" ps
  docker compose --project-name "$smoke_project" --env-file "$smoke_env" --file "$smoke_compose" down -v --remove-orphans >/dev/null
  [[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$smoke_project")" ]] || {
    echo "Runtime smoke containers were not cleaned up" >&2
    exit 1
  }
  echo "runtime smoke ok: bundled Sub2API/PostgreSQL/Redis healthy on 127.0.0.1:$port"
fi

echo "release verification passed: $app_dir"
