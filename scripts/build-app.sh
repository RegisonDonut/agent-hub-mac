#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/dist/AgentHub.app"
contents_dir="$app_dir/Contents"

cd "$project_dir"
swift build -c "$configuration"
binary_path=$(swift build -c "$configuration" --show-bin-path)/AgentHub

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_path" "$contents_dir/MacOS/AgentHub"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
chmod +x "$contents_dir/MacOS/AgentHub"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
