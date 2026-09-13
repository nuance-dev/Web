#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_directory="${WEB_BUILD_DIR:-$project_root/build}"
signing_identity="${WEB_SIGNING_IDENTITY:--}"

xcodebuild -project "$project_root/Web.xcodeproj" -scheme Web \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build_directory" \
  CODE_SIGNING_ALLOWED=NO build

app_path="$build_directory/Build/Products/Release/Web.app"
# Keep build-machine debug paths and local symbols out of the shipped executable.
xcrun strip -S -x "$app_path/Contents/MacOS/Web"
if LC_ALL=C grep -aEq '/(Users|home)/' "$app_path/Contents/MacOS/Web"; then
  printf '%s\n' 'The executable contains a local source path. Refusing to sign it.' >&2
  exit 1
fi
codesign --force --deep --options runtime --sign "$signing_identity" \
  --entitlements "$project_root/Web/Web.entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built: %s\n' "$app_path"
if [[ "$signing_identity" == '-' ]]; then
  printf '%s\n' 'Ad-hoc signed for local use. Public distribution requires Developer ID signing and notarization.'
fi
# Public distribution also requires a Developer ID identity and notarization.
