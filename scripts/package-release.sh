#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/AgentHub.app"
archive="$dist_dir/AgentHub-macOS.zip"
checksum="$dist_dir/AgentHub-macOS.zip.sha256"

if [[ -n "$(git -C "$project_dir" status --porcelain)" ]]; then
  echo "Release packaging requires a clean Git worktree." >&2
  exit 1
fi

commit=$(git -C "$project_dir" rev-parse HEAD)
"$project_dir/scripts/build-app.sh" release

rm -f "$archive" "$checksum"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
"$project_dir/scripts/verify-release.sh" "$archive" --expected-commit "$commit" --runtime-smoke

(
  cd "$dist_dir"
  shasum -a 256 AgentHub-macOS.zip > AgentHub-macOS.zip.sha256
)

echo "$archive"
echo "$checksum"
