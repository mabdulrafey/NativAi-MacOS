#!/usr/bin/env bash
# ==============================================================================
# NativAI — Test Suite Runner
# Runs all 110 unit tests for NativAI Core services and models.
#
# Usage:
#   ./test.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_PATH="/tmp/nativai_test_build"

echo "🧪 Running NativAI Core Test Suite..."

# Auto-detect Xcode developer tools & macro plugin path
XCODE_PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
XCODE_FRAMEWORKS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
XCODE_USRLIB="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib"
XCTEST_BIN="/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"

EXTRA_FLAGS=()
if [[ -d "${XCODE_PLUGINS}" ]]; then
    EXTRA_FLAGS+=(
        "-Xswiftc" "-plugin-path" "-Xswiftc" "${XCODE_PLUGINS}"
        "-Xswiftc" "-F" "-Xswiftc" "${XCODE_FRAMEWORKS}"
        "-Xswiftc" "-I" "-Xswiftc" "${XCODE_USRLIB}"
        "-Xlinker" "-F" "-Xlinker" "${XCODE_FRAMEWORKS}"
        "-Xlinker" "-L" "-Xlinker" "${XCODE_USRLIB}"
        "-Xlinker" "-rpath" "-Xlinker" "${XCODE_FRAMEWORKS}"
    )
fi

# Build test target in a clean staging build path to avoid filesystem attribute conflicts
(
    cd "${SCRIPT_DIR}"
    swift build --build-tests --build-path "${BUILD_PATH}" "${EXTRA_FLAGS[@]}"
)

TEST_BUNDLE="${BUILD_PATH}/out/Products/Debug/NativAICoreTests.xctest"

if [[ ! -d "${TEST_BUNDLE}" ]]; then
    TEST_BUNDLE="$(find "${BUILD_PATH}" -name "NativAICoreTests.xctest" | head -n 1)"
fi

if [[ -z "${TEST_BUNDLE}" || ! -d "${TEST_BUNDLE}" ]]; then
    echo "❌ Error: Test bundle not found in ${BUILD_PATH}"
    exit 1
fi

echo "🚀 Executing test bundle: ${TEST_BUNDLE}"
"${XCTEST_BIN}" "${TEST_BUNDLE}"
echo "✅ All NativAI tests passed successfully!"
