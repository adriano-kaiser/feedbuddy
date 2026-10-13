#!/bin/bash
# Builds FeedBuddy.app (ad-hoc signed). Pass "install" to copy it to ~/Applications and launch it.
# Set UNIVERSAL=1 for an arm64 + x86_64 binary (needs full Xcode; used by CI).
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-}" == 1 ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP=build/FeedBuddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FeedBuddy" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x FeedBuddy || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/FeedBuddy.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/FeedBuddy.app
    echo "Installed to ~/Applications/FeedBuddy.app"
fi
