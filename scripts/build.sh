#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

build_arch="${SUPERBAR_ARCH:-$(uname -m)}"
case "$build_arch" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported architecture: $build_arch (use arm64 or x86_64)"; exit 2 ;;
esac

mkdir -p build
stage_root=$(mktemp -d "$PWD/build/.app-build.XXXXXX")
trap 'rm -rf -- "$stage_root"' EXIT
stage_app="$stage_root/Superbar.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
source_hash=$(zsh scripts/source-fingerprint.sh "$PWD")

# Generate resources afresh so an earlier build cannot leave stale bundle files.
xcrun swift scripts/make-icon.swift "$stage_root/AppIcon.iconset"
iconutil -c icns "$stage_root/AppIcon.iconset" -o "$stage_app/Contents/Resources/AppIcon.icns"
xcrun swiftc -swift-version 5 -O -target "$build_arch-apple-macosx13.0" \
  Sources/Superbar/*.swift -o "$stage_app/Contents/MacOS/Superbar" \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement -framework ScreenCaptureKit
cp Resources/Info.plist "$stage_app/Contents/Info.plist"
cp LICENSE "$stage_app/Contents/Resources/LICENSE"

[[ "$source_hash" == $(zsh scripts/source-fingerprint.sh "$PWD") ]] || { print -u2 'Build inputs changed during compilation; repeat the build after edits finish.'; exit 1; }
source_revision=$(git rev-parse HEAD 2>/dev/null || print unavailable)
receipt="$stage_app/Contents/Resources/BuildInfo.plist"
cat > "$receipt" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :SourceFingerprint string $source_hash" "$receipt"
/usr/libexec/PlistBuddy -c "Add :Revision string $source_revision" "$receipt"
/usr/libexec/PlistBuddy -c "Add :Architecture string $build_arch" "$receipt"
/usr/libexec/PlistBuddy -c 'Add :MinimumSystemVersion string 13.0' "$receipt"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$stage_app/Contents/Info.plist")
codesign --force --sign - --identifier "$bundle_id" "$stage_app"
zsh scripts/verify-app.sh "$stage_app" "$build_arch"

# Publish the completed bundle only after compilation and verification succeed.
if [[ -e build/Superbar.app ]]; then mv build/Superbar.app "$stage_root/previous.app"; fi
if ! mv "$stage_app" build/Superbar.app; then
  if [[ -e "$stage_root/previous.app" ]]; then mv "$stage_root/previous.app" build/Superbar.app; fi
  exit 1
fi
print "Built $PWD/build/Superbar.app ($build_arch, minimum macOS 13.0). Native UI acceptance remains separate."
