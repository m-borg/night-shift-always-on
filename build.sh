#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/NightShiftAlwaysOn.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BIN_FILE="$MACOS_DIR/NightShiftAlwaysOn"

SDK_PATH="$(xcrun --show-sdk-path)"
UNIVERSAL=false
if [ "${1:-}" = "--universal" ]; then
  UNIVERSAL=true
fi

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"

compile_arch() {
  local arch="$1"
  local obj="$BUILD_DIR/CoreBrightnessBridge_${arch}.o"
  local bin="$BUILD_DIR/NightShiftAlwaysOn_${arch}"

  echo "Compiling CoreBrightnessBridge.m ($arch)..."
  clang -fobjc-arc -O2 -arch "$arch" -isysroot "$SDK_PATH" \
    -mmacosx-version-min=13.0 \
    -c "$ROOT_DIR/Sources/CoreBrightnessBridge.m" \
    -o "$obj"

  echo "Compiling Swift sources ($arch)..."
  swiftc -O -target "${arch}-apple-macos13.0" \
    -sdk "$SDK_PATH" \
    -import-objc-header "$ROOT_DIR/Sources/CoreBrightnessBridge.h" \
    "$ROOT_DIR/Sources/NightShiftController.swift" \
    "$ROOT_DIR/Sources/AppDelegate.swift" \
    "$ROOT_DIR/Sources/main.swift" \
    "$obj" \
    -framework Cocoa \
    -framework Foundation \
    -o "$bin"
}

if [ "$UNIVERSAL" = true ]; then
  compile_arch arm64
  compile_arch x86_64
  echo "Creating universal binary (arm64 + x86_64)..."
  lipo -create \
    "$BUILD_DIR/NightShiftAlwaysOn_arm64" \
    "$BUILD_DIR/NightShiftAlwaysOn_x86_64" \
    -output "$BIN_FILE"
else
  ARCH="$(uname -m)"
  compile_arch "$ARCH"
  cp "$BUILD_DIR/NightShiftAlwaysOn_${ARCH}" "$BIN_FILE"
fi

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  mkdir -p "$CONTENTS_DIR/Resources"
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Built: $APP_BUNDLE"
