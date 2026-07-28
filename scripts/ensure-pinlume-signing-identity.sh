#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_ROOT="${ROOT_DIR}"
if COMMON_GIT_DIR="$(git -C "${ROOT_DIR}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  REPOSITORY_ROOT="$(dirname "${COMMON_GIT_DIR}")"
fi
LEGACY_SIGNING_DIR="${REPOSITORY_ROOT}/build/signing"
SIGNING_DIR="${PINLUME_SIGNING_DIR:-${HOME}/Library/Application Support/Pinlume/signing}"
KEYCHAIN="${SIGNING_DIR}/pinlume-signing.keychain-db"
KEYCHAIN_PASSWORD="pinlume-local"
IDENTITY_NAME="Pinlume Local Code Signing"
KEY_FILE="${SIGNING_DIR}/pinlume.key"
CERT_FILE="${SIGNING_DIR}/pinlume.crt"
P12_FILE="${SIGNING_DIR}/pinlume.p12"
OPENSSL_CONFIG="${SIGNING_DIR}/openssl-codesign.cnf"

migrate_legacy_identity_if_needed() {
  [ "${SIGNING_DIR}" = "${LEGACY_SIGNING_DIR}" ] && return
  [ -f "${P12_FILE}" ] && return
  [ -f "${LEGACY_SIGNING_DIR}/pinlume.p12" ] || return
  [ -f "${LEGACY_SIGNING_DIR}/pinlume.crt" ] || return
  [ -f "${LEGACY_SIGNING_DIR}/pinlume.key" ] || return

  mkdir -p "${SIGNING_DIR}"
  cp "${LEGACY_SIGNING_DIR}/pinlume.key" "${KEY_FILE}"
  cp "${LEGACY_SIGNING_DIR}/pinlume.crt" "${CERT_FILE}"
  cp "${LEGACY_SIGNING_DIR}/pinlume.p12" "${P12_FILE}"
  chmod 600 "${KEY_FILE}" "${P12_FILE}"
  chmod 644 "${CERT_FILE}"
}

migrate_legacy_identity_if_needed
mkdir -p "${SIGNING_DIR}"

remove_keychain_from_search_list() {
  existing_keychains=()
  while IFS= read -r line; do
    cleaned="${line//\"/}"
    cleaned="$(echo "${cleaned}" | xargs)"
    if [ -n "${cleaned}" ] && [ -f "${cleaned}" ] && [ "${cleaned}" != "${KEYCHAIN}" ]; then
      existing_keychains+=("${cleaned}")
    fi
  done < <(security list-keychains -d user)
  if [ "${#existing_keychains[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${existing_keychains[@]}"
  fi
}

create_keychain() {
  remove_keychain_from_search_list
  security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
  security set-keychain-settings -lut 21600 "${KEYCHAIN}"
}

if [ ! -f "${KEYCHAIN}" ]; then
  create_keychain
elif ! security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}" >/dev/null 2>&1; then
  if [ "${PINLUME_REPAIR_KEYCHAIN:-0}" = "1" ]; then
    backup="${KEYCHAIN}.broken.$(date +%Y%m%d%H%M%S)"
    mv "${KEYCHAIN}" "${backup}"
    create_keychain
  else
    echo "error: failed to unlock ${KEYCHAIN}" >&2
    echo "hint: grant keychain access, or rerun with PINLUME_REPAIR_KEYCHAIN=1 to rebuild it from the existing p12." >&2
    exit 1
  fi
fi

security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"

existing_keychains=()
while IFS= read -r line; do
  cleaned="${line//\"/}"
  cleaned="$(echo "${cleaned}" | xargs)"
  if [ -n "${cleaned}" ] && [ -f "${cleaned}" ] && [ "${cleaned}" != "${KEYCHAIN}" ]; then
    existing_keychains+=("${cleaned}")
  fi
done < <(security list-keychains -d user)
security list-keychains -d user -s "${KEYCHAIN}" "${existing_keychains[@]}"

if ! security find-identity -v -p codesigning "${KEYCHAIN}" | grep -F "\"${IDENTITY_NAME}\"" >/dev/null; then
  if [ ! -f "${P12_FILE}" ] || [ ! -f "${CERT_FILE}" ]; then
    cat > "${OPENSSL_CONFIG}" <<'CONFIG'
[ req ]
distinguished_name = req_distinguished_name

[ req_distinguished_name ]

[ codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

    openssl req \
      -new \
      -x509 \
      -days 3650 \
      -nodes \
      -newkey rsa:2048 \
      -sha256 \
      -keyout "${KEY_FILE}" \
      -out "${CERT_FILE}" \
      -subj "/CN=${IDENTITY_NAME}" \
      -config "${OPENSSL_CONFIG}" \
      -extensions codesign >/dev/null 2>&1

    openssl pkcs12 \
      -export \
      -inkey "${KEY_FILE}" \
      -in "${CERT_FILE}" \
      -out "${P12_FILE}" \
      -password "pass:${KEYCHAIN_PASSWORD}" \
      -name "${IDENTITY_NAME}" >/dev/null 2>&1
  fi

  security import "${P12_FILE}" \
    -k "${KEYCHAIN}" \
    -P "${KEYCHAIN_PASSWORD}" \
    -T /usr/bin/codesign >/dev/null

  security add-trusted-cert \
    -r trustRoot \
    -k "${KEYCHAIN}" \
    "${CERT_FILE}" >/dev/null

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "${KEYCHAIN_PASSWORD}" \
    "${KEYCHAIN}" >/dev/null
fi

identity_hash="$(security find-identity -v -p codesigning "${KEYCHAIN}" | awk -v name="${IDENTITY_NAME}" 'index($0, "\"" name "\"") { print $2; exit }')"
if [ -z "${identity_hash}" ]; then
  echo "error: failed to create codesigning identity '${IDENTITY_NAME}'" >&2
  exit 1
fi

echo "${identity_hash}"
