# OpenRecord v3.2 migration notes

OpenRecord v3.2 writes project document format **v7**. The format bump adds only portable project-template provenance and defaults:

- `projectTemplateID` — optional provenance; a project never depends on the template file.
- `defaultCaptionStyle` — the style used by newly added or transcript-generated captions.
- `defaultAnnotationStyle` — the optional style used by newly added annotations.

All concrete canvas, cursor, webcam, device-frame, keyboard, and export values continue to live in the ordinary project document. Recorded media and timed items are never stored in `.openrecordtemplate` files.

## Compatibility policy

- Formats v1–v6 open with behavior-preserving defaults and are not rewritten merely by opening.
- The first real save upgrades a supported legacy document to v7 with atomic replacement.
- Current-format unknown top-level fields and all newer format versions are rejected without changing bytes.
- Supported nested unknown fields remain preserved by the existing raw-document merge path.
- CLI inspection, validation, and export never rewrite project metadata or edit documents.

The deterministic fixtures under `Tests/OpenRecordTests/Fixtures/ProjectMigration` cover v1 through v7.
