#!/bin/sh

set -eu

ARCHIVE_PATH="$1"
EXTRACT_PATH=$(mktemp -d)
trap 'rm -rf "$EXTRACT_PATH"' EXIT

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_PATH"
APP_PATH="$EXTRACT_PATH/tart.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/tart"

for LIBRARY in $(otool -L "$EXECUTABLE_PATH" | sed -n 's|.*@rpath/\(libswift[^ ]*\.dylib\).*|\1|p' | sort -u); do
  if [ ! -f "$APP_PATH/Contents/MacOS/$LIBRARY" ]; then
    echo "missing bundled Swift library: $LIBRARY" >&2
    exit 1
  fi
done

codesign --verify --strict --deep "$APP_PATH"
