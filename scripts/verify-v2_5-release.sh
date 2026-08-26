#!/usr/bin/env bash
# Verify the deterministic v2.5 release gates. Hardware/manual checks live in
# docs/V2_5_RELEASE_CHECKLIST.md and are intentionally not inferred here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXPECTED_VERSION="2.5.0"
EXPECTED_BUILD="250"
APP="${APP_PATH:-$ROOT/dist/OpenRecord.app}"
ARTIFACTS="$ROOT/.build/openrecord-v2_5-release"
MODE="default"

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-v2_5-release.sh [--static-only] [--full-benchmark]

Default mode runs swift test, a release build, ad-hoc app packaging, app
metadata/signature checks, and a short deterministic benchmark smoke.

  --static-only       Validate source metadata and an already packaged app.
                      Intended for CI after its build/test/package steps.
  --full-benchmark    After the default gates, run the 300-second benchmark
                      and require totalExportSeconds < 180.
  --help              Show this help.
EOF
}

fail() {
  echo "verify-v2_5-release: error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only)
      [[ "$MODE" == "default" ]] || fail "--static-only cannot be combined with --full-benchmark"
      MODE="static"
      ;;
    --full-benchmark)
      [[ "$MODE" == "default" ]] || fail "--full-benchmark cannot be combined with --static-only"
      MODE="full"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option '$1' (use --help)"
      ;;
  esac
  shift
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

source_metadata_check() {
  local info_file="$ROOT/Sources/OpenRecord/Contracts/OpenRecordInfo.swift"
  local plist="$ROOT/Resources/Info.plist"

  [[ -f "$info_file" ]] || fail "missing $info_file"
  [[ -f "$plist" ]] || fail "missing $plist"
  grep -Fq "appVersion = \"$EXPECTED_VERSION\"" "$info_file" \
    || fail "OpenRecordInfo.appVersion is not $EXPECTED_VERSION"

  local plist_version plist_build
  plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)" \
    || fail "could not read CFBundleShortVersionString from $plist"
  plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)" \
    || fail "could not read CFBundleVersion from $plist"
  [[ "$plist_version" == "$EXPECTED_VERSION" ]] \
    || fail "Resources/Info.plist version is $plist_version (expected $EXPECTED_VERSION)"
  [[ "$plist_build" == "$EXPECTED_BUILD" ]] \
    || fail "Resources/Info.plist build is $plist_build (expected $EXPECTED_BUILD)"
  echo "✓ source metadata: $EXPECTED_VERSION ($EXPECTED_BUILD)"
}

bundle_check() {
  local executable="$APP/Contents/MacOS/OpenRecord"
  local bundle_plist="$APP/Contents/Info.plist"
  [[ -d "$APP" ]] || fail "missing packaged app: $APP"
  [[ -x "$executable" ]] || fail "missing executable: $executable"
  [[ -f "$bundle_plist" ]] || fail "missing bundle Info.plist: $bundle_plist"

  local bundle_version bundle_build
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle_plist" 2>/dev/null)" \
    || fail "could not read bundle version"
  bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle_plist" 2>/dev/null)" \
    || fail "could not read bundle build"
  [[ "$bundle_version" == "$EXPECTED_VERSION" ]] \
    || fail "bundle version is $bundle_version (expected $EXPECTED_VERSION)"
  [[ "$bundle_build" == "$EXPECTED_BUILD" ]] \
    || fail "bundle build is $bundle_build (expected $EXPECTED_BUILD)"

  codesign --verify --deep --strict --verbose=2 "$APP"
  local architectures
  architectures="$(lipo -archs "$executable")"
  [[ " $architectures " == *" arm64 "* ]] \
    || fail "packaged executable architectures are '$architectures' (arm64 required)"
  echo "✓ package: $APP ($architectures, $EXPECTED_VERSION/$EXPECTED_BUILD)"
}

benchmark_report_seconds() {
  local report="$1"
  awk '
    /"totalExportSeconds"[[:space:]]*:/ {
      value = $0
      sub(/^.*"totalExportSeconds"[[:space:]]*:[[:space:]]*/, "", value)
      sub(/[^0-9.eE+-].*$/, "", value)
      if (value != "") { print value; found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "$report"
}

run_smoke_benchmark() {
  local smoke_dir="$ARTIFACTS/smoke"
  local report="$ARTIFACTS/smoke-report.json"
  mkdir -p "$smoke_dir"
  echo "Running deterministic benchmark smoke…"
  swift run -c release --arch arm64 OpenRecordExportBenchmark \
    --duration 2 --width 640 --height 360 --fps 24 \
    --work-dir "$smoke_dir" --report "$report"
  [[ -s "$report" ]] || fail "benchmark smoke did not write $report"
  grep -Eq '"totalExportSeconds"[[:space:]]*:[[:space:]]*[0-9]' "$report" \
    || fail "benchmark smoke report has no completed export time"
  echo "✓ benchmark smoke: $report"
}

run_full_benchmark() {
  local benchmark_dir="$ARTIFACTS/full"
  local report="$ARTIFACTS/full-report.json"
  mkdir -p "$benchmark_dir"
  echo "Running full 300-second benchmark (target: totalExportSeconds < 180)…"
  swift run -c release --arch arm64 OpenRecordExportBenchmark \
    --duration 300 --width 1920 --height 1080 --fps 30 \
    --work-dir "$benchmark_dir" --report "$report"
  [[ -s "$report" ]] || fail "full benchmark did not write $report"
  local seconds
  seconds="$(benchmark_report_seconds "$report")" \
    || fail "full benchmark report has no totalExportSeconds value"
  awk -v seconds="$seconds" 'BEGIN { if (!(seconds < 180)) exit 1 }' \
    || fail "full benchmark measured totalExportSeconds=$seconds (must be < 180)"
  echo "✓ full benchmark: totalExportSeconds=$seconds ($report)"
}

require_command swift
require_command codesign
require_command lipo
require_command /usr/libexec/PlistBuddy
source_metadata_check

if [[ "$MODE" == "static" ]]; then
  bundle_check
  echo "v2.5 static-only verification passed."
  exit 0
fi

mkdir -p "$ARTIFACTS"
echo "Running full Swift test suite…"
swift test
echo "✓ Swift tests"

echo "Building release…"
swift build -c release --arch arm64
echo "✓ release build"

echo "Packaging ad-hoc Apple Silicon app…"
CONFIGURATION=release CODESIGN_IDENTITY=- ARCH=arm64 \
  "$ROOT/scripts/package-app.sh"
bundle_check
run_smoke_benchmark

if [[ "$MODE" == "full" ]]; then
  run_full_benchmark
fi

echo "v2.5 release verification passed (manual/hardware gates remain checklist-driven)."
