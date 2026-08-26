# OpenRecord project format v7

An `.openrecord` project is an ordinary directory bundle. It is inspectable without running plugins or contacting a service.

```text
Example.openrecord/
  meta.json
  project.json
  recording/
    display.mp4
    webcam.mp4        optional
    mic.m4a           optional
    system.m4a        optional
    mouse.jsonl       optional
    clicks.jsonl      optional
    keys.jsonl        optional
    target.jsonl      optional
    thumb.jpg         optional cache
    cursors/          optional cursor PNG assets
```

## `meta.json`

Capture metadata contains creation/app version, source bounds and scale, capture target, optional per-track offsets/clock corrections, health warnings, and optional webcam capture information. Imported movies use display ID `0` as a sentinel and otherwise follow normal bundle ownership.

## `project.json`

`formatVersion` is `7`. Top-level families are:

- trim, edit decisions, speed segments, and the authoritative source/output mapping inputs;
- zoom, canvas, cursor sprites/effects, keyboard overlay, webcam overlay, and audio cleanup;
- captions, transcript, annotations, redactions, vector drawings, and device frame;
- video export settings and applied style/template provenance;
- `defaultCaptionStyle` and optional `defaultAnnotationStyle` for items created after a template is applied.

Timed items remain source-timestamped. Excluded ranges and speed segments determine ripple/output time through `ProjectTimeMapper`; project files never destructively rewrite recorded media.

## Template format

`.openrecordtemplate` is versioned JSON with canvas/aspect, cursor, webcam, caption, annotation, device-frame, keyboard, and export settings. It contains no project path, media URL, transcript, cut, or timed item. Applying it copies values into a project for portability.

## Compatibility and automation

See [`V3_MIGRATION.md`](V3_MIGRATION.md) for migration policy. `openrecord-cli inspect <bundle> --json` provides a machine-readable summary, and `openrecord-cli validate <bundle> --json` returns exit code `0` for valid bundles and `2` for validation failures.
