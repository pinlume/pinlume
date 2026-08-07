#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${PINLUME_PACKAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DERIVED_DATA="${PINLUME_RELEASE_DERIVED_DATA:-${ROOT_DIR}/build/DerivedDataPlusRelease}"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/Pinlume.app"
OUTPUT_DIR="${ROOT_DIR}/build/release"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinlume-dmg.XXXXXX")"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinlume-mount.XXXXXX")"
DMG_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinlume-dmg-image.XXXXXX")"
DMG_RW_PATH="${DMG_BUILD_DIR}/Pinlume-layout.dmg"
LAYOUT_VOLUME_NAME="PinlumeLayout-$(uuidgen)"
LAYOUT_DEVICE=""
LAYOUT_MOUNT_DIR=""
ICONSET_PARENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinlume-iconset.XXXXXX")"
ICON_VERIFY_PARENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pinlume-icon-verify.XXXXXX")"
DMG_ASSETS_ROOT="${PINLUME_DMG_ASSETS_ROOT:-${ROOT_DIR}/assets}"
DMG_BACKGROUND_RENDERER="${ROOT_DIR}/scripts/render-dmg-background.swift"
ENTITLEMENTS="${ROOT_DIR}/pinlume/pinlume.entitlements"
SIGN_IDENTITY="${PINLUME_RELEASE_SIGNING_IDENTITY:-$("${ROOT_DIR}/scripts/ensure-pinlume-signing-identity.sh")}"
VERIFY_SCRIPT="${PINLUME_RELEASE_VERIFY_SCRIPT:-${ROOT_DIR}/scripts/verify-pinlume-release.sh}"
if [ "${PINLUME_RELEASE_SWIFT_ACTIVE_COMPILATION_CONDITIONS+x}" = x ]; then
  RELEASE_COMPILATION_CONDITIONS="${PINLUME_RELEASE_SWIFT_ACTIVE_COMPILATION_CONDITIONS}"
else
  RELEASE_COMPILATION_CONDITIONS="PLUS"
fi
MOUNTED=false
LAYOUT_MOUNTED=false

cleanup() {
  if [ "${LAYOUT_MOUNTED}" = true ]; then
    hdiutil detach "${LAYOUT_DEVICE}" -quiet || true
  fi
  if [ "${MOUNTED}" = true ]; then
    hdiutil detach "${MOUNT_DIR}" -quiet || true
  fi
  rm -rf "${STAGING_DIR}"
  rm -rf "${MOUNT_DIR}"
  rm -rf "${DMG_BUILD_DIR}"
  rm -rf "${ICONSET_PARENT_DIR}"
  rm -rf "${ICON_VERIFY_PARENT_DIR}"
}
trap cleanup EXIT

build_full_resolution_app_icon() {
  local icon_source_dir="${ROOT_DIR}/pinlume/Assets.xcassets/AppIcon.appiconset"
  local iconset_dir="${ICONSET_PARENT_DIR}/AppIcon.iconset"

  mkdir "${iconset_dir}"
  cp "${icon_source_dir}"/*.png "${iconset_dir}/"
  /usr/bin/iconutil -c icns "${iconset_dir}" -o "${APP_PATH}/Contents/Resources/AppIcon.icns"
}

verify_full_resolution_app_icon() {
  local app_path="$1"
  local extracted_iconset="${ICON_VERIFY_PARENT_DIR}/AppIcon.iconset"

  /usr/bin/iconutil -c iconset "${app_path}/Contents/Resources/AppIcon.icns" -o "${extracted_iconset}"
  test -f "${extracted_iconset}/icon_512x512.png"
  test -f "${extracted_iconset}/icon_512x512@2x.png"
}

mkdir -p "${OUTPUT_DIR}"

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
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="${RELEASE_COMPILATION_CONDITIONS}" \
  INFOPLIST_KEY_CFBundleDisplayName="Pinlume" \
  MACOSX_DEPLOYMENT_TARGET=12.3 \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

test -d "${APP_PATH}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
PUBLIC_SOURCE_REF="${PINLUME_PUBLIC_SOURCE_REF:-v${VERSION}}"
PUBLIC_SOURCE_URL="https://github.com/pinlume/pinlume/tree/${PUBLIC_SOURCE_REF}"
build_full_resolution_app_icon
test -f "${ROOT_DIR}/LICENSE"
ditto "${ROOT_DIR}/LICENSE" "${APP_PATH}/Contents/Resources/LICENSE"
ditto "${ROOT_DIR}/NOTICE.md" "${APP_PATH}/Contents/Resources/NOTICE.md"
/usr/bin/printf '%s\n' \
  'Pinlume Corresponding Source' \
  '' \
  "Version: ${VERSION}" \
  "Source ref: ${PUBLIC_SOURCE_REF}" \
  "Source: ${PUBLIC_SOURCE_URL}" \
  '' \
  'Pinlume is distributed under GPLv3. Publish this exact public tag or commit before distributing the DMG.' \
  > "${APP_PATH}/Contents/Resources/SOURCE_CODE.txt"
verify_full_resolution_app_icon "${APP_PATH}"
/usr/bin/codesign --force --deep --sign "${SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS}" "${APP_PATH}"

SIGNING_REQUIREMENT="$(/usr/bin/codesign -d -r- "${APP_PATH}" 2>&1)"
if ! /usr/bin/grep -qi "certificate leaf = H\"${SIGN_IDENTITY}\"" <<< "${SIGNING_REQUIREMENT}"; then
  printf 'Unexpected release signing requirement: %s\n' "${SIGNING_REQUIREMENT}" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

DMG_PATH="${OUTPUT_DIR}/Pinlume.dmg"

ditto "${APP_PATH}" "${STAGING_DIR}/Pinlume.app"
ditto "${ROOT_DIR}/安装(install)-doc.txt" "${STAGING_DIR}/安装(install)-doc.txt"
ln -s /Applications "${STAGING_DIR}/Applications"
test -f "${DMG_ASSETS_ROOT}/dmg-background-base.png"
test -f "${DMG_BACKGROUND_RENDERER}"
swift "${DMG_BACKGROUND_RENDERER}" \
  "${DMG_ASSETS_ROOT}/dmg-background-base.png" \
  "${DMG_ASSETS_ROOT}/dmg-background.png" \
  "${DMG_ASSETS_ROOT}/dmg-background@2x.png"
mkdir -p "${STAGING_DIR}/.background"
ditto "${DMG_ASSETS_ROOT}/dmg-background.png" "${STAGING_DIR}/.background/dmg-background.png"
ditto "${DMG_ASSETS_ROOT}/dmg-background@2x.png" "${STAGING_DIR}/.background/dmg-background@2x.png"
/usr/bin/hdiutil create \
  -ov \
  -format UDRW \
  -fs HFS+ \
  -volname "${LAYOUT_VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  "${DMG_RW_PATH}"

LAYOUT_ATTACH_OUTPUT="$(/usr/bin/hdiutil attach -readwrite "${DMG_RW_PATH}")"
LAYOUT_DEVICE="$(/usr/bin/awk '/Apple_HFS/ { print $1; exit }' <<< "${LAYOUT_ATTACH_OUTPUT}")"
LAYOUT_MOUNT_DIR="$(/usr/bin/awk '/\/Volumes\// { print $NF; exit }' <<< "${LAYOUT_ATTACH_OUTPUT}")"
test -n "${LAYOUT_DEVICE}"
test -n "${LAYOUT_MOUNT_DIR}"
LAYOUT_MOUNTED=true
/usr/bin/osascript - "${LAYOUT_VOLUME_NAME}" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
    delay 1
    tell disk volumeName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 1000, 680}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set background picture of viewOptions to file ".background:dmg-background.png"
        set position of item "Pinlume.app" to {225, 224}
        set position of item "Applications" to {675, 224}
        set position of item "安装(install)-doc.txt" to {110, 350}
        set position of item ".background" to {690, 365}
        set position of item ".fseventsd" to {800, 365}
        update without registering applications
        close
    end tell
    end tell
end run
APPLESCRIPT
/usr/sbin/diskutil renameVolume "${LAYOUT_DEVICE}" "Pinlume" >/dev/null
/bin/sync
/usr/bin/hdiutil detach "${LAYOUT_DEVICE}" -quiet
LAYOUT_MOUNTED=false
/usr/bin/hdiutil convert "${DMG_RW_PATH}" -ov -format UDZO -o "${DMG_PATH}" >/dev/null

/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "${MOUNT_DIR}" "${DMG_PATH}" >/dev/null
MOUNTED=true
MOUNTED_APP_PATH="${MOUNT_DIR}/Pinlume.app"
test -d "${MOUNTED_APP_PATH}"
verify_full_resolution_app_icon "${MOUNTED_APP_PATH}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${MOUNTED_APP_PATH}"
MOUNTED_SIGNING_REQUIREMENT="$(/usr/bin/codesign -d -r- "${MOUNTED_APP_PATH}" 2>&1)"
if ! /usr/bin/grep -qi "certificate leaf = H\"${SIGN_IDENTITY}\"" <<< "${MOUNTED_SIGNING_REQUIREMENT}"; then
  printf 'Unexpected packaged signing requirement: %s\n' "${MOUNTED_SIGNING_REQUIREMENT}" >&2
  exit 1
fi

/usr/bin/hdiutil detach "${MOUNT_DIR}" -quiet
MOUNTED=false

"${VERIFY_SCRIPT}" "${APP_PATH}" "${DMG_PATH}"

printf 'APP=%s\nDMG=%s\n' "${APP_PATH}" "${DMG_PATH}"
