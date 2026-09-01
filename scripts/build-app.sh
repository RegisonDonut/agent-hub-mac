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
AGENTHUB_MANIFEST_PATH="$contents_dir/Resources/AgentHubRelease.json" \
AGENTHUB_RUNTIME_DIR="$contents_dir/Resources/BundledRuntime" \
AGENTHUB_VERSION="$version" \
AGENTHUB_BUILD_NUMBER="$build_number" \
AGENTHUB_SOURCE_COMMIT="$source_commit" \
AGENTHUB_SOURCE_DIRTY="$source_dirty" \
python3 - <<'PY'
import datetime
import hashlib
import json
import os
from pathlib import Path

manifest_path = Path(os.environ["AGENTHUB_MANIFEST_PATH"])
runtime_dir = Path(os.environ["AGENTHUB_RUNTIME_DIR"])
versions = {}
for line in (runtime_dir / "VERSIONS.txt").read_text(encoding="utf-8").splitlines():
    if ":" in line:
        key, value = line.split(":", 1)
        versions[key.strip()] = value.strip()

hashed_files = {}
for relative in (
    "VERSIONS.txt",
    "docker-images-arm64.tar.gz",
    "docker-images-x86_64.tar.gz",
    "arm64/codex",
    "x86_64/codex",
):
    path = runtime_dir / relative
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    hashed_files[f"Contents/Resources/BundledRuntime/{relative}"] = digest.hexdigest()

manifest = {
    "schemaVersion": 1,
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
    "requiredFiles": [
        "Contents/MacOS/AgentHub",
        "Contents/Helpers/agenthub-totp",
        "Contents/Resources/BundledRuntime/VERSIONS.txt",
        "Contents/Resources/BundledRuntime/docker-images-arm64.tar.gz",
        "Contents/Resources/BundledRuntime/docker-images-x86_64.tar.gz",
        "Contents/Resources/BundledRuntime/arm64/codex",
        "Contents/Resources/BundledRuntime/x86_64/codex",
        "Contents/Resources/BundledRuntime/ThirdPartyLicenses/OpenAI-Codex-Apache-2.0.txt",
        "Contents/Resources/BundledRuntime/ThirdPartyLicenses/PostgreSQL.txt",
        "Contents/Resources/BundledRuntime/ThirdPartyLicenses/Redis.txt",
        "Contents/Resources/BundledRuntime/ThirdPartyLicenses/Sub2API-LGPL-3.0.txt",
    ],
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
    "sha256": hashed_files,
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

# Restricted entitlements such as application-identifier and
# keychain-access-groups require a certificate-backed signing identity. They
# make macOS reject an ad hoc build before launch, so local builds deliberately
# omit them. A distribution build can opt in with a real identity.
sign_identity="${AGENTHUB_CODESIGN_IDENTITY:--}"
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
