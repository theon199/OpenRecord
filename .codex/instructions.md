# OpenRecord Codex Instructions

## Environment & Toolchain
- Apple Command Line Tools only (`/Library/Developer/CommandLineTools`).
- The system toolchain and SDK are verified functional and compatible.
- Never invoke `xcodebuild`.
- Never use `import XCTest` (use `import Testing` and `@Test`).
- Never run raw Mach-O executables directly; always use `./scripts/run.sh` or `./scripts/package-app.sh`.

## Stop & Ask Rule (No Self-Installations)
- **NEVER attempt to download or install toolchain updates, compilers, Xcode, SDKs, or external packages.**
- Always execute `swift test` or `swift build` directly to inspect actual compiler diagnostics rather than assuming version mismatches.
