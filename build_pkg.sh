#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║              NATIVAI — PKG Builder  (Native SwiftUI, universal)          ║
# ║                                                                          ║
# ║  Builds a signed-ready, notarization-ready .pkg that installs a native  ║
# ║  SwiftUI .app bundling the catalog.json model catalog — no external     ║
# ║  runtime required. Ollama itself is installed by the app on first run.  ║
# ║                                                                          ║
# ║  Usage:  bash build_pkg.sh                                              ║
# ╚══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

APP_NAME="NativAI"
APP_DISPLAY="NativAI"
BUNDLE_ID="com.nativai.app"
VERSION="1.0.0"
INSTALL_PATH="/Applications/${APP_NAME}.app"
BIN_NAME="NativAI"     # matches Package.swift executable target

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build_staging"
PKG_ROOT="${BUILD_DIR}/pkg_root"
SCRIPTS_DIR="${BUILD_DIR}/scripts"
APP_BUNDLE="${PKG_ROOT}${INSTALL_PATH}"
FINAL_PKG="${SCRIPT_DIR}/${APP_NAME}-${VERSION}.pkg"

# Optional signing (set env vars to enable):
#   DEV_ID_APP  = "Developer ID Application: … (TEAMID)"
#   DEV_ID_PKG  = "Developer ID Installer: … (TEAMID)"
DEV_ID_APP="${DEV_ID_APP:-}"
DEV_ID_PKG="${DEV_ID_PKG:-}"

GRN='\033[0;32m'; YLW='\033[0;33m'; RED='\033[0;31m'; RST='\033[0m'

# ── Signing preflight ───────────────────────────────────────────────────────
#
# Catches the mistake that is easiest to make and hardest to diagnose: signing
# with an "Apple Development" certificate instead of a "Developer ID
# Application" one. Development certs are for running on your own registered
# machines — a .pkg signed with one is rejected by Gatekeeper on every other
# Mac, and notarization refuses it outright. The error message at that point
# names neither the cause nor the fix, so it's worth checking here.
signing_preflight() {
    local id="$1" expected="$2" label="$3"
    [[ -z "${id}" ]] && return 0

    if [[ "${id}" != *"${expected}"* ]]; then
        echo -e "  ${RED}✖  ${label} is not a '${expected}' certificate:${RST}"
        echo "       ${id}"
        if [[ "${id}" == *"Apple Development"* ]]; then
            echo -e "  ${YLW}     'Apple Development' certs only work on machines registered to your"
            echo -e "       account. External distribution needs a Developer ID, which requires"
            echo -e "       the paid Apple Developer Program.${RST}"
        fi
        exit 1
    fi

    if ! security find-identity -v -p codesigning | grep -qF "${id}"; then
        echo -e "  ${RED}✖  ${label} not found in keychain:${RST}"
        echo "       ${id}"
        echo "     Available:"
        security find-identity -v -p codesigning | sed 's/^/       /'
        exit 1
    fi
}

signing_preflight "${DEV_ID_APP:-}" "Developer ID Application" "DEV_ID_APP"
signing_preflight "${DEV_ID_PKG:-}" "Developer ID Installer" "DEV_ID_PKG"

# Signing the .app without also signing the .pkg (or vice versa) produces a
# build that passes one Gatekeeper check and fails the other.
if [[ -n "${DEV_ID_APP:-}" && -z "${DEV_ID_PKG:-}" ]] \
   || [[ -z "${DEV_ID_APP:-}" && -n "${DEV_ID_PKG:-}" ]]; then
    echo -e "  ${YLW}⚠  Only one of DEV_ID_APP / DEV_ID_PKG is set — set both, or neither.${RST}"
fi
step() { echo -e "\n${GRN}  [$1/6]${RST} $2"; }
fail() { echo -e "${RED}  ✗  $1${RST}"; exit 1; }

echo ""
echo "  ╔──────────────────────────────────────────────────╗"
echo "  ║  NativAI — PKG Builder                            ║"
echo "  ║  Native SwiftUI · universal (arm64 + x86_64)       ║"
echo "  ╚──────────────────────────────────────────────────╝"

# ── 1. Verify sources ──────────────────────────────────────────────────────
step 1 "Verifying sources …"
[[ -f "${SCRIPT_DIR}/Package.swift" ]] || fail "Missing: Package.swift"
[[ -d "${SCRIPT_DIR}/Sources" ]]       || fail "Missing: Sources/"
CATALOG_SRC="${SCRIPT_DIR}/Sources/${BIN_NAME}/Resources/catalog.json"
[[ -f "${CATALOG_SRC}" ]] || fail "Missing: ${CATALOG_SRC}"
echo "  ✔ catalog.json → ${CATALOG_SRC}"

# ── 2. Compile release binary (UNIVERSAL: arm64 + x86_64) ──────────────────
step 2 "Compiling universal binary (arm64 + x86_64) …"
rm -rf "${BUILD_DIR}"
RELEASE_BIN=""

# Preferred path: SwiftPM with both architectures.
if ( cd "${SCRIPT_DIR}" && swift build -c release --arch arm64 --arch x86_64 ) 2>/dev/null; then
    RELEASE_BIN="${SCRIPT_DIR}/.build/apple/Products/Release/${BIN_NAME}"
    [[ -f "${RELEASE_BIN}" ]] || RELEASE_BIN="${SCRIPT_DIR}/.build/release/${BIN_NAME}"
    echo "  ✔ Built universal via swift build"
fi

# Fallback: direct swiftc — build each slice, then merge with lipo. Works in
# restricted/sandboxed shells where SwiftPM's manifest sandbox can't run.
# NOTE: this fallback only compiles .swift sources directly and will NOT
# process SwiftPM resources (catalog.json) — the resource copy step below
# handles that separately regardless of which build path succeeded.
if [[ -z "${RELEASE_BIN}" || ! -f "${RELEASE_BIN}" ]]; then
    echo -e "  ${YLW}⚠  swift build unavailable — falling back to swiftc + lipo${RST}"
    SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
    mkdir -p "${BUILD_DIR}"
    SRC=($(find "${SCRIPT_DIR}/Sources/${BIN_NAME}" -name '*.swift'))
    echo "    • arm64 slice …"
    swiftc -O -sdk "${SDK}" -target arm64-apple-macosx14.0 \
        -o "${BUILD_DIR}/bin_arm64" "${SRC[@]}" || fail "swiftc arm64 build failed"
    echo "    • x86_64 slice …"
    swiftc -O -sdk "${SDK}" -target x86_64-apple-macosx14.0 \
        -o "${BUILD_DIR}/bin_x86" "${SRC[@]}" || fail "swiftc x86_64 build failed"
    RELEASE_BIN="${BUILD_DIR}/${BIN_NAME}"
    lipo -create "${BUILD_DIR}/bin_arm64" "${BUILD_DIR}/bin_x86" \
        -output "${RELEASE_BIN}" || fail "lipo merge failed"
    echo "  ✔ Built universal via swiftc + lipo"
fi
[[ -f "${RELEASE_BIN}" ]] || fail "Built binary not found: ${RELEASE_BIN}"

# Verify BOTH architectures are present — hard-fail if not, so we never ship
# an accidentally single-arch binary.
ARCHS="$(lipo -archs "${RELEASE_BIN}" 2>/dev/null || echo "")"
echo "  ✔ Architectures: ${ARCHS}"
[[ "${ARCHS}" == *"arm64"* && "${ARCHS}" == *"x86_64"* ]] \
    || fail "Universal check failed — expected arm64 + x86_64, got: ${ARCHS}"
echo "  ✔ Binary: ${RELEASE_BIN}"

# ── 3. Assemble .app bundle ────────────────────────────────────────────────
step 3 "Assembling .app bundle …"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${SCRIPTS_DIR}"

cp "${RELEASE_BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Bundle resources: catalog.json (SwiftPM's Bundle.module lookup expects this
# alongside the executable inside Contents/Resources for a hand-assembled bundle)
cp "${CATALOG_SRC}" "${APP_BUNDLE}/Contents/Resources/catalog.json"

# Ship the uninstaller inside the bundle.
#
# This is the only way a user can reclaim the model storage. Dragging the .app to
# the Trash removes ~10 MB and silently leaves Ollama plus tens of gigabytes of
# downloaded models behind in ~/.ollama — a hidden directory most people will
# never find. Shipping it in Contents/Resources means it travels with the app and
# is always the version matching that build.
if [[ -f "${SCRIPT_DIR}/uninstall.sh" ]]; then
    cp "${SCRIPT_DIR}/uninstall.sh" "${APP_BUNDLE}/Contents/Resources/uninstall.sh"
    chmod +x "${APP_BUNDLE}/Contents/Resources/uninstall.sh"
    echo "  ✔ Bundled uninstall.sh"
else
    echo -e "  ${YLW}⚠  uninstall.sh not found — users will have no way to remove models${RST}"
fi
[[ -f "${SCRIPT_DIR}/AppIcon.icns" ]] && \
    cp "${SCRIPT_DIR}/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundleName</key>                <string>${APP_DISPLAY}</string>
    <key>CFBundleDisplayName</key>         <string>${APP_DISPLAY}</string>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>          <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>             <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <false/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <!-- Required for dictation. macOS terminates the process outright — not with
         a catchable error — the first time an app touches the microphone or the
         Speech framework without these strings present. The wording is shown
         verbatim in the system permission dialog, so it states where the audio
         goes: nowhere. Recognition is forced on-device in DictationService, and
         the app refuses to dictate rather than fall back to Apple's servers. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>NativAI uses your microphone only while you hold the dictate button, to turn your speech into text in the message box. Audio is processed entirely on this Mac and is never uploaded or stored.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>NativAI converts your speech to text on-device so you can dictate messages. Your voice never leaves this Mac — if on-device recognition isn't available for your language, dictation is disabled rather than sent to a server.</string>
</dict>
</plist>
PLIST
# NOTE: deliberately no .entitlements file / no com.apple.security.app-sandbox
# key is written anywhere — this app is unsandboxed by construction, which is
# required for it to run `Process` (Ollama install/serve) and reach
# http://127.0.0.1:11434 freely.

# Codesign the app if a Developer ID is provided (hardened runtime for notarization)
#
# Signing failure is treated as fatal rather than a warning. A silently
# unsigned-but-expected-to-be-signed build is the worst outcome: it looks
# successful here, then Gatekeeper blocks it on every machine it's sent to, and
# the failure surfaces to end users instead of at build time.
if [[ -n "${DEV_ID_APP}" ]]; then
    echo "  Signing .app with: ${DEV_ID_APP}"
    if ! codesign --force --deep --options runtime --timestamp \
            --sign "${DEV_ID_APP}" "${APP_BUNDLE}"; then
        echo -e "  ${RED}✖  App signing FAILED — aborting.${RST}"
        echo "     Check the identity exists:  security find-identity -v -p codesigning"
        exit 1
    fi
    # Verify rather than trust the exit code: --deep can report success while
    # leaving a nested binary unsigned, which notarization then rejects.
    if ! codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}" 2>/dev/null; then
        echo -e "  ${RED}✖  Signature verification FAILED — aborting.${RST}"
        exit 1
    fi
    echo "  ✔ App signed and verified"
    # Confirm the hardened runtime actually took. Notarization requires it, and
    # its absence is otherwise only discovered after a round trip to Apple.
    if codesign -d --verbose=2 "${APP_BUNDLE}" 2>&1 | grep -q "flags=.*runtime"; then
        echo "  ✔ Hardened runtime enabled"
    else
        echo -e "  ${YLW}⚠  Hardened runtime flag not detected — notarization will fail${RST}"
    fi
else
    echo -e "  ${YLW}⚠  DEV_ID_APP not set — building UNSIGNED app${RST}"
fi
echo "  ✔ .app bundle ready"

# ── 4. Installer scripts (preinstall = clean-replace, postinstall = launch) ─
step 4 "Writing installer scripts …"

cat > "${SCRIPTS_DIR}/preinstall" <<'EOF'
#!/bin/bash
# Clean-replace: remove any previous installed version so the new one
# starts from a clean state.
INSTALL_PATH="/Applications/NativAI.app"
log() { echo "[preinstall] $*"; }

if [[ -d "${INSTALL_PATH}" ]]; then
    OLD_VER=$(defaults read "${INSTALL_PATH}/Contents/Info.plist" \
        CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Found existing version ${OLD_VER} — removing before reinstall."
    pkill -9 -f "NativAI" 2>/dev/null || true
    sleep 1
    rm -rf "${INSTALL_PATH}"
    log "✔ Removed previous installation"
else
    log "No existing installation found — fresh install."
fi
exit 0
EOF

cat > "${SCRIPTS_DIR}/postinstall" <<'EOF'
#!/bin/bash
# Launch the app once for the current console user, so onboarding
# (spec scan → Ollama install → use-case picker) starts immediately.
INSTALL_PATH="/Applications/NativAI.app"
log() { echo "[postinstall] $*"; }

REAL_USER="${USER:-}"
if [[ -z "${REAL_USER}" || "${REAL_USER}" == "root" ]]; then
    REAL_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
fi

chown -R "${REAL_USER}:staff" "${INSTALL_PATH}" 2>/dev/null || true
chmod -R 755 "${INSTALL_PATH}" 2>/dev/null || true
log "✔ Permissions set"

if [[ -n "${REAL_USER}" ]]; then
    sudo -u "${REAL_USER}" /usr/bin/open "${INSTALL_PATH}" 2>/dev/null || true
    log "✔ Launched NativAI for ${REAL_USER}"
fi
log "✔ Installation complete"
exit 0
EOF

chmod +x "${SCRIPTS_DIR}/preinstall" "${SCRIPTS_DIR}/postinstall"
echo "  ✔ Scripts written"

# ── 5. Component PKG ───────────────────────────────────────────────────────
step 5 "Building component PKG …"
COMPONENT="${BUILD_DIR}/${APP_NAME}.pkg"

# Disable Bundle Relocation. Without this, macOS Installer uses Spotlight to search
# for any existing com.nativai.app on disk (including inside our build directory)
# and installs the payload there instead of placing it into /Applications/NativAI.app.
pkgbuild --analyze --root "${PKG_ROOT}" "${BUILD_DIR}/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "${BUILD_DIR}/components.plist" 2>/dev/null || true

pkgbuild \
    --root             "${PKG_ROOT}" \
    --component-plist  "${BUILD_DIR}/components.plist" \
    --identifier       "${BUNDLE_ID}" \
    --version          "${VERSION}" \
    --scripts          "${SCRIPTS_DIR}" \
    --install-location "/" \
    "${COMPONENT}"

# ── 6. Final product PKG ───────────────────────────────────────────────────
step 6 "Building final installer PKG …"
cat > "${BUILD_DIR}/distribution.xml" <<DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${APP_DISPLAY}</title>
    <options customize="never" require-scripts="true" rootVolumeOnly="true"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="${APP_DISPLAY}"><pkg-ref id="${BUNDLE_ID}"/></choice>
    <pkg-ref id="${BUNDLE_ID}" version="${VERSION}" onConclusion="none">${APP_NAME}.pkg</pkg-ref>
</installer-gui-script>
DISTXML

if [[ -n "${DEV_ID_PKG}" ]]; then
    productbuild --distribution "${BUILD_DIR}/distribution.xml" \
        --package-path "${BUILD_DIR}" --sign "${DEV_ID_PKG}" "${FINAL_PKG}"
    echo "  ✔ Signed product PKG"
else
    productbuild --distribution "${BUILD_DIR}/distribution.xml" \
        --package-path "${BUILD_DIR}" "${FINAL_PKG}"
    echo -e "  ${YLW}⚠  DEV_ID_PKG not set — building UNSIGNED pkg${RST}"
fi

PKG_SIZE=$(du -sh "${FINAL_PKG}" | awk '{print $1}')
echo ""
echo -e "  ${GRN}✅  PKG built:  ${FINAL_PKG}  (${PKG_SIZE})${RST}"
echo ""
echo "  Distribute this single .pkg file. On install it will:"
echo "    • Detect & cleanly remove any older version"
echo "    • Install the native app to /Applications"
echo "    • Launch it immediately → onboarding begins (spec scan, Ollama install)"
echo ""
if [[ -z "${DEV_ID_PKG}" || -z "${DEV_ID_APP}" ]]; then
    echo -e "  ${YLW}To ship externally, sign + notarize:${RST}"
    echo "    export DEV_ID_APP='Developer ID Application: NAME (TEAMID)'"
    echo "    export DEV_ID_PKG='Developer ID Installer: NAME (TEAMID)'"
    echo "    bash build_pkg.sh"
    echo "    xcrun notarytool submit '${FINAL_PKG}' --keychain-profile AC --wait"
    echo "    xcrun stapler staple '${FINAL_PKG}'"
    echo ""
fi
open "$(dirname "${FINAL_PKG}")" 2>/dev/null || true
