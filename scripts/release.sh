#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

release_app=''
release_parent="$PWD/build/releases"
while (( $# )); do
  case "$1" in
    --app) (( $# >= 2 )) || { print -u2 'Missing --app value'; exit 2; }; release_app="${2:A}"; shift 2 ;;
    --output) (( $# >= 2 )) || { print -u2 'Missing --output value'; exit 2; }; release_parent="${2:A}"; shift 2 ;;
    *) print -u2 "Usage: zsh scripts/release.sh --app /Applications/Superbar.app [--output /path/to/releases]"; exit 2 ;;
  esac
done
[[ -n "$release_app" ]] || { print -u2 'Specify the exact app accepted in native testing with --app. Packaging never rebuilds it.'; exit 2; }
[[ -z $(git status --porcelain --untracked-files=all) ]] || { print -u2 'Commit the reviewed source before release; the checkout must be clean.'; exit 1; }

release_arch=$(lipo -archs "$release_app/Contents/MacOS/Superbar")
zsh scripts/verify-app.sh "$release_app" "$release_arch"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$release_app/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Unsupported release version: $version"; exit 1; }
[[ "$version" == $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist) ]] || { print -u2 'Tested app and source versions differ'; exit 1; }
revision=$(git rev-parse HEAD)
name="Superbar-$version-macos-$release_arch"
source_name="Superbar-$version-source"
release_out="$release_parent/$name"
[[ ! -e "$release_out" ]] || { print -u2 "Release output already exists: $release_out (preserve it or choose a new --output directory)"; exit 1; }
mkdir -p "$release_parent"
stage_root=$(mktemp -d "$release_parent/.release-stage.XXXXXX")
dmg_mounted=false
cleanup() {
  if [[ "$dmg_mounted" == true ]]; then hdiutil detach "$stage_root/dmg-check" >/dev/null || true; fi
  rm -rf -- "$stage_root"
}
trap cleanup EXIT
mkdir -p "$stage_root/assets" "$stage_root/dmg-root" "$stage_root/zip-check" "$stage_root/source-check" "$stage_root/dmg-check"

# Snapshot the already tested app; never sign or mutate the accepted original.
ditto "$release_app" "$stage_root/dmg-root/Superbar.app"
diff -qr "$release_app" "$stage_root/dmg-root/Superbar.app"
zsh scripts/verify-app.sh "$stage_root/dmg-root/Superbar.app" "$release_arch"
cp LICENSE README.md "$stage_root/dmg-root/"
ln -s /Applications "$stage_root/dmg-root/Applications"

# Git commits supply stable timestamps; gzip -n removes host/time metadata.
# Export every tracked source file except private or generated material.
source_files=()
while IFS= read -r -d $'\0' source_file; do
  case "$source_file" in
    build/*|.build/*|.swiftpm/*|local-verification/*|reference-ice/*|reference-*/*|.DS_Store|*/.DS_Store|settings.json|*/settings.json|diagnostics.json|*/diagnostics.json|*.xcuserstate) continue ;;
  esac
  source_files+=("$source_file")
done < <(git ls-tree -r --name-only -z "$revision")
(( ${#source_files} )) || { print -u2 'No source files to archive'; exit 1; }
git archive --format=tar --prefix="$source_name/" "$revision" -- "${source_files[@]}" | gzip -n > "$stage_root/assets/$source_name.tar.gz"
tar -xzf "$stage_root/assets/$source_name.tar.gz" -C "$stage_root/source-check"
source_hash=$(zsh scripts/source-fingerprint.sh "$stage_root/source-check/$source_name")
tested_hash=$(/usr/libexec/PlistBuddy -c 'Print SourceFingerprint' "$stage_root/dmg-root/Superbar.app/Contents/Resources/BuildInfo.plist")
[[ "$source_hash" == "$tested_hash" ]] || { print -u2 'Source archive differs from the inputs used to build the accepted app. Rebuild and repeat native acceptance before packaging.'; exit 1; }
cmp LICENSE "$stage_root/dmg-root/Superbar.app/Contents/Resources/LICENSE"
cmp LICENSE "$stage_root/source-check/$source_name/LICENSE"
zsh scripts/test.sh
zsh scripts/test-packaging.sh "$stage_root/dmg-root/Superbar.app"

ditto -c -k --sequesterRsrc --keepParent "$stage_root/dmg-root/Superbar.app" "$stage_root/assets/$name.zip"
ditto -x -k "$stage_root/assets/$name.zip" "$stage_root/zip-check"
diff -qr "$stage_root/dmg-root/Superbar.app" "$stage_root/zip-check/Superbar.app"
zsh scripts/verify-app.sh "$stage_root/zip-check/Superbar.app" "$release_arch"

hdiutil create -volname "Superbar $version" -srcfolder "$stage_root/dmg-root" -format UDZO "$stage_root/assets/$name.dmg"
hdiutil verify "$stage_root/assets/$name.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$stage_root/dmg-check" "$stage_root/assets/$name.dmg"
dmg_mounted=true
diff -qr "$stage_root/dmg-root/Superbar.app" "$stage_root/dmg-check/Superbar.app"
zsh scripts/verify-app.sh "$stage_root/dmg-check/Superbar.app" "$release_arch"
hdiutil detach "$stage_root/dmg-check"
dmg_mounted=false

# A concurrent rebuild must not silently replace the app during packaging.
diff -qr "$release_app" "$stage_root/dmg-root/Superbar.app"
binary_hash=$(shasum -a 256 "$stage_root/dmg-root/Superbar.app/Contents/MacOS/Superbar" | awk '{print $1}')
cat > "$stage_root/assets/BUILD-MANIFEST.txt" <<MANIFEST
Version: $version
Architecture: $release_arch
Minimum macOS: 13.0 (Mach-O and Info.plist verified)
Source commit: $revision
Source inputs SHA-256: $source_hash
Accepted executable SHA-256: $binary_hash
Input app: $release_app
ZIP and mounted DMG: byte-identical app files and valid strict code signatures
Native acceptance: performed separately by the release operator; packaging does not launch the app
MANIFEST
(
  cd "$stage_root/assets"
  shasum -a 256 "$name.zip" "$name.dmg" "$source_name.tar.gz" BUILD-MANIFEST.txt > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
mv "$stage_root/assets" "$release_out"
print "Release files: $release_out"
print "Accepted executable SHA-256: $binary_hash (no rebuild performed)"
