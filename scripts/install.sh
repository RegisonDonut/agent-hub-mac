#!/bin/zsh
set -euo pipefail

repo_url="https://github.com/RegisonDonut/agent-hub-mac.git"
install_root="$HOME/Applications"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-install.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

command -v git >/dev/null || { echo "需要先安装 Git。" >&2; exit 1; }
command -v swift >/dev/null || { echo "需要先安装 Xcode Command Line Tools：xcode-select --install" >&2; exit 1; }

git clone --depth 1 "$repo_url" "$work_dir/agent-hub-mac"
cd "$work_dir/agent-hub-mac"
chmod +x scripts/build-app.sh
./scripts/build-app.sh release

mkdir -p "$install_root"
rm -rf "$install_root/AgentHub.app"
cp -R "dist/AgentHub.app" "$install_root/AgentHub.app"
open "$install_root/AgentHub.app"

echo "AgentHub 已安装到 $install_root/AgentHub.app"
