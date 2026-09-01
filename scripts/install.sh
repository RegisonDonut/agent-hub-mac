#!/bin/zsh
set -euo pipefail

release_url="https://github.com/RegisonDonut/agent-hub-mac/releases/latest/download/AgentHub-macOS.zip"
checksum_url="https://github.com/RegisonDonut/agent-hub-mac/releases/latest/download/AgentHub-macOS.zip.sha256"
install_root="$HOME/Applications"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-install.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

command -v curl >/dev/null || { echo "需要 curl 才能下载安装包。" >&2; exit 1; }

curl --retry 3 --retry-all-errors --connect-timeout 15 -fL "$release_url" -o "$work_dir/AgentHub-macOS.zip"
curl --retry 3 --retry-all-errors --connect-timeout 15 -fL "$checksum_url" -o "$work_dir/AgentHub-macOS.zip.sha256"
(
  cd "$work_dir"
  shasum -a 256 -c AgentHub-macOS.zip.sha256
)
ditto -x -k "$work_dir/AgentHub-macOS.zip" "$work_dir/unpacked"
test -d "$work_dir/unpacked/AgentHub.app" || { echo "安装包内缺少 AgentHub.app。" >&2; exit 1; }
test -x "$work_dir/unpacked/AgentHub.app/Contents/MacOS/AgentHub" || { echo "安装包内缺少 AgentHub 主程序。" >&2; exit 1; }
test -x "$work_dir/unpacked/AgentHub.app/Contents/Helpers/agenthub-totp" || { echo "安装包内缺少 agenthub-totp。" >&2; exit 1; }
test -f "$work_dir/unpacked/AgentHub.app/Contents/Resources/AgentHubRelease.json" || { echo "安装包内缺少 release manifest。" >&2; exit 1; }
codesign --verify --deep --strict "$work_dir/unpacked/AgentHub.app"

mkdir -p "$install_root"
rm -rf "$install_root/AgentHub.app"
cp -R "$work_dir/unpacked/AgentHub.app" "$install_root/AgentHub.app"
xattr -dr com.apple.quarantine "$install_root/AgentHub.app" 2>/dev/null || true
open "$install_root/AgentHub.app"

mkdir -p "$HOME/.local/bin"
ln -sf "$install_root/AgentHub.app/Contents/Helpers/agenthub-totp" "$HOME/.local/bin/agenthub-totp"

echo "AgentHub 已安装到 $install_root/AgentHub.app"
echo "agenthub-totp CLI 已链接到 $HOME/.local/bin/agenthub-totp"
