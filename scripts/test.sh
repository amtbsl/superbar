#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
test_stage=$(mktemp -d "$PWD/build/tests/.logic-tests.XXXXXX")
trap 'rm -rf -- "$test_stage"' EXIT

# Test the same pure logic used by the app, compiled for this host. This command
# never links native movement/capture services or launches Superbar.
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  Sources/Superbar/Models.swift Sources/Superbar/AppModel.swift Sources/Superbar/SettingsStore.swift \
  Sources/Superbar/MenuLayoutPlanner.swift Sources/Superbar/MenuDiscoveryPolicy.swift \
  Sources/Superbar/MenuCaptureGeometry.swift Sources/Superbar/MenuTemporaryRevealGeometry.swift Tests/*.swift \
  -o "$test_stage/logic-tests" -framework AppKit
"$test_stage/logic-tests"
mv "$test_stage/logic-tests" build/tests/logic-tests
