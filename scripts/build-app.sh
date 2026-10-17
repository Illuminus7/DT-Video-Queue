#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --scratch-path /private/tmp/dt-video-queue-build
bundle="${PWD}/DT Video Queue.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$(swift build -c release --scratch-path /private/tmp/dt-video-queue-build --show-bin-path)/DTVideoQueue" "$bundle/Contents/MacOS/DTVideoQueue"
resource_bundle="$(swift build -c release --scratch-path /private/tmp/dt-video-queue-build --show-bin-path)/DTVideoQueue_DTVideoQueue.bundle"
cp -R "$resource_bundle" "$bundle/Contents/Resources/"
cp THIRD_PARTY_NOTICES.txt "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DTVideoQueue</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.illuminus7.DTVideoQueue</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>DT Video Queue</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
swift scripts/CreateIcon.swift Assets/AppIcon.iconset
iconutil -c icns Assets/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
staging="/private/tmp/DT Video Queue.app"
rm -rf "$staging"
ditto --norsrc "$bundle" "$staging"
xattr -cr "$staging"
codesign --force --deep --sign - "$staging"
codesign --verify --deep --strict "$staging"
# Signing happens outside iCloud Drive, whose extended attributes break codesign; then the signed app replaces the unsigned one.
rm -rf "$bundle"
ditto --norsrc "$staging" "$bundle"
# iCloud re-adds Finder attributes to the folder at once, so only the staging copy gets the strict check.
codesign --verify --deep "$bundle"
echo "$bundle"
