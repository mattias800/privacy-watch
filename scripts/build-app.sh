#!/usr/bin/env bash
# Builds PrivacyWatch.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/PrivacyWatch.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PrivacyWatch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PrivacyWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and to use notifications.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/PrivacyWatch.app"
    mkdir -p "$HOME/Applications"
    pkill -x PrivacyWatch 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
