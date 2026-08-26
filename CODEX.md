# OpenRecord - OpenAI Codex Guidelines

## CRITICAL: Toolchain Error Handling & No Self-Installations
- **NEVER attempt to download or install new toolchains, compilers, Xcode, SDKs, Homebrew formulas, CocoaPods, or external packages.**
- If a compilation or environment issue arises: **STOP IMMEDIATELY, do not run installation scripts, and notify the user with the exact error.**

## Environment
- **Active Developer Directory**: `/Library/Developer/CommandLineTools` (Apple Command Line Tools only).
- **No Xcode**: `xcodebuild` is not available and should never be called.
- **Zero Third-Party Dependencies**: Do not download or add external packages.

## Build, Test & Run Workflows
- **Build**: `swift build` (or `swift build -c release --arch arm64`)
- **Test**: `swift test` (Always use `import Testing`, NEVER `import XCTest`)
- **Package**: `./scripts/package-app.sh`
- **Run**: `./scripts/run.sh` (Never run raw binary directly from `.build/` to prevent breaking TCC permissions)
- **Verify**: `./scripts/verify-v2_5-release.sh`
