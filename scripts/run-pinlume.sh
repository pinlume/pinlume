#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/build/DerivedDataPlus/Build/Products/Debug/Pinlume.app"

"${ROOT_DIR}/scripts/build-pinlume.sh"
open "${APP_PATH}"
echo "Started ${APP_PATH}"
