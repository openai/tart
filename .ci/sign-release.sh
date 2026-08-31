#!/bin/sh

set -eu

APP_PATH="dist/tart_darwin_all/tart.app"

if [ "${TART_RELEASE_SNAPSHOT:-false}" = "true" ]; then
  codesign \
    --force \
    --deep \
    --sign - \
    --entitlements Resources/tart-dev.entitlements \
    "$APP_PATH"
else
  codesign \
    --force \
    --verbose \
    --sign "Developer ID Application: Cirrus Labs, Inc. (9M2P8L4D89)" \
    --timestamp \
    --options runtime \
    --keychain "$RUNNER_TEMP/build.keychain" \
    --entitlements Resources/tart-prod.entitlements \
    "$APP_PATH"
fi

codesign --verify --strict --verbose=2 "$APP_PATH"
"$APP_PATH/Contents/MacOS/tart" --version

if [ "${TART_RELEASE_SNAPSHOT:-false}" != "true" ]; then
  NOTARIZATION_ARCHIVE="$RUNNER_TEMP/tart-notarization.zip"

  ditto -c -k --keepParent "$APP_PATH" "$NOTARIZATION_ARCHIVE"
  xcrun notarytool submit "$NOTARIZATION_ARCHIVE" \
    --keychain-profile "notarytool" \
    --keychain "$RUNNER_TEMP/build.keychain" \
    --wait \
    --timeout 20m
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
fi
