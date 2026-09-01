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
