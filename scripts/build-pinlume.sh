#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${ROOT_DIR}/build/DerivedDataPlus"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug/Pinlume.app"
ENTITLEMENTS="${ROOT_DIR}/pinlume/pinlume.entitlements"

xcodebuild \
  -quiet \
  -project "${ROOT_DIR}/pinlume.xcodeproj" \
  -scheme Pinlume \
  -configuration Debug \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PRODUCT_BUNDLE_IDENTIFIER=com.pinlume.app \
  PRODUCT_NAME="Pinlume" \
  INFOPLIST_KEY_CFBundleDisplayName="Pinlume" \
  build >&2

if [ "${PINLUME_USE_STABLE_LOCAL_SIGNING:-0}" = "1" ]; then
  SIGN_IDENTITY="$("${ROOT_DIR}/scripts/ensure-pinlume-signing-identity.sh")"
  /usr/bin/codesign --force --deep --sign "${SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS}" "${APP_PATH}" >/dev/null

  # This optional self-signed identity keeps TCC permissions stable between
  # local checkouts on the same Mac. It is never created by a default build.
  SIGNING_REQUIREMENT="$(/usr/bin/codesign -d -r- "${APP_PATH}" 2>&1)"
  if ! /usr/bin/grep -qi "certificate leaf = H\"${SIGN_IDENTITY}\"" <<< "${SIGNING_REQUIREMENT}"; then
    printf 'Unexpected Debug signing requirement: %s\n' "${SIGNING_REQUIREMENT}" >&2
    exit 1
  fi
fi

echo "${APP_PATH}"
