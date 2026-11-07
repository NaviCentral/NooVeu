#!/usr/bin/env bash
# Builds NooVeu.app in build/ (which git ignores), ad-hoc signed for running on this Mac.
#
#   scripts/bundle-app.sh [--version X.Y.Z]
#
# The result is for local use. Ad-hoc signing lets macOS run it from the Mac that built it; a
# copy given to another Mac needs Developer ID signing and notarisation (not set up yet), or
# Gatekeeper will refuse it.
#
# Steps: build the release binary, draw the placeholder icon, write Info.plist, sign, verify.
set -euo pipefail
cd "$(dirname "$0")/.."

version="0.1.0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?--version needs a value, e.g. 1.2.3}"; shift 2 ;;
    *) echo "usage: $0 [--version X.Y.Z]" >&2; exit 64 ;;
  esac
done

root="$PWD"
out="$root/build/NooVeu.app"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Assemble in a scratch folder and move the finished bundle into place at the end, so a failure
# half way never destroys the last good app.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/NooVeu.app"

echo "Building release binary..."
swift build -c release --product NooVeu
binary="$(swift build -c release --product NooVeu --show-bin-path)/NooVeu"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/NooVeu"
# Drop the debug map: it records absolute paths of the machine that built the binary.
strip -S "$app/Contents/MacOS/NooVeu"

echo "Drawing the icon..."
swift scripts/make-icon.swift "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>NooVeu</string>
  <key>CFBundleDisplayName</key><string>NooVeu</string>
  <key>CFBundleIdentifier</key><string>ch.navicentral.nooveu</string>
  <key>CFBundleExecutable</key><string>NooVeu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build_number}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 NaviCentral. MIT License.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.image</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

echo "Signing (ad hoc)..."
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"

# Only now replace the previous build.
mkdir -p "$root/build"
rm -rf "$out"
mv "$app" "$out"

echo
echo "Built $out (version $version, build $build_number)"
echo "Open it with:  open \"$out\"    or    open -a \"$out\" path/to/image.jpg"
