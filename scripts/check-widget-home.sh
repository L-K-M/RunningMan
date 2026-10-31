#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf "$test_directory"' EXIT
app="$test_directory/WidgetHomeCheck.app"
mkdir -p "$app/Contents/MacOS"
binary="$app/Contents/MacOS/WidgetHomeCheck"
swiftc -module-cache-path "$test_directory/cache" \
  "$project_root/Sources/RunningManWidgets/WidgetAccount.swift" \
  "$project_root/scripts/check-widget-home.swift" -o "$binary"
account_home="$("$binary")"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ch.lkmc.RunningMan.WidgetHomeCheck</string>
  <key>CFBundleName</key><string>WidgetHomeCheck</string>
  <key>CFBundleExecutable</key><string>WidgetHomeCheck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$project_root/Resources/RunningManWidgets.entitlements" "$app"
# Exercise the production lookup with the widget's actual sandbox entitlements.
# No runner files, preferences or live widget snapshots are read or changed.
"$binary" "$account_home"
