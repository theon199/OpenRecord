# OpenRecord Codex Instructions

## Stop & Ask Rule (No Self-Installations)
- **NEVER attempt to download or install toolchain updates, compilers, Xcode, SDKs, or external packages.**
- If you encounter a toolchain incompatibility or missing tool, **STOP IMMEDIATELY and report the error to the user.**

## Environment & Build Rules
- Use Apple Command Line Tools (`/Library/Developer/CommandLineTools`) and SwiftPM (`swift build`, `swift test`).
- Never invoke `xcodebuild`.
- Never use `import XCTest` (use `import Testing` and `@Test`).
- Never run raw Mach-O executables directly; always use `./scripts/run.sh` or `./scripts/package-app.sh`.
