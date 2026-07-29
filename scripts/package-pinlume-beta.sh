#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${ROOT_DIR}/build/DerivedDataRelease"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/Pinlume.app"
OUTPUT_DIR="${ROOT_DIR}/build/release"
OUTPUT_PATH="${OUTPUT_DIR}/Pinlume.dmg"
ENTITLEMENTS="${ROOT_DIR}/pinlume/pinlume.entitlements"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinlume-beta.XXXXXX")"

cleanup() {
  /bin/rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

xcodebuild \
  -quiet \
  -project "${ROOT_DIR}/pinlume.xcodeproj" \
  -scheme Pinlume \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PRODUCT_BUNDLE_IDENTIFIER=com.pinlume.app \
  PRODUCT_NAME="Pinlume" \
  INFOPLIST_KEY_CFBundleDisplayName="Pinlume" \
  build >&2

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >&2
/usr/bin/plutil -extract CFBundleShortVersionString raw "${APP_PATH}/Contents/Info.plist" >&2

/bin/mkdir -p "${OUTPUT_DIR}"
/usr/bin/ditto "${APP_PATH}" "${STAGING_DIR}/Pinlume.app"
/bin/cp "${ROOT_DIR}/BETA_INSTALL.md" "${STAGING_DIR}/BETA_INSTALL.md"
/bin/ln -s /Applications "${STAGING_DIR}/Applications"
/usr/bin/hdiutil create \
  -volname Pinlume \
  -srcfolder "${STAGING_DIR}" \
  -format UDZO \
  -ov \
  "${OUTPUT_PATH}" >&2

echo "${OUTPUT_PATH}"
