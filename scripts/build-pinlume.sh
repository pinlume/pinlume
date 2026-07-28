#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${ROOT_DIR}/build/DerivedDataPlus"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug/Pinlume.app"
ENTITLEMENTS="${ROOT_DIR}/pinlume/pinlume.entitlements"
SIGN_IDENTITY="$("${ROOT_DIR}/scripts/ensure-pinlume-signing-identity.sh")"

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

/usr/bin/codesign --force --deep --sign "${SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS}" "${APP_PATH}" >/dev/null

# This local identity is intentionally self-signed, so trust-chain verification
# fails by design. Verify the designated requirement instead: a stable leaf
# certificate fingerprint is what keeps Screen Recording permission stable.
SIGNING_REQUIREMENT="$(/usr/bin/codesign -d -r- "${APP_PATH}" 2>&1)"
if ! /usr/bin/grep -qi "certificate leaf = H\"${SIGN_IDENTITY}\"" <<< "${SIGNING_REQUIREMENT}"; then
  printf 'Unexpected Debug signing requirement: %s\n' "${SIGNING_REQUIREMENT}" >&2
  exit 1
fi

echo "${APP_PATH}"
