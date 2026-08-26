# OpenRecord - Copilot / Codex Instructions

## Critical Directive: No Self-Installations / Stop & Ask
- If a build, toolchain, or compilation issue occurs, **do NOT attempt to install or upgrade toolchains, compilers, Xcode, SDKs, Homebrew packages, or dependencies**.
- **STOP immediately and notify the user** with the exact error details.

## Toolchain & Build
- Apple Command Line Tools only (`/Library/Developer/CommandLineTools`).
- Never run `xcodebuild`.
- Tests use `import Testing` (`@Test`), never `import XCTest`.
- Run/launch via `./scripts/run.sh` or `./scripts/package-app.sh`.
