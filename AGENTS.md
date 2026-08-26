# OpenRecord - AI Agent Instructions

## CRITICAL: Toolchain Error Handling & No Self-Installations
- **NEVER attempt to download or install new toolchain versions, compilers, Xcode, SDKs, Homebrew packages, CocoaPods, or external tools yourself.**
- If you encounter a toolchain mismatch, missing CLI tool, or build environment problem: **STOP IMMEDIATELY, do not try automated workarounds or downloads, and report the issue to the user.**

## Environment & Toolchain
- **Platform**: macOS Apple Silicon (`arm64`), Apple Command Line Tools (`/Library/Developer/CommandLineTools`) ONLY.
- **NO Full Xcode**: Full Xcode and `xcodebuild` are NOT installed and must NEVER be invoked.
- **NO External Dependencies**: The project uses pure native Apple frameworks (`SwiftUI`, `ScreenCaptureKit`, `AVFoundation`, `MetalKit`, etc.) and SwiftPM. Do NOT add external dependencies.

## Standard Development Workflows
- **Debug build**: `swift build`
- **Release build**: `swift build -c release --arch arm64`
- **Run Unit Tests**: `swift test`
- **Package App Bundle**: `./scripts/package-app.sh` (builds and assembles `dist/OpenRecord.app` with `OpenRecord Dev` keychain signing)
- **Launch/Run App**: `./scripts/run.sh`
- **Release Verification**: `./scripts/verify-v2_5-release.sh`

## Testing Rules
- Use Apple's modern Swift **`Testing`** framework (`import Testing`, `@Test`, `#expect(...)`).
- **NEVER use `import XCTest`** or `XCTestCase`. Standalone Command Line Tools does not include `XCTest.framework`.

## macOS TCC Permissions
- Screen Recording, Microphone, and Accessibility event tap grants attach to the signed `.app` bundle.
- **NEVER run the raw Mach-O binary directly** from `.build/.../OpenRecordApp`. Always launch through `./scripts/run.sh` or `open dist/OpenRecord.app`.
