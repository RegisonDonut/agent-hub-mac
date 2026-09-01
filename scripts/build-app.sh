#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/dist/AgentHub.app"
contents_dir="$app_dir/Contents"
cli_dir="$contents_dir/Helpers"

if [[ "$app_dir" != "$project_dir/dist/AgentHub.app" ]]; then
  echo "Unexpected app output path" >&2
  exit 1
fi
rm -rf "$app_dir"

# Resolve Swift through xcrun rather than PATH. A stale toolchain manager shim
# (e.g. ~/.swiftly/bin/swift pointing at a removed toolchain) otherwise shadows
# the working compiler and fails with "xcbuild ... does not exist".
swift_bin=$(xcrun --find swift 2>/dev/null || true)
if [[ -z "$swift_bin" ]]; then
  swift_bin=$(command -v swift || true)
fi
if [[ -z "$swift_bin" ]]; then
  echo "No usable Swift toolchain found (tried xcrun and PATH)" >&2
  exit 1
fi

cd "$project_dir"
if [[ "$configuration" == "release" ]]; then
  "$swift_bin" build -c release --arch arm64 --arch x86_64
  binary_path=$("$swift_bin" build -c release --arch arm64 --arch x86_64 --show-bin-path)/AgentHub
  cli_binary_path=$("$swift_bin" build -c release --arch arm64 --arch x86_64 --show-bin-path)/agenthub-totp
else
  "$swift_bin" build -c "$configuration"
  binary_path=$("$swift_bin" build -c "$configuration" --show-bin-path)/AgentHub
  cli_binary_path=$("$swift_bin" build -c "$configuration" --show-bin-path)/agenthub-totp
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$cli_dir"
cp "$binary_path" "$contents_dir/MacOS/AgentHub"
cp "$cli_binary_path" "$cli_dir/agenthub-totp"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
if [[ -d "$project_dir/Resources/BundledRuntime" ]]; then
  ditto "$project_dir/Resources/BundledRuntime" "$contents_dir/Resources/BundledRuntime"
fi
chmod +x "$contents_dir/MacOS/AgentHub"
chmod +x "$cli_dir/agenthub-totp"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$contents_dir/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$contents_dir/Info.plist")
source_commit=$(git -C "$project_dir" rev-parse HEAD)
source_dirty=false
if [[ -n "$(git -C "$project_dir" status --porcelain)" ]]; then
  source_dirty=true
fi
sign_identity="${AGENTHUB_CODESIGN_IDENTITY:--}"
signing_kind="certificate"
if [[ "$sign_identity" == "-" ]]; then
  signing_kind="adhoc"
fi
AGENTHUB_MANIFEST_PATH="$contents_dir/Resources/AgentHubRelease.json" \
AGENTHUB_RUNTIME_DIR="$contents_dir/Resources/BundledRuntime" \
AGENTHUB_SOURCE_FILE="$project_dir/Sources/QuotaBar/Sub2APIServiceManager.swift" \
AGENTHUB_VERSION="$version" \
AGENTHUB_BUILD_NUMBER="$build_number" \
AGENTHUB_SOURCE_COMMIT="$source_commit" \
AGENTHUB_SOURCE_DIRTY="$source_dirty" \
AGENTHUB_SIGNING_KIND="$signing_kind" \
python3 - <<'PY'
import datetime
import hashlib
import json
import os
import re
import stat
import textwrap
from pathlib import Path

manifest_path = Path(os.environ["AGENTHUB_MANIFEST_PATH"])
runtime_dir = Path(os.environ["AGENTHUB_RUNTIME_DIR"])
source = Path(os.environ["AGENTHUB_SOURCE_FILE"]).read_text(encoding="utf-8")
compose_match = re.search(r'static let composeFile = """(.*?)"""', source, re.S)
if not compose_match:
    raise SystemExit("could not extract Sub2API composeFile")
compose = textwrap.dedent(compose_match.group(1)).strip("\n") + "\n"
(runtime_dir / "docker-compose.yml").write_text(compose, encoding="utf-8")
versions = {}
for line in (runtime_dir / "VERSIONS.txt").read_text(encoding="utf-8").splitlines():
    if ":" in line:
        key, value = line.split(":", 1)
        versions[key.strip()] = value.strip()

contents_dir = manifest_path.parents[1]
executable_paths = {
    "Contents/MacOS/AgentHub",
    "Contents/Helpers/agenthub-totp",
}
file_inventory = {}
for path in sorted(contents_dir.rglob("*")):
    if path.is_symlink():
        raise SystemExit(f"release bundle cannot contain symlinks: {path}")
    if path.is_dir():
        continue
    if not path.is_file():
        raise SystemExit(f"release bundle contains a special file: {path}")
    relative = f"Contents/{path.relative_to(contents_dir).as_posix()}"
    if relative in executable_paths:
        file_inventory[relative] = {"validation": "codesign+lipo"}
        continue
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    file_inventory[relative] = {
        "size": path.stat().st_size,
        "mode": format(stat.S_IMODE(path.stat().st_mode), "04o"),
        "sha256": digest.hexdigest(),
    }

manifest = {
    "schemaVersion": 2,
    "version": os.environ["AGENTHUB_VERSION"],
    "buildNumber": os.environ["AGENTHUB_BUILD_NUMBER"],
    "sourceCommit": os.environ["AGENTHUB_SOURCE_COMMIT"],
    "sourceDirty": os.environ["AGENTHUB_SOURCE_DIRTY"] == "true",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "architectures": ["arm64", "x86_64"],
    "features": [
        "codex-account-management",
        "multi-account-routing",
        "quota-and-work-dashboard",
        "totp-manager",
        "touch-id-session-authorization",
        "agenthub-totp-cli",
        "offline-sub2api-runtime",
    ],
    "signing": {"kind": os.environ["AGENTHUB_SIGNING_KIND"]},
    "fileInventory": file_inventory,
    "runtime": {
        "codex": versions.get("OpenAI Codex CLI"),
        "sub2api": versions.get("Sub2API"),
        "postgresql": versions.get("PostgreSQL"),
        "redis": versions.get("Redis"),
        "images": [
            f"weishaw/sub2api:{versions.get('Sub2API')}",
            f"postgres:{versions.get('PostgreSQL')}",
            f"redis:{versions.get('Redis')}",
        ],
    },
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

# Restricted entitlements such as application-identifier and
# keychain-access-groups require a certificate-backed signing identity. They
# make macOS reject an ad hoc build before launch, so local builds deliberately
# omit them. A distribution build can opt in with a real identity.
codesign_options=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" && "${AGENTHUB_USE_RESTRICTED_ENTITLEMENTS:-0}" == "1" ]]; then
  codesign_options+=(--entitlements "$project_dir/Resources/AgentHub.entitlements")
fi
codesign "${codesign_options[@]}" "$cli_dir/agenthub-totp"
codesign --deep "${codesign_options[@]}" "$app_dir"

# A build that ships images the compose file never references starts fine on a
# dev machine and dies on a clean install. Refuse to hand out such a build.
"$project_dir/scripts/verify-bundle.sh" "$app_dir"

echo "$app_dir"
