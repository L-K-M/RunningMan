#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration=release
universal=false
zip_app=false
for argument in "$@"; do
  case "$argument" in
    --debug) configuration=debug ;;
    --universal) universal=true ;;
    --zip) zip_app=true ;;
    *) echo "Usage: scripts/build-app.sh [--debug] [--universal] [--zip]" >&2; exit 2 ;;
  esac
done

build_arguments=(--package-path "$project_root" -c "$configuration" --product RunningMan)
if $universal; then build_arguments+=(--arch arm64 --arch x86_64); fi
swift build "${build_arguments[@]}"
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
output_directory="$project_root/dist"
app="$output_directory/RunningMan.app"
version="${RUNNINGMAN_VERSION:-0.1.0}"
case "$version" in *[!0-9.]*|"") echo "RUNNINGMAN_VERSION must be a numeric version." >&2; exit 2 ;; esac
# CFBundleVersion is the commit count unless RUNNINGMAN_BUILD_NUMBER overrides
# it. A shallow clone counts only the fetched commits, so CI checks out the
# full history; a copy without .git builds with 0 rather than failing.
if [ -n "${RUNNINGMAN_BUILD_NUMBER:-}" ]; then
  build_number="$RUNNINGMAN_BUILD_NUMBER"
elif build_number="$(git -C "$project_root" rev-list --count HEAD 2>/dev/null)"; then
  if [ "$(git -C "$project_root" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    echo "warning: shallow clone, so build number $build_number is not the commit count. Fetch the full history or set RUNNINGMAN_BUILD_NUMBER." >&2
  fi
else
  build_number=0
  echo "warning: no git history, so the build number is 0. Set RUNNINGMAN_BUILD_NUMBER to override it." >&2
fi
case "$build_number" in *[!0-9]*|"") echo "RUNNINGMAN_BUILD_NUMBER must contain only digits." >&2; exit 2 ;; esac
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/RunningMan" "$app/Contents/MacOS/RunningMan"

# Rebuild from the canonical PNG so a stale tracked ICNS never hides new artwork.
swift "$project_root/scripts/make-icon.swift" "$app/Contents/Resources"
cp "$project_root/LICENSE" "$app/Contents/Resources/LICENSE"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.l-k-m.RunningMan</string>
  <key>CFBundleName</key><string>RunningMan</string>
  <key>CFBundleDisplayName</key><string>RunningMan</string>
  <key>CFBundleExecutable</key><string>RunningMan</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
if $zip_app; then
  ditto -c -k --keepParent "$app" "$output_directory/RunningMan.zip"
  (cd "$output_directory" && shasum -a 256 RunningMan.zip > RunningMan.zip.sha256)
fi
echo "Built $app"
