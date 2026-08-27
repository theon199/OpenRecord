#!/usr/bin/env bash
# Deterministic OpenRecord v3.2 release gates. Hardware-only checks remain in
# docs/V3_RELEASE_CHECKLIST.md and are never inferred from synthetic fixtures.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

EXPECTED_VERSION="3.2.1"
EXPECTED_BUILD="321"
APP_PATH="${APP_PATH:-$PROJECT_DIR/dist/OpenRecord.app}"
ARTIFACT_DIR="$PROJECT_DIR/.build/openrecord-v3-release"
RUN_MODE="default"

usage() {
  printf '%s\n' \
    'Usage: ./scripts/verify-v3-release.sh [--static-only] [--full-benchmark]' \
    '' \
    'Default: tests, release build, ad-hoc package verification, CLI smoke,' \
    'format-v7 validation, and a short deterministic export benchmark.' \
    '' \
    '  --static-only       Verify source metadata and existing build artifacts.' \
    '  --full-benchmark    Also require the 300-second benchmark to finish in <180s.'
}

fail() {
  printf 'verify-v3-release: error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only)
      [[ "$RUN_MODE" == "default" ]] || fail 'verification modes cannot be combined'
      RUN_MODE="static"
      ;;
    --full-benchmark)
      [[ "$RUN_MODE" == "default" ]] || fail 'verification modes cannot be combined'
      RUN_MODE="full"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option '$1'"
      ;;
  esac
  shift
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

source_metadata_check() {
  local info_file="$PROJECT_DIR/Sources/OpenRecord/Contracts/OpenRecordInfo.swift"
  local plist_file="$PROJECT_DIR/Resources/Info.plist"
  grep -Fq "appVersion = \"$EXPECTED_VERSION\"" "$info_file" \
    || fail "OpenRecordInfo.appVersion is not $EXPECTED_VERSION"

  local plist_version plist_build
  plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_file")"
  plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist_file")"
  [[ "$plist_version" == "$EXPECTED_VERSION" ]] \
    || fail "Info.plist version is $plist_version (expected $EXPECTED_VERSION)"
  [[ "$plist_build" == "$EXPECTED_BUILD" ]] \
    || fail "Info.plist build is $plist_build (expected $EXPECTED_BUILD)"
  grep -Fq 'currentFormatVersion = 7' "$PROJECT_DIR/Sources/OpenRecord/Contracts/Project.swift" \
    || fail 'ProjectDocument.currentFormatVersion is not 7'
  printf '✓ source metadata: %s (%s), project format v7\n' "$EXPECTED_VERSION" "$EXPECTED_BUILD"
}

build_artifact_paths() {
  BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
  CLI_PATH="$BIN_DIR/openrecord-cli"
}

bundle_check() {
  local executable="$APP_PATH/Contents/MacOS/OpenRecord"
  local bundle_plist="$APP_PATH/Contents/Info.plist"
  [[ -d "$APP_PATH" ]] || fail "missing packaged app: $APP_PATH"
  [[ -x "$executable" ]] || fail "missing app executable: $executable"
  [[ -f "$bundle_plist" ]] || fail "missing bundle Info.plist"

  local version build architectures
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle_plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle_plist")"
  [[ "$version" == "$EXPECTED_VERSION" ]] || fail "bundle version is $version"
  [[ "$build" == "$EXPECTED_BUILD" ]] || fail "bundle build is $build"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  architectures="$(lipo -archs "$executable")"
  [[ " $architectures " == *' arm64 '* ]] || fail "app architectures are '$architectures'"
  printf '✓ package: %s (%s)\n' "$APP_PATH" "$architectures"
}

cli_check() {
  [[ -x "$CLI_PATH" ]] || fail "missing CLI executable: $CLI_PATH"
  "$CLI_PATH" --help >/dev/null
  [[ "$("$CLI_PATH" --version)" == "openrecord-cli $EXPECTED_VERSION" ]] \
    || fail 'CLI version does not match release metadata'
  local architectures
  architectures="$(lipo -archs "$CLI_PATH")"
  [[ " $architectures " == *' arm64 '* ]] || fail "CLI architectures are '$architectures'"
  printf '✓ CLI: %s (%s)\n' "$CLI_PATH" "$architectures"
}

run_smoke_benchmark() {
  local smoke_dir="$ARTIFACT_DIR/smoke"
  local report="$ARTIFACT_DIR/smoke-report.json"
  mkdir -p "$smoke_dir"
  swift run -c release --arch arm64 OpenRecordExportBenchmark \
    --duration 2 --width 640 --height 360 --fps 24 \
    --work-dir "$smoke_dir" --report "$report" >/dev/null
  [[ -s "$report" ]] || fail "benchmark did not write $report"
  grep -Eq '"totalExportSeconds"[[:space:]]*:[[:space:]]*[0-9]' "$report" \
    || fail 'benchmark report has no completed export time'

  local generated_project="$smoke_dir/synthetic-640x360-24fps.openrecord"
  "$CLI_PATH" inspect "$generated_project" --json >/dev/null
  "$CLI_PATH" validate "$generated_project" --json >/dev/null
  printf '✓ benchmark + CLI project validation: %s\n' "$report"
}

run_full_benchmark() {
  local benchmark_dir="$ARTIFACT_DIR/full"
  local report="$ARTIFACT_DIR/full-report.json"
  mkdir -p "$benchmark_dir"
  swift run -c release --arch arm64 OpenRecordExportBenchmark \
    --duration 300 --width 1920 --height 1080 --fps 30 \
    --work-dir "$benchmark_dir" --report "$report" >/dev/null
  local seconds
  seconds="$(sed -nE 's/.*"totalExportSeconds"[[:space:]]*:[[:space:]]*([0-9.eE+-]+).*/\1/p' "$report" | head -n 1)"
  [[ -n "$seconds" ]] || fail 'full benchmark report has no export time'
  awk -v value="$seconds" 'BEGIN { exit !(value < 180) }' \
    || fail "full benchmark took ${seconds}s (must be <180s)"
  printf '✓ full benchmark: %ss\n' "$seconds"
}

require_command swift
require_command codesign
require_command lipo
require_command /usr/libexec/PlistBuddy
source_metadata_check
build_artifact_paths

if [[ "$RUN_MODE" == "static" ]]; then
  bundle_check
  cli_check
  printf 'OpenRecord v3.2 static verification passed.\n'
  exit 0
fi

mkdir -p "$ARTIFACT_DIR"
swift test
swift build -c release --arch arm64
CONFIGURATION=release CODESIGN_IDENTITY=- ARCH=arm64 \
  "$PROJECT_DIR/scripts/package-app.sh"
build_artifact_paths
bundle_check
cli_check
run_smoke_benchmark

if [[ "$RUN_MODE" == "full" ]]; then
  run_full_benchmark
fi

printf 'OpenRecord v3.2 deterministic release verification passed.\n'
