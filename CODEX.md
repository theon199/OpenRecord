# OpenRecord - OpenAI Codex Guidelines

## Environment & Toolchain
- **Active Developer Directory**: `/Library/Developer/CommandLineTools` (Apple Command Line Tools only).
- **Environment Status**: The system toolchain and SDK are **verified functional and compatible**. Always execute `swift test` or `swift build` directly.
- **No Xcode**: `xcodebuild` is not available and should never be called.
- **Zero Third-Party Dependencies**: Do not download or add external packages.

## CRITICAL: Toolchain Error Handling & No Self-Installations
- **NEVER attempt to download or install new toolchains, compilers, Xcode, SDKs, Homebrew formulas, CocoaPods, or external packages.**
- If an actual compiler error occurs, inspect the code and test failures directly. Do not assume toolchain/SDK mismatches without actively running `swift build` or `swift test`.

## Build, Test & Run Workflows
- **Build**: `swift build` (or `swift build -c release --arch arm64`)
- **Test**: `swift test` (Always use `import Testing`, NEVER `import XCTest`)
- **Package**: `./scripts/package-app.sh`
- **Run**: `./scripts/run.sh` (Never run raw binary directly from `.build/` to prevent breaking TCC permissions)
- **Verify**: `./scripts/verify-v2_5-release.sh`
