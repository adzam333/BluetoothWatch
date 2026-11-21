#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL=false
if [[ "${1:-}" == "--install" && "$#" == 1 ]]; then
    INSTALL=true
elif [[ "$#" != 0 ]]; then
    echo "Usage: bash scripts/build-app.sh [--install]" >&2
    exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Building this app requires a Mac with Xcode / Command Line Tools." >&2
    exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 26 )); then
    echo "Bluetooth Watch requires macOS 26 or newer." >&2
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Install Xcode or run xcode-select --install first." >&2
    exit 1
fi

xcrun swift build --package-path "$ROOT" --configuration release --product BluetoothWatch
BIN_DIR="$(xcrun swift build --package-path "$ROOT" --configuration release --show-bin-path)"
APP="$ROOT/build/Bluetooth Watch.app"
# Assemble and sign outside the checkout: synced folders (e.g. iCloud Desktop)
# can re-attach Finder metadata at any time, which codesign rejects.
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bluetoothwatch-build.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGED="$STAGE_DIR/Bluetooth Watch.app"
mkdir -p "$STAGED/Contents/MacOS"
cp "$BIN_DIR/BluetoothWatch" "$STAGED/Contents/MacOS/BluetoothWatch"
cp "$ROOT/Packaging/Info.plist" "$STAGED/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED/Contents/Info.plist"
/usr/bin/xattr -cr "$STAGED"
/usr/bin/codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --timestamp=none "$STAGED"
/usr/bin/codesign --verify --strict "$STAGED"
rm -rf "$APP"
mkdir -p "$ROOT/build"
/usr/bin/ditto --noextattr "$STAGED" "$APP"
echo "Built: $APP"

if [[ "$INSTALL" == true ]]; then
    if /usr/bin/pgrep -x BluetoothWatch >/dev/null; then
        echo "Quit Bluetooth Watch from its menu-bar icon, then rerun this command to install." >&2
        exit 1
    fi
    DESTINATION="$HOME/Applications/Bluetooth Watch.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DESTINATION"
    /usr/bin/ditto --noextattr "$STAGED" "$DESTINATION"
    /usr/bin/xattr -cr "$DESTINATION"
    /usr/bin/codesign --verify --strict "$DESTINATION"
    echo "Installed: $DESTINATION"
    /usr/bin/open "$DESTINATION"
fi
