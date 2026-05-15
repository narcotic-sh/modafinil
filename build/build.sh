#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: HAMZA QAYYUM (3LF26Z4G2R)}"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/Modafinil.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DAEMONS_DIR="$CONTENTS_DIR/Library/LaunchDaemons"

cd "$ROOT_DIR"

if ! security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" >/dev/null; then
  echo "Missing signing identity: $SIGN_IDENTITY" >&2
  echo "For local development, pass your own Apple Development identity:" >&2
  echo "  SIGN_IDENTITY=\"Apple Development: Your Name (TEAMID)\" $0" >&2
  exit 1
fi

BUILD_DIR="$(swift build -c release --arch x86_64 --arch arm64 --show-bin-path)"
swift build -c release --arch x86_64 --arch arm64

lipo "$BUILD_DIR/Modafinil" -verify_arch x86_64 arm64 >/dev/null
lipo "$BUILD_DIR/ModafinilHelper" -verify_arch x86_64 arm64 >/dev/null

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DAEMONS_DIR"

cp "$BUILD_DIR/Modafinil" "$MACOS_DIR/Modafinil"
cp "$BUILD_DIR/ModafinilHelper" "$MACOS_DIR/ModafinilHelper"
cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Packaging/com.narcotic.modafinil.helper.plist" "$DAEMONS_DIR/com.narcotic.modafinil.helper.plist"

if [ -f "$ROOT_DIR/assets/icon.png" ]; then
  ICONSET="$DIST_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
  rm -rf "$ICONSET"
fi

xattr -cr "$APP_PATH"

sign_path() {
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$1" >/dev/null
}

sign_path "$MACOS_DIR/ModafinilHelper"
sign_path "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Built $APP_PATH"
