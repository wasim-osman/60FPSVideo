#!/bin/bash
#
# Assemble 60FPS.app and, with --dmg, a disk image to ship it in.
#
# SwiftPM produces a bare Mach-O executable. macOS wants a bundle: the executable inside
# Contents/MacOS, a plist the system reads before the process exists, an icon, and a signature.
# Without the bundle the app still runs from a terminal, and does nothing useful from the Finder
# — no icon, no name in the menu bar, no document types, no way to say "Open With".
#
# Usage:
#   scripts/bundle.sh                 # release build, app only
#   scripts/bundle.sh --debug         # debug build, for testing the bundle itself
#   scripts/bundle.sh --dmg           # also write build/60FPS-<version>.dmg
#   scripts/bundle.sh --no-sign       # skip codesign, for inspecting the layout
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG=release
MAKE_DMG=0
SIGN=1

for arg in "$@"; do
    case "$arg" in
        --debug)   CONFIG=debug ;;
        --release) CONFIG=release ;;
        --dmg)     MAKE_DMG=1 ;;
        --no-sign) SIGN=0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME=60FPS
PLIST="$ROOT/packaging/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD="$ROOT/build"
BUNDLE="$BUILD/$APP_NAME.app"

echo "==> building $APP_NAME ($CONFIG)"
# --disable-sandbox: SwiftPM's own sandbox cannot nest inside the agent shell.
swift build -c "$CONFIG" --disable-sandbox --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)"

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$BUNDLE/Contents/Info.plist"
# Four bytes of classic Mac OS metadata. Deprecated since 10.7 and still read by some tools;
# its absence is harmless, its presence costs nothing, and a bundle without one looks hand-made.
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if [ ! -f "$BUILD/icon/AppIcon.icns" ]; then
    echo "==> drawing the icon"
    PYTHON="${PYTHON:-/Users/Wasim/.workbuddy-ai/binaries/python/envs/default/bin/python}"
    if ! command -v "$PYTHON" >/dev/null 2>&1; then PYTHON=python3; fi
    "$PYTHON" "$ROOT/scripts/make-icon.py" "$BUILD/icon"
fi
cp "$BUILD/icon/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

# A binary copied out of the build directory keeps a stale mtime more often than not, and
# LaunchServices caches the bundle by modification date — a bundle that "did not change" keeps
# its old icon and its old document types no matter how many times it is rebuilt.
touch "$BUNDLE"

if [ "$SIGN" -eq 1 ]; then
    echo "==> signing (ad-hoc)"
    # `-` is the ad-hoc identity: no certificate, no team, no notarisation. It is not a
    # placeholder for "signing we did not get round to" — it is the only honest option for a
    # build produced without a Developer ID, and it still buys something real: the signature
    # covers the whole bundle, so a modified binary is detected rather than run.
    #
    # `--options runtime` is the hardened runtime, which a notarised build would also carry.
    # Including it here means the thing being tested is the thing that would ship.
    codesign --force --sign - --options runtime --timestamp=none \
             --identifier "com.sixtyfps.video" "$BUNDLE"

    echo "==> verifying"
    codesign --verify --deep --strict --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/    /'
    codesign -dv --verbose=4 "$BUNDLE" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|Runtime" | sed 's/^/    /'

    # Gatekeeper will refuse this, and that is the correct answer rather than a failure: an
    # ad-hoc signature has no Developer ID behind it and no notarisation ticket. Reported, not
    # treated as an error, because a script that exits non-zero here would be a script that
    # cannot be run by the person who built the app.
    echo "==> Gatekeeper"
    if spctl --assess --type execute --verbose=4 "$BUNDLE" 2>&1 | sed 's/^/    /'; then
        echo "    accepted"
    else
        echo "    rejected — expected for an ad-hoc build; the first launch needs"
        echo "    System Settings › Privacy & Security › Open Anyway"
    fi
fi

if [ "$MAKE_DMG" -eq 1 ]; then
    STAGE="$BUILD/dmg"
    DMG="$BUILD/$APP_NAME-$VERSION.dmg"
    echo "==> building $DMG"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$BUNDLE" "$STAGE/"
    # The symlink is the whole install instruction. Without it the user gets a window with an
    # app in it and no statement of what to do next, which is how a disk image ends up mounted
    # forever with the app being run from inside it — where it cannot update itself and where
    # the volume can be ejected underneath it.
    ln -s /Applications "$STAGE/Applications"

    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
                   -quiet "$DMG"
    hdiutil verify "$DMG" | sed 's/^/    /'
    rm -rf "$STAGE"
    echo "    $(du -h "$DMG" | cut -f1)  $DMG"
fi

echo
echo "==> $BUNDLE"
du -sh "$BUNDLE" | sed 's/^/    /'
