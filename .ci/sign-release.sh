#!/bin/sh

set -eu

if [ "${TART_RELEASE_SNAPSHOT:-false}" = "true" ]; then
  codesign \
    --force \
    --deep \
    --sign - \
    --entitlements Resources/tart-dev.entitlements \
    dist/tart_darwin_all/tart.app
else
  codesign \
    --force \
    --verbose \
    --sign "Developer ID Application: Cirrus Labs, Inc. (9M2P8L4D89)" \
    --timestamp \
    --options runtime \
    --keychain "$RUNNER_TEMP/build.keychain" \
    --entitlements Resources/tart-prod.entitlements \
    dist/tart_darwin_all/tart.app

  codesign --verify --strict --verbose=2 dist/tart_darwin_all/tart.app
fi
