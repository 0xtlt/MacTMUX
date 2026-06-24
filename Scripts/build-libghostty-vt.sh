#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_REF="${GHOSTTY_REF:-main}"
GHOSTTY_SRC="$ROOT_DIR/.build/ghostty-vt-src"
GHOSTTY_INSTALL="$ROOT_DIR/.build/ghostty-vt-install"
VENDOR_DIR="$ROOT_DIR/Vendor/GhosttyVT"
ZIG="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"

if [[ ! -x "$ZIG" ]]; then
  cat >&2 <<EOF
Missing Zig 0.15.2.

Install the patched Homebrew build recommended by Ghostty on Xcode 26.4+:
  brew install zig@0.15

Then rerun:
  ZIG=/opt/homebrew/opt/zig@0.15/bin/zig $0
EOF
  exit 1
fi

mkdir -p "$ROOT_DIR/.build"
if [[ ! -d "$GHOSTTY_SRC/.git" ]]; then
  git clone --depth 1 --branch "$GHOSTTY_REF" https://github.com/ghostty-org/ghostty "$GHOSTTY_SRC"
else
  git -C "$GHOSTTY_SRC" fetch --depth 1 origin "$GHOSTTY_REF"
  git -C "$GHOSTTY_SRC" checkout --detach FETCH_HEAD
fi

rm -rf "$GHOSTTY_INSTALL"
(
  cd "$GHOSTTY_SRC"
  "$ZIG" build \
    --prefix "$GHOSTTY_INSTALL" \
    -Demit-lib-vt=true \
    -Doptimize=ReleaseFast \
    --summary failures \
    --color off
)

rm -rf "$VENDOR_DIR/include"
mkdir -p "$VENDOR_DIR/lib"
cp -R "$GHOSTTY_INSTALL/include" "$VENDOR_DIR/include"
cp "$GHOSTTY_INSTALL/lib/libghostty-vt.0.1.0.dylib" "$VENDOR_DIR/lib/libghostty-vt.dylib"

echo "Vendored libghostty-vt into $VENDOR_DIR"
