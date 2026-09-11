# OpenRecord v4.1 migration notes

OpenRecord v4.1 writes project document format **v8**. The format bump adds compact authored `storyBeats` for portable ActionMap corrections. Derived action and OCR evidence stays in the optional, disposable `analysis/` directory.

## Compatibility policy

- Formats v1–v7 open with behavior-preserving defaults and are not rewritten merely by opening.
- The first real save atomically upgrades a supported legacy document to v8; pre-v8 documents default `storyBeats` to an empty array.
- Current-format unknown top-level fields and all newer format versions are rejected without changing bytes.
- Supported nested unknown fields remain preserved by the raw-document merge path, including story beats matched by stable UUID.
- Missing, malformed, stale, partial, or incompatible analysis never blocks the authored project.
- Removing `analysis/` or disabling semantic capture does not change existing timeline edits or authored story beats.
- CLI inspection, validation, and export never rewrite project metadata or edit documents.

The deterministic fixtures under `Tests/OpenRecordTests/Fixtures/ProjectMigration` cover v1 through v8. The historical v7 schema remains documented in [`PROJECT_FORMAT_V7.md`](PROJECT_FORMAT_V7.md).
