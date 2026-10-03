#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

if (( $# != 1 )); then print -u2 'Usage: zsh scripts/test-packaging.sh /path/to/Superbar.app'; exit 2; fi
accepted_app="${1:A}"
accepted_arch=$(lipo -archs "$accepted_app/Contents/MacOS/Superbar")
zsh scripts/verify-app.sh "$accepted_app" "$accepted_arch"
mkdir -p build/tests
qa_stage=$(mktemp -d "$PWD/build/tests/.packaging-tests.XXXXXX")
trap 'rm -rf -- "$qa_stage"' EXIT

expect_rejection() {
  local case_name="$1" expected_text="$2" failure_output
  shift 2
  if failure_output=$("$@" 2>&1); then print -u2 "FAIL $case_name unexpectedly succeeded"; exit 1; fi
  [[ "$failure_output" == *"$expected_text"* ]] || { print -u2 "FAIL $case_name failed for an unexpected reason: $failure_output"; exit 1; }
  print "PASS packaging rejects $case_name"
}

if [[ "$accepted_arch" == arm64 ]]; then other_arch=x86_64; else other_arch=arm64; fi
expect_rejection 'wrong architecture' 'Mach-O architecture does not match' zsh scripts/verify-app.sh "$accepted_app" "$other_arch"
expect_rejection 'implicit rebuild request' 'Specify the exact app accepted' zsh scripts/release.sh

fixture_app="$qa_stage/Superbar.app"
ditto "$accepted_app" "$fixture_app"
/usr/libexec/PlistBuddy -c 'Set LSMinimumSystemVersion 14.0' "$fixture_app/Contents/Info.plist"
codesign --force --sign - --identifier io.github.amtbsl.superbar "$fixture_app"
expect_rejection 'incorrect Info.plist minimum' 'Info.plist minimum macOS version is not 13.0' zsh scripts/verify-app.sh "$fixture_app" "$accepted_arch"

/usr/libexec/PlistBuddy -c 'Set LSMinimumSystemVersion 13.0' "$fixture_app/Contents/Info.plist"
print -r -- 'int main(void) { return 0; }' > "$qa_stage/fixture.c"
# This executable is inspected, never run. It proves that a signed bundle with
# a correct plist cannot mask an incorrect Mach-O deployment target.
xcrun clang -target "$accepted_arch-apple-macosx14.0" "$qa_stage/fixture.c" -o "$fixture_app/Contents/MacOS/Superbar"
codesign --force --sign - --identifier io.github.amtbsl.superbar "$fixture_app"
expect_rejection 'incorrect Mach-O minimum' 'Mach-O minimum deployment target is not macOS 13.0' zsh scripts/verify-app.sh "$fixture_app" "$accepted_arch"

rm -rf -- "$fixture_app"
ditto "$accepted_app" "$fixture_app"
print 'modified license resource' >> "$fixture_app/Contents/Resources/LICENSE"
expect_rejection 'tampered signed resource' 'invalid' zsh scripts/verify-app.sh "$fixture_app" "$accepted_arch"

sample_root="$qa_stage/source-sample"
mkdir -p "$sample_root/scripts" "$sample_root/docs" "$sample_root/build"
ditto Sources "$sample_root/Sources"
ditto Resources "$sample_root/Resources"
cp LICENSE "$sample_root/"
cp scripts/build.sh scripts/make-icon.swift scripts/source-fingerprint.sh scripts/verify-app.sh "$sample_root/scripts/"
first_hash=$(zsh scripts/source-fingerprint.sh "$sample_root")
[[ "$first_hash" == $(zsh scripts/source-fingerprint.sh "$sample_root") ]] || { print -u2 'FAIL source fingerprint is not stable'; exit 1; }
print 'documentation fixture' > "$sample_root/docs/qa.md"
print 'private generated fixture' > "$sample_root/build/settings.json"
[[ "$first_hash" == $(zsh scripts/source-fingerprint.sh "$sample_root") ]] || { print -u2 'FAIL docs/private build files unexpectedly affect production identity'; exit 1; }
print '// compilation input changed' >> "$sample_root/Sources/Superbar/Models.swift"
[[ "$first_hash" != $(zsh scripts/source-fingerprint.sh "$sample_root") ]] || { print -u2 'FAIL altered compilation input was not detected'; exit 1; }
print 'PASS source identity detects production changes and ignores generated/documentation files'
print 'PASS packaging guard tests. No fixture executable or app was launched.'
