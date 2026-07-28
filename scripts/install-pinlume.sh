#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/build/DerivedDataPlus/Build/Products/Debug/Pinlume.app"
DEST_PATH="${PINLUME_INSTALL_PATH:-/Applications/Pinlume Public Debug.app}"

"${ROOT_DIR}/scripts/build-pinlume.sh"
ditto "${APP_PATH}" "${DEST_PATH}"
open "${DEST_PATH}"

echo "Installed and started ${DEST_PATH}"
