#!/bin/zsh
set -euo pipefail

workspace_dir="${0:A:h:h}"
output_dir="$workspace_dir/outputs"
derived_dir="$workspace_dir/build/DerivedData"
mkdir -p "$workspace_dir/build"
staging_dir="$(mktemp -d "$workspace_dir/build/release.XXXXXX")"
staged_app="$staging_dir/PRThroughput.app"
final_app="$output_dir/PRThroughput.app"
previous_app="$staging_dir/previous.app"
github_client_id="${GITHUB_CLIENT_ID:-}"

if [[ -z "$github_client_id" && -f "$workspace_dir/Config/Local.xcconfig" ]]; then
  github_client_id="$(sed -nE 's/^[[:space:]]*GITHUB_CLIENT_ID[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' "$workspace_dir/Config/Local.xcconfig" | head -n 1)"
fi
if [[ -n "$github_client_id" && ! "$github_client_id" =~ ^[A-Za-z0-9_-]{10,}$ ]]; then
  print -u2 "GITHUB_CLIENT_ID must be a public GitHub OAuth client ID."
  exit 64
fi

cleanup() {
  if [[ ! -e "$final_app" && -e "$previous_app" ]]; then
    mv "$previous_app" "$final_app"
  fi
  rm -rf "$staging_dir"
}
trap cleanup EXIT

cd "$workspace_dir"
xcodegen generate
xcodebuild build \
  -project PRThroughput.xcodeproj \
  -scheme PRThroughput \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_dir" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  "GITHUB_CLIENT_ID=$github_client_id"

mkdir -p "$output_dir"
ditto "$derived_dir/Build/Products/Release/PRThroughput.app" "$staged_app"
codesign --force --deep --sign - --entitlements "$workspace_dir/PRThroughput/Resources/PRThroughput.entitlements" "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -e "$final_app" ]]; then
  mv "$final_app" "$previous_app"
fi
if ! mv "$staged_app" "$final_app"; then
  if [[ -e "$previous_app" ]]; then mv "$previous_app" "$final_app"; fi
  exit 1
fi
