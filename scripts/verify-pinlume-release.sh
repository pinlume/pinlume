#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_APP="${ROOT_DIR}/build/DerivedDataPlusRelease/Build/Products/Release/Pinlume.app"
DEFAULT_DMG="${ROOT_DIR}/build/release/Pinlume.dmg"
APP_PATH="${1:-${DEFAULT_APP}}"
DMG_PATH="${2:-${DEFAULT_DMG}}"
EXPECTED_BUNDLE_ID="${PINLUME_RELEASE_BUNDLE_ID:-com.pinlume.app}"
EXPECTED_SIGNING_IDENTITY="${PINLUME_RELEASE_SIGNING_IDENTITY:-}"
MOUNT_PLIST="$(mktemp "${TMPDIR:-/tmp}/pinlume-mount.XXXXXX")"
MOUNT_POINT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "${MOUNT_POINT}" ]; then
    /usr/bin/hdiutil detach "${MOUNT_POINT}" -quiet >/dev/null 2>&1 || true
  fi
  rm -f "${MOUNT_PLIST}"
}
trap cleanup EXIT

test -d "${APP_PATH}" || fail "app not found: ${APP_PATH}"
test -f "${DMG_PATH}" || fail "DMG not found: ${DMG_PATH}"

if [ -z "${EXPECTED_SIGNING_IDENTITY}" ]; then
  EXPECTED_SIGNING_IDENTITY="$("${ROOT_DIR}/scripts/ensure-pinlume-signing-identity.sh")"
fi

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

EXPECTED_VERSION="${PINLUME_RELEASE_VERSION:-$(read_plist "${APP_PATH}" CFBundleShortVersionString)}"
EXPECTED_BUILD="${PINLUME_RELEASE_BUILD:-$(read_plist "${APP_PATH}" CFBundleVersion)}"
[ -n "${EXPECTED_VERSION}" ] || fail "release version is empty"
[ -n "${EXPECTED_BUILD}" ] || fail "release build is empty"
EXPECTED_PUBLIC_SOURCE_REF="${PINLUME_PUBLIC_SOURCE_REF:-v${EXPECTED_VERSION}}"

configured_marketing_versions="$(/usr/bin/sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "${ROOT_DIR}/pinlume.xcodeproj/project.pbxproj" | /usr/bin/sort -u)"
configured_build_versions="$(/usr/bin/sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "${ROOT_DIR}/pinlume.xcodeproj/project.pbxproj" | /usr/bin/sort -u)"
[ "${configured_marketing_versions}" = "${EXPECTED_VERSION}" ] || fail "built marketing version does not match the project: ${EXPECTED_VERSION}"
[ "${configured_build_versions}" = "${EXPECTED_BUILD}" ] || fail "built build version does not match the project: ${EXPECTED_BUILD}"

verify_app() {
  local app_path="$1"
  local info_plist="${app_path}/Contents/Info.plist"
  local key expected actual candidate file_info architectures linked_libraries build_info signature_info signing_requirement
  local mach_o_count=0

  test -d "${app_path}" || fail "app not found: ${app_path}"
  for pair in \
    "CFBundleIdentifier|${EXPECTED_BUNDLE_ID}" \
    "CFBundleShortVersionString|${EXPECTED_VERSION}" \
    "CFBundleVersion|${EXPECTED_BUILD}" \
    'CFBundleURLTypes:1:CFBundleURLSchemes:0|pinlume'; do
    key="${pair%%|*}"
    expected="${pair#*|}"
    actual="$(/usr/libexec/PlistBuddy -c "Print :${key}" "${info_plist}")"
    [ "${actual}" = "${expected}" ] || fail "${app_path}: ${key} is '${actual}', expected '${expected}'"
  done

  while IFS= read -r -d '' candidate; do
    file_info="$(/usr/bin/file -b "${candidate}")"
    if /usr/bin/grep -q 'Mach-O' <<< "${file_info}"; then
      mach_o_count=$((mach_o_count + 1))
      architectures="$(/usr/bin/lipo -archs "${candidate}")"
      case " ${architectures} " in
        *' arm64 '* ) ;;
        * ) fail "missing arm64: ${candidate}" ;;
      esac
      case " ${architectures} " in
        *' x86_64 '* ) ;;
        * ) fail "missing x86_64: ${candidate}" ;;
      esac
      build_info="$(/usr/bin/vtool -show-build "${candidate}" 2>/dev/null)"
      /usr/bin/grep -q 'minos 12\.3' <<< "${build_info}" || fail "macOS 12.3 minimum missing: ${candidate}"
      linked_libraries="$(/usr/bin/otool -L "${candidate}")"
      if /usr/bin/grep -qi 'Sparkle' <<< "${linked_libraries}"; then
        fail "Sparkle dynamic link: ${candidate}"
      fi
    fi
  done < <(/usr/bin/find "${app_path}" -type f -print0)
  [ "${mach_o_count}" -gt 0 ] || fail "no Mach-O files found in ${app_path}"

  [ -z "$(/usr/bin/find "${app_path}" -iname '*sparkle*' -print -quit)" ] || fail "Sparkle file remains in ${app_path}"
  for key in SUFeedURL SUPublicEDKey SUScheduledCheckInterval SUEnableAutomaticChecks SUEnableInstallerLauncherService; do
    if /usr/libexec/PlistBuddy -c "Print :${key}" "${info_plist}" >/dev/null 2>&1; then
      fail "Sparkle Info.plist key remains in ${app_path}: ${key}"
    fi
  done

  /usr/bin/codesign --verify --deep --strict "${app_path}"
  signature_info="$(/usr/bin/codesign -dvv "${app_path}" 2>&1)"
  if /usr/bin/grep -qiE 'Signature=adhoc|Authority=Ad Hoc' <<< "${signature_info}"; then
    fail "ad-hoc signing is forbidden: ${app_path}"
  fi
  signing_requirement="$(/usr/bin/codesign -d -r- "${app_path}" 2>&1)"
  /usr/bin/grep -qiF "certificate leaf = H\"${EXPECTED_SIGNING_IDENTITY}\"" <<< "${signing_requirement}" \
    || fail "app is not signed by the stable Pinlume identity: ${app_path}"
  printf 'verified app: %s (%s Mach-O files)\n' "${app_path}" "${mach_o_count}"
}

verify_app "${APP_PATH}"

DMG_FORMAT="$(/usr/bin/hdiutil imageinfo -format "${DMG_PATH}")"
[ "${DMG_FORMAT}" = 'UDZO' ] || fail "DMG is not UDZO"
/usr/bin/hdiutil attach -readonly -nobrowse -plist "${DMG_PATH}" > "${MOUNT_PLIST}"
for index in 0 1 2 3 4; do
  mount_candidate="$(/usr/libexec/PlistBuddy -c "Print :system-entities:${index}:mount-point" "${MOUNT_PLIST}" 2>/dev/null || true)"
  if [ -n "${mount_candidate}" ]; then
    MOUNT_POINT="${mount_candidate}"
    break
  fi
done
[ -n "${MOUNT_POINT}" ] || fail "could not find mounted DMG volume"
test -d "${MOUNT_POINT}/Pinlume.app" || fail "DMG is missing Pinlume.app"
test -L "${MOUNT_POINT}/Applications" || fail "DMG is missing Applications link"
[ "$(readlink "${MOUNT_POINT}/Applications")" = '/Applications' ] || fail "Applications link target is incorrect"
LEGAL_RESOURCES="${MOUNT_POINT}/Pinlume.app/Contents/Resources"
test -f "${LEGAL_RESOURCES}/LICENSE" || fail "packaged app is missing LICENSE"
test -f "${LEGAL_RESOURCES}/NOTICE.md" || fail "packaged app is missing NOTICE.md"
test -f "${LEGAL_RESOURCES}/SOURCE_CODE.txt" || fail "packaged app is missing SOURCE_CODE.txt"
/usr/bin/cmp -s "${ROOT_DIR}/LICENSE" "${LEGAL_RESOURCES}/LICENSE" \
  || fail "packaged app LICENSE does not match the checked-in license"
/usr/bin/cmp -s "${ROOT_DIR}/NOTICE.md" "${LEGAL_RESOURCES}/NOTICE.md" \
  || fail "packaged app NOTICE.md does not match the checked-in attribution notice"
/usr/bin/grep -qF "Version: ${EXPECTED_VERSION}" "${LEGAL_RESOURCES}/SOURCE_CODE.txt" \
  || fail "packaged app source notice does not match release version ${EXPECTED_VERSION}"
/usr/bin/grep -qF "Source ref: ${EXPECTED_PUBLIC_SOURCE_REF}" "${LEGAL_RESOURCES}/SOURCE_CODE.txt" \
  || fail "packaged app source notice does not match public ref ${EXPECTED_PUBLIC_SOURCE_REF}"
/usr/bin/grep -qF "Source: https://github.com/pinlume/pinlume/tree/${EXPECTED_PUBLIC_SOURCE_REF}" "${LEGAL_RESOURCES}/SOURCE_CODE.txt" \
  || fail "packaged app source notice does not point to the expected public source"
verify_app "${MOUNT_POINT}/Pinlume.app"

printf 'release verification passed\n'
