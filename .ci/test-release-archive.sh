#!/bin/sh

set -eu

ARCHIVE_PATH="$1"
EXTRACT_PATH=$(mktemp -d)
trap 'rm -rf "$EXTRACT_PATH"' EXIT

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_PATH"
APP_PATH="$EXTRACT_PATH/tart.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/tart"

if ! otool -l "$EXECUTABLE_PATH" | awk '
  /^Load command/ { weak = 0 }
  /cmd LC_LOAD_WEAK_DYLIB/ { weak = 1 }
  weak && /name @rpath\/libswiftCompatibilitySpan\.dylib/ { found = 1 }
  END { exit found ? 0 : 1 }
'; then
  echo "libswiftCompatibilitySpan.dylib is not weak-linked" >&2
  exit 1
fi

codesign --verify --strict --deep "$APP_PATH"
