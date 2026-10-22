#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pinned Ghostty commit (override with GHOSTTY_REF=<sha|branch|tag>).
GHOSTTY_REF="${GHOSTTY_REF:-f54340ad77814fe319d136e5e915d6a48de8dd23}"
GHOSTTY_SRC="$ROOT_DIR/.build/ghostty-vt-src"
GHOSTTY_INSTALL="$ROOT_DIR/.build/ghostty-vt-install"
VENDOR_DIR="$ROOT_DIR/Vendor/GhosttyVT"
ZIG="${ZIG:-$(mise which zig --tool zig@0.17 2>/dev/null || true)}"

if [[ -z "$ZIG" || ! -x "$ZIG" ]]; then
  cat >&2 <<EOF
Missing Zig >= 0.17.0 (required by current Ghostty main).

Install it with mise (does not change global config):
  mise install zig@0.17

Then rerun:
  $0
or point at any Zig >= 0.17.0:
  ZIG=/path/to/zig $0
EOF
  exit 1
fi

mkdir -p "$ROOT_DIR/.build"
# `git clone --branch` cannot take a commit SHA, so init + shallow-fetch the ref.
if [[ ! -d "$GHOSTTY_SRC/.git" ]]; then
  git init --quiet "$GHOSTTY_SRC"
  git -C "$GHOSTTY_SRC" remote add origin https://github.com/ghostty-org/ghostty
fi
git -C "$GHOSTTY_SRC" fetch --depth 1 origin "$GHOSTTY_REF"
git -C "$GHOSTTY_SRC" checkout --detach FETCH_HEAD
echo "Building Ghostty $(git -C "$GHOSTTY_SRC" rev-parse HEAD) with $("$ZIG" version)"

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
