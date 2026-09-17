#!/usr/bin/env bash
# Builds FLACintosh.app and a .dmg to hand out, in dist/.
#
#     scripts/package.sh
#
# Command Line Tools only — no Xcode — and no Apple account: the app is
# signed ad hoc, which is what Apple Silicon needs to run it at all, not a
# Developer ID. On another Mac the first launch is blocked until "Open
# Anyway" in System Settings → Privacy & Security.
#
# Settings, all overridable from the environment:
#   VERSION=0.2.0 BUILD_NUMBER=7 ARCHS=arm64 scripts/package.sh
#   SIGN_IDENTITY="FLACintosh Local" scripts/package.sh
#
# SIGN_IDENTITY is a code-signing certificate in the login keychain — a
# self-signed one made in Keychain Access is enough. Ad hoc, every build is
# a different app to the keychain, which asks again for the server
# passwords after each one; signed with the same certificate, "Always
# Allow" carries over from build to build. It is still not a Developer ID:
# Gatekeeper treats the app the same either way.

set -euo pipefail

APP_NAME="FLACintosh"
BUNDLE_ID="${BUNDLE_ID:-io.github.bartolomeorusso9.flacintosh}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS="15.0"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Both, so the same download runs on Intel and Apple Silicon. The decoder
# frameworks SFBAudioEngine ships are already universal; only the app's own
# binary is built twice.
ARCHS="${ARCHS:-arm64 x86_64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ICON_PNG="$ROOT/Assets/AppIcon.png"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

cd "$ROOT"
step() { printf '\n==> %s\n' "$*"; }

# MARK: - Icon

if [[ ! -f "$ICON_PNG" ]]; then
    step "No Assets/AppIcon.png — drawing the placeholder"
    swift scripts/make-icon.swift "$ICON_PNG"
fi

# MARK: - Build

binaries=()
frameworks_dir=""
native="$(uname -m)"
for arch in $ARCHS; do
    triple="$arch-apple-macosx$MIN_MACOS"
    # No cached build description. SwiftPM keeps one per configuration, not
    # per triple, so after building one architecture the next run for the
    # other fails with "No target named …". Rebuilding the description
    # costs a second; a build folder per architecture would instead fetch
    # every dependency again.
    step "Building release for $arch"
    # SFBAudioEngine uses std::jthread/std::stop_token, which Apple's libc++
    # only exposes with this flag (unconditionally available since Xcode 26,
    # but the macOS 15 SDK this app targets ships with Xcode 16).
    if ! swift build -c release --product "$APP_NAME" --triple "$triple" --disable-build-manifest-caching -Xcxx -fexperimental-library; then
        # The machine's own architecture has to build; the other one is a
        # bonus, and a failed cross build should not cost the whole package.
        if [[ "$arch" == "$native" ]]; then
            echo "Release build failed" >&2
            exit 1
        fi
        echo "warning: $arch did not build — the app will run on $native only" >&2
        continue
    fi
    bin="$(swift build -c release --triple "$triple" --show-bin-path)"
    binaries+=("$bin/$APP_NAME")
    frameworks_dir="$bin"
done

# MARK: - Bundle

step "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

executable="$APP/Contents/MacOS/$APP_NAME"
if (( ${#binaries[@]} > 1 )); then
    lipo -create "${binaries[@]}" -output "$executable"
else
    cp "${binaries[0]}" "$executable"
fi

# Every framework the binary links through @rpath: the decoders, which
# live next to the build products and nowhere on a user's Mac.
linked="$(otool -L "$executable" | awk '/@rpath\/[^ ]+\.framework/ { print $1 }' \
    | sed -E 's#@rpath/([^/]+\.framework)/.*#\1#' | sort -u)"
for framework in $linked; do
    ditto "$frameworks_dir/$framework" "$APP/Contents/Frameworks/$framework"
done

# Look for them inside the app, and nowhere on this machine: an rpath into
# the Command Line Tools works here and nowhere else.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$executable"
# `sort -u`: a universal binary lists each rpath once per architecture, and
# one delete already removes it from both.
otool -l "$executable" | awk '/LC_RPATH/ { getline; getline; print $2 }' \
    | grep -E '^/Library/Developer|^/Applications/Xcode' | sort -u \
    | while read -r path; do install_name_tool -delete_rpath "$path" "$executable"; done

step "Making the icon"
iconset="$DIST/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_PNG" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>$APP_NAME finds Google Cast devices on your network and plays music on them.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_googlecast._tcp</string>
    </array>
    <key>NSAppleEventsUsageDescription</key>
    <string>$APP_NAME opens SpotiFLAC's interactive mode and its updates in Terminal.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# MARK: - Signing

# Ad hoc, inside out: frameworks first, then the app around them. Editing
# the rpaths above broke the linker's own signature, and Apple Silicon will
# not start a binary whose signature does not check out.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    step "Signing ad hoc"
else
    step "Signing with \"$SIGN_IDENTITY\""
fi
for framework in "$APP/Contents/Frameworks/"*.framework; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$framework"
done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

# MARK: - Disk image

step "Making $(basename "$DMG")"
stage="$DIST/dmg"
rm -rf "$stage" "$DMG"
mkdir -p "$stage"
ditto "$APP" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$stage"

step "Done"
echo "  $APP ($(lipo -archs "$executable"))"
echo "  $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
