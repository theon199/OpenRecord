# OpenRecord project format v8

An `.openrecord` project is an ordinary local directory bundle. It is inspectable without plugins, accounts, or network access.

```text
Example.openrecord/
  meta.json
  project.json
  recording/
    display.mp4
    webcam.mp4             optional
    mic.m4a                optional
    system.m4a             optional
    mouse.jsonl            optional
    clicks.jsonl           optional
    keys.jsonl             optional
    typing.jsonl           optional, geometry/activity only
    target.jsonl           optional legacy-compatible target geometry
    semantic-targets.jsonl optional privacy-filtered semantic controls
    thumb.jpg              optional cache
    cursors/               optional cursor PNG assets
  analysis/                optional and rebuildable
    manifest.json
    actions.jsonl
    ocr.jsonl
    privacy.jsonl
    suggestions.jsonl
    index.json
```

## `meta.json`

Capture metadata contains creation/app version, source bounds and scale, capture target, optional per-track offsets/clock corrections, health warnings, and optional webcam capture information. Imported movies use display ID `0` as a sentinel and otherwise follow normal bundle ownership.

## `project.json`

`formatVersion` is `8`. It retains the v7 non-destructive editing, presentation, transcript, template, and export fields and adds `storyBeats`.

A story beat contains a stable authored UUID, source-time range, kind and user-approved title, optional application bundle ID, stable evidence references, lock/suppression state, and optional compact provenance. Rename, merge, split, suppress, lock, and chapter conversion are therefore portable and participate in save/undo even if analysis is removed.

All timed items remain source-timestamped. `ProjectTimeMapper` resolves them through trim, exclusion cuts, and speed regions; recorded media and evidence timestamps are never destructively rewritten.

## Semantic capture privacy

`semantic-targets.jsonl` is optional and independent from basic cursor capture. It may contain control role, application bundle ID, normalized bounds, an approved static-control label, confidence/source, and a fixed degradation reason. Capture never queries or persists Accessibility values, selected text, secure-field content, ordinary typed characters, or window titles. Labels are allowlisted by role, length-bounded, and rejected when they resemble private identifiers, URLs, email addresses, paths, or tokens.

`target.jsonl` remains the existing window/display geometry stream so older project behavior is preserved.

## Rebuildable analysis

Derived actions and OCR evidence belong under `analysis/`, not in the authored document. The manifest fingerprints relevant source files. Missing, stale, malformed, partial, or future analysis never prevents project open, save, preview, or export; it can be rebuilt locally or deleted without changing authored edits.

## Compatibility and automation

See [`V4_MIGRATION.md`](V4_MIGRATION.md) for migration policy. `openrecord-cli inspect <bundle> --json` provides a privacy-safe machine-readable summary, and `openrecord-cli validate <bundle> --json` returns exit code `0` for valid bundles and `2` for validation failures.
