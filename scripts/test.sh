#!/usr/bin/env bash
set -euo pipefail

# Command Line Tools ship Swift Testing outside SwiftPM's default search paths.
DEV_DIR="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
if [[ "$(uname)" == "Darwin" && "$DEV_DIR" == */CommandLineTools ]]; then
    LIB="$DEV_DIR/Library/Developer"
    exec swift test \
        -Xswiftc -F -Xswiftc "$LIB/Frameworks" \
        -Xlinker -rpath -Xlinker "$LIB/Frameworks" \
        -Xlinker -rpath -Xlinker "$LIB/usr/lib" \
        "$@"
fi
exec swift test "$@"
