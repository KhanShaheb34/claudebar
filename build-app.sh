#!/bin/bash
set -e

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeBar"
BUNDLE_ID="com.claudebar.app"
VERSION="1.0.0"

step() { echo -e "\n${CYAN}${BOLD}[$1/4]${RESET} $2"; }
ok()   { echo -e "  ${GREEN}OK${RESET} $1"; }
fail() { echo -e "  ${RED}ERROR${RESET} $1"; exit 1; }

echo -e "${BOLD}Building ${APP_NAME}.dmg${RESET}"

cd "$SCRIPT_DIR"

# ── Step 1: Compile ──────────────────────────────────────────────────

step 1 "Compiling"

swiftc -parse-as-library \
    -framework SwiftUI \
    -framework AppKit \
    -O \
    -o "${APP_NAME}" \
    ClaudeBarApp.swift

ok "Compiled binary"

# ── Step 2: Create .app bundle ───────────────────────────────────────

step 2 "Creating ${APP_NAME}.app bundle"

APP_DIR="${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Move binary
cp "${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

ok "Created ${APP_DIR}"

# ── Step 3: Create .dmg ─────────────────────────────────────────────

step 3 "Packaging ${APP_NAME}.dmg"

DMG_NAME="${APP_NAME}.dmg"
DMG_TEMP="dmg-staging"

rm -rf "$DMG_TEMP" "$DMG_NAME"
mkdir -p "$DMG_TEMP"
cp -R "${APP_DIR}" "${DMG_TEMP}/"

# Add symlink to /Applications for drag-and-drop install
ln -s /Applications "${DMG_TEMP}/Applications"

# Create the DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_NAME" \
    > /dev/null 2>&1

rm -rf "$DMG_TEMP"

ok "Created ${DMG_NAME} ($(du -h "$DMG_NAME" | cut -f1 | xargs))"

# ── Step 4: Done ─────────────────────────────────────────────────────

step 4 "Done"

echo ""
echo -e "  ${BOLD}${APP_DIR}${RESET}  -- Double-click to run"
echo -e "  ${BOLD}${DMG_NAME}${RESET} -- Distribute to others"
echo ""
echo -e "  ${DIM}Note: The app is unsigned. On first launch, users need to:"
echo -e "  Right-click > Open, or allow it in System Settings > Privacy & Security.${RESET}"
echo ""
