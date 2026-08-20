#!/usr/bin/env bash
# Debug-build OpenRecord, package dist/OpenRecord.app, and launch the bundle.
# Never exec the raw .build binary — TCC binds to the .app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CONFIGURATION="${CONFIGURATION:-debug}"
"$ROOT/scripts/package-app.sh"
open "$ROOT/dist/OpenRecord.app"
