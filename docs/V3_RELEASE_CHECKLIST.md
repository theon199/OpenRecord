# OpenRecord v3.2 release checklist

## Automated gates

- [x] Full Swift test suite, including v1–v7 migration and v3.2 template/batch/CLI/import coverage.
- [x] Debug build for app, benchmark, and CLI products.
- [x] Apple Silicon release build and deterministic benchmark smoke (`./scripts/verify-v3-release.sh`).
- [x] Packaged `dist/OpenRecord.app` metadata, architecture, and code-signature verification.
- [x] CLI help plus inspect/validate smoke against a generated project.
- [ ] Final git diff/status review, tagged commit, GitHub push, and release artifacts.

The unchecked automated items are completed by the final release run and should be checked before tagging.

## Hardware/manual evidence still recommended

These checks require real devices, macOS permission prompts, or subjective review and are not represented as automated evidence:

- Screen/window capture with Screen Recording, Microphone, and Accessibility prompts on a clean macOS account.
- Real camera and microphone capture, including disconnect/interruption behavior.
- 30-minute, 1-hour, and 2-hour screen/window soak captures from the existing soak protocol.
- Import and edit a real iPhone recording containing both video and audio.
- Final visual/interaction review of template selection and the batch queue.
- Developer ID signing, notarization, and Gatekeeper verification if distributing a notarized build.

The release can remain fully local and non-notarized; those manual checks do not change project-file correctness or deterministic automated coverage.
