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
  gon gon.hcl
fi
