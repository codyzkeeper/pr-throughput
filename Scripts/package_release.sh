#!/bin/zsh
set -euo pipefail

workspace_dir="${0:A:h:h}"
app="$workspace_dir/outputs/PRThroughput.app"
output_dir="$workspace_dir/outputs"

if [[ ! -d "$app" ]]; then
  print -u2 "Build the app first with Scripts/build_release.sh."
  exit 66
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
staging_dir="$(mktemp -d "$workspace_dir/build/package.XXXXXX")"
volume_dir="$staging_dir/volume"
zip_tmp="$staging_dir/PR-Throughput-v$version.zip"
dmg_tmp="$staging_dir/PR-Throughput-v$version.dmg"
checksum_tmp="$staging_dir/SHA256SUMS.txt"

cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

mkdir -p "$volume_dir" "$output_dir"
ditto "$app" "$volume_dir/PR Throughput.app"
ln -s /Applications "$volume_dir/Applications"

ditto -c -k --sequesterRsrc --keepParent "$volume_dir/PR Throughput.app" "$zip_tmp"
hdiutil create \
  -volname "PR Throughput" \
  -srcfolder "$volume_dir" \
  -format UDZO \
  -fs HFS+ \
  -ov \
  "$dmg_tmp" >/dev/null

(cd "$staging_dir" && shasum -a 256 "${zip_tmp:t}" "${dmg_tmp:t}") >"$checksum_tmp"

mv -f "$zip_tmp" "$output_dir/${zip_tmp:t}"
mv -f "$dmg_tmp" "$output_dir/${dmg_tmp:t}"
mv -f "$checksum_tmp" "$output_dir/SHA256SUMS-v$version.txt"

print "$output_dir/${dmg_tmp:t}"
print "$output_dir/${zip_tmp:t}"
print "$output_dir/SHA256SUMS-v$version.txt"
