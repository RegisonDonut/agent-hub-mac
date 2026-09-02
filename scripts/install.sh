#!/bin/zsh
set -euo pipefail

release_url="https://github.com/RegisonDonut/agent-hub-mac/releases/latest/download/AgentHub-macOS.zip"
checksum_url="https://github.com/RegisonDonut/agent-hub-mac/releases/latest/download/AgentHub-macOS.zip.sha256"
install_root="$HOME/Applications"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-install.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

command -v curl >/dev/null || { echo "需要 curl 才能下载安装包。" >&2; exit 1; }

cat <<'EOF'
安全说明：安装包会记录固定的签名身份。当前团队证书为自签名证书，并非 Apple Developer ID，且未经过 Apple 公证；在没有团队证书的构建环境中会回退为 ad-hoc 签名。
固定签名身份可以避免升级时被当成另一款 App，但不能替代 Apple 公证。安装器会保留 macOS quarantine；只应从 RegisonDonut/agent-hub-mac 官方 Release 安装。
如果 Gatekeeper 阻止首次打开，请在 Finder 中对 App 使用“打开”并确认，不要移除 quarantine 属性。
EOF

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
test -x "$work_dir/unpacked/AgentHub.app/Contents/Helpers/agenthub-task" || { echo "安装包内缺少 agenthub-task。" >&2; exit 1; }
test -f "$work_dir/unpacked/AgentHub.app/Contents/Resources/AgentHubRelease.json" || { echo "安装包内缺少 release manifest。" >&2; exit 1; }
codesign --verify --deep --strict "$work_dir/unpacked/AgentHub.app"

mkdir -p "$install_root"
rm -rf "$install_root/AgentHub.app"
cp -R "$work_dir/unpacked/AgentHub.app" "$install_root/AgentHub.app"
quarantine_timestamp="$(printf '%x' "$(date +%s)")"
xattr -w com.apple.quarantine "0081;${quarantine_timestamp};AgentHub Installer;" "$install_root/AgentHub.app"
open "$install_root/AgentHub.app"

mkdir -p "$HOME/.local/bin"
ln -sf "$install_root/AgentHub.app/Contents/Helpers/agenthub-totp" "$HOME/.local/bin/agenthub-totp"
ln -sf "$install_root/AgentHub.app/Contents/Helpers/agenthub-task" "$HOME/.local/bin/agenthub-task"

echo "AgentHub 已安装到 $install_root/AgentHub.app"
echo "agenthub-totp CLI 已链接到 $HOME/.local/bin/agenthub-totp"
