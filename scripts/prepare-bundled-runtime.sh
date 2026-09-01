#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
runtime_dir="$project_dir/Resources/BundledRuntime"
licenses_dir="$runtime_dir/ThirdPartyLicenses"
codex_version="0.149.0"
sub2api_version="0.1.179"
# Must stay in sync with Sub2APIServiceManager.composeFile. scripts/verify-bundle.sh enforces it.
postgres_image="postgres:18-alpine"
redis_image="redis:8-alpine"
work_dir=$(mktemp -d /tmp/agenthub-runtime.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$runtime_dir/arm64" "$runtime_dir/x86_64" "$licenses_dir"

download_codex() {
  local app_arch="$1"
  local release_arch="$2"
  local archive="$work_dir/codex-$app_arch.tar.gz"
  curl -fL --retry 4 --retry-all-errors \
    "https://github.com/openai/codex/releases/download/rust-v${codex_version}/codex-${release_arch}-apple-darwin.tar.gz" \
    -o "$archive"
  tar -xzf "$archive" -C "$work_dir/codex-$app_arch"
  local binary
  binary=$(find "$work_dir/codex-$app_arch" -type f -name 'codex*' | head -1)
  test -n "$binary"
  cp "$binary" "$runtime_dir/$app_arch/codex"
  chmod +x "$runtime_dir/$app_arch/codex"
}

mkdir -p "$work_dir/codex-arm64" "$work_dir/codex-x86_64"
download_codex arm64 aarch64
download_codex x86_64 x86_64

curl -fL --retry 4 https://raw.githubusercontent.com/openai/codex/rust-v${codex_version}/LICENSE \
  -o "$licenses_dir/OpenAI-Codex-Apache-2.0.txt"
curl -fL --retry 4 https://raw.githubusercontent.com/Wei-Shaw/sub2api/v${sub2api_version}/LICENSE \
  -o "$licenses_dir/Sub2API-LGPL-3.0.txt"
curl -fL --retry 4 https://raw.githubusercontent.com/postgres/postgres/REL_18_STABLE/COPYRIGHT \
  -o "$licenses_dir/PostgreSQL.txt"
curl -fL --retry 4 https://raw.githubusercontent.com/redis/redis/8.0/LICENSE.txt \
  -o "$licenses_dir/Redis.txt"

if [[ "${1:-}" != "--skip-docker" ]]; then
  docker info >/dev/null
  for pair in 'arm64 linux/arm64' 'x86_64 linux/amd64'; do
    app_arch=${pair%% *}
    platform=${pair#* }
    for image in "weishaw/sub2api:${sub2api_version}" "$postgres_image" "$redis_image"; do
      for attempt in 1 2 3; do
        docker pull --platform "$platform" "$image" && break
        if [[ "$attempt" == 3 ]]; then exit 1; fi
        sleep $((attempt * 2))
      done
    done
    docker save "weishaw/sub2api:${sub2api_version}" "$postgres_image" "$redis_image" \
      | gzip -9 > "$runtime_dir/docker-images-${app_arch}.tar.gz"
  done
  if [[ "$(uname -m)" == "arm64" ]]; then
    gzip -dc "$runtime_dir/docker-images-arm64.tar.gz" | docker load
  fi
fi

printf '%s\n' \
  "OpenAI Codex CLI: ${codex_version}" \
  "Sub2API: ${sub2api_version}" \
  "PostgreSQL: ${postgres_image#postgres:}" \
  "Redis: ${redis_image#redis:}" \
  "" \
  "Sub2API source: https://github.com/Wei-Shaw/sub2api/tree/v${sub2api_version}" \
  "Codex source: https://github.com/openai/codex/tree/rust-v${codex_version}" \
  > "$runtime_dir/VERSIONS.txt"

echo "Bundled runtime prepared at $runtime_dir"
