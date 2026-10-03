#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "Usage: zsh scripts/verify-app.sh /path/to/Superbar.app [arm64|x86_64]"
  exit 2
fi
verify_app="${1:A}"
verify_arch="${2:-$(uname -m)}"
case "$verify_arch" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported expected architecture: $verify_arch"; exit 2 ;;
esac

plist="$verify_app/Contents/Info.plist"
binary="$verify_app/Contents/MacOS/Superbar"
receipt="$verify_app/Contents/Resources/BuildInfo.plist"
[[ -f "$plist" && -x "$binary" && -f "$receipt" ]] || { print -u2 "Incomplete app bundle: $verify_app"; exit 1; }
[[ -f "$verify_app/Contents/Resources/LICENSE" ]] || { print -u2 'App is missing its source license'; exit 1; }

plutil -lint "$plist" "$receipt"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")
[[ "$bundle_id" == io.github.amtbsl.superbar ]] || { print -u2 "Unexpected bundle identifier: $bundle_id"; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist") == Superbar ]] || { print -u2 'Unexpected bundle executable'; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$plist") == 13.0 ]] || { print -u2 'Info.plist minimum macOS version is not 13.0'; exit 1; }
[[ $(lipo -archs "$binary") == "$verify_arch" ]] || { print -u2 "Mach-O architecture does not match $verify_arch"; exit 1; }

# Verify the load command independently; Info.plist alone is insufficient.
load_commands=$(xcrun vtool -show-build "$binary")
print -r -- "$load_commands"
print -r -- "$load_commands" | awk '
  $1 == "platform" { platforms++; if ($2 != "MACOS") bad = 1 }
  $1 == "minos" { minimums++; if ($2 != "13.0") bad = 1 }
  END { exit bad || platforms != 1 || minimums != 1 }
' || { print -u2 'Mach-O minimum deployment target is not macOS 13.0'; exit 1; }

[[ $(/usr/libexec/PlistBuddy -c 'Print Architecture' "$receipt") == "$verify_arch" ]] || { print -u2 'Build receipt architecture mismatch'; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print MinimumSystemVersion' "$receipt") == 13.0 ]] || { print -u2 'Build receipt deployment target mismatch'; exit 1; }
source_hash=$(/usr/libexec/PlistBuddy -c 'Print SourceFingerprint' "$receipt")
[[ "$source_hash" =~ '^[0-9a-f]{64}$' ]] || { print -u2 'Invalid source fingerprint'; exit 1; }

codesign --verify --deep --strict --verbose=2 "$verify_app"
signature=$(codesign -dv "$verify_app" 2>&1)
print -r -- "$signature" | awk -F= -v expected="$bundle_id" '$1 == "Identifier" { found = ($2 == expected) } END { exit !found }' \
  || { print -u2 'Code-signing identifier mismatch'; exit 1; }
binary_hash=$(shasum -a 256 "$binary" | awk '{print $1}')
print "PASS app structure, architecture $verify_arch, Mach-O macOS 13.0 target, strict code signature; binary SHA-256 $binary_hash"
