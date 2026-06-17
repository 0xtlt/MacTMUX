#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacTMUX"
BIN_NAME="MacTMUX"
PROFILE="debug"
ARCH=""

usage() {
  echo "usage: $0 [--release] [arm64|x86_64]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      PROFILE="release"
      ;;
    debug|release)
      PROFILE="$1"
      ;;
    arm64|x86_64)
      ARCH="$1"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ "$PROFILE" == "release" && -z "$ARCH" ]]; then
  ARCH="$(uname -m)"
fi

case "$ARCH" in
  ""|arm64|x86_64)
    ;;
  *)
    echo "unsupported arch: $ARCH" >&2
    exit 2
    ;;
esac

BUILD_ARGS=(-c "$PROFILE")
if [[ -n "$ARCH" ]]; then
  BUILD_ARGS+=(--arch "$ARCH")
fi

DIST_DIR="$ROOT_DIR/dist"
if [[ -n "$ARCH" ]]; then
  PRODUCT_DIR="$ROOT_DIR/.build/$ARCH-apple-macosx/$PROFILE"
else
  PRODUCT_DIR="$ROOT_DIR/.build/$PROFILE"
fi

if [[ "$PROFILE" == "release" ]]; then
  APP_DIR="$DIST_DIR/$APP_NAME.app"
else
  APP_DIR="$ROOT_DIR/$APP_NAME.app"
fi

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
DMG_DIR="$DIST_DIR/dmg"
LIBGHOSTTY_VT="$ROOT_DIR/Vendor/GhosttyVT/lib/libghostty-vt.dylib"

cd "$ROOT_DIR"

echo "Building $APP_NAME ($PROFILE${ARCH:+, $ARCH})..."
swift build "${BUILD_ARGS[@]}"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/MacTMUX.icns" "$RESOURCES_DIR/MacTMUX.icns"
cp "$PRODUCT_DIR/$BIN_NAME" "$MACOS_DIR/$BIN_NAME"
chmod +x "$MACOS_DIR/$BIN_NAME"

if [[ -f "$LIBGHOSTTY_VT" ]]; then
  cp "$LIBGHOSTTY_VT" "$FRAMEWORKS_DIR/libghostty-vt.dylib"
  chmod +x "$FRAMEWORKS_DIR/libghostty-vt.dylib"
fi

if [[ "$PROFILE" == "release" ]]; then
  DMG_PATH="$DIST_DIR/mactmux-$ARCH.dmg"
  echo "Creating DMG..."
  rm -rf "$DMG_DIR" "$DMG_PATH"
  mkdir -p "$DMG_DIR"
  cp -R "$APP_DIR" "$DMG_DIR/"
  ln -s /Applications "$DMG_DIR/Applications"
  hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"
  rm -rf "$DMG_DIR"
  echo "Built $APP_DIR"
  echo "Built $DMG_PATH"
else
  echo "Built $APP_DIR"
fi
