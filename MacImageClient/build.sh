#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/NPC Image Sender.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
MODULE_CACHE_DIR="$ROOT_DIR/build/ModuleCache"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$MODULE_CACHE_DIR"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"

swiftc \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos11.0" \
  -framework AppKit \
  -framework Foundation \
  "$ROOT_DIR/MacImageClient/Sources/main.swift" \
  -o "$MACOS_DIR/NPCImageSender"

cp "$ROOT_DIR/MacImageClient/Info.plist" "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
