# OpenRecord v4.2 migration notes

OpenRecord v4.2 continues to write project document format **v8**. v4.1 introduced compact authored `storyBeats`; v4.2 adds no new authored schema. First Cut proposals and Privacy Firewall findings remain optional, disposable `analysis/suggestions.jsonl` and `analysis/privacy.jsonl` sidecars. Applying a proposal creates existing v8 project values, and accepted privacy findings create existing `RedactionRegion` values.

## Compatibility policy

- Formats v1–v7 open with behavior-preserving defaults and are not rewritten merely by opening.
- The first real save atomically upgrades a supported legacy document to v8; pre-v8 documents default `storyBeats` to an empty array.
- Current-format unknown top-level fields and all newer format versions are rejected without changing bytes.
- Supported nested unknown fields remain preserved by the raw-document merge path, including story beats matched by stable UUID.
- Missing, malformed, stale, partial, or incompatible analysis never blocks the authored project.
- Removing `analysis/` or disabling semantic capture does not change existing timeline edits or authored story beats.
- Removing First Cut or privacy sidecars loses only rebuildable review state; applied cuts, zooms, captions, chapters, and redactions remain ordinary v8 authored values.
- A Sanitized Share Copy is a new rendered derivative with an exact file allowlist. It never rewrites or makes claims about the privacy of the editable source bundle.
- CLI inspection, validation, and export never rewrite project metadata or edit documents.

The deterministic fixtures under `Tests/OpenRecordTests/Fixtures/ProjectMigration` cover v1 through v8. The historical v7 schema remains documented in [`PROJECT_FORMAT_V7.md`](PROJECT_FORMAT_V7.md).
