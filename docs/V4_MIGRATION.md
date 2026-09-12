# OpenRecord v4.3 migration and publishing notes

OpenRecord v4.3.0 continues to write project document format **v8**. v4.1
introduced compact authored `storyBeats`; v4.2 added no new authored schema;
v4.3 adds no authored project fields. Release Factory recipes, render plans,
output manifests, documentation, and Open Tutorial Packages are external
derived artifacts. They never put destination paths or publishing state in
`project.json`.

First Cut proposals and Privacy Firewall findings remain optional, disposable
`analysis/suggestions.jsonl` and `analysis/privacy.jsonl` sidecars. Applying a
proposal creates existing v8 project values, and accepted privacy findings
create existing `RedactionRegion` values.

## Compatibility policy

- Formats v1–v7 open with behavior-preserving defaults and are not rewritten merely by opening.
- The first real save atomically upgrades a supported legacy document to v8; pre-v8 documents default `storyBeats` to an empty array.
- Current-format unknown top-level fields and all newer format versions are rejected without changing bytes.
- Supported nested unknown fields remain preserved by the raw-document merge path, including story beats matched by stable UUID.
- Missing, malformed, stale, partial, or incompatible analysis never blocks the authored project.
- Removing `analysis/` or disabling semantic capture does not change existing timeline edits or authored story beats.
- Removing First Cut or privacy sidecars loses only rebuildable review state; applied cuts, zooms, captions, chapters, and redactions remain ordinary v8 authored values.
- A Sanitized Share Copy is a new rendered derivative with an exact file allowlist. It never rewrites or makes claims about the privacy of the editable source bundle.
- CLI inspection, validation, export, and publishing never rewrite project metadata or edit documents. The explicit `analyze` command may write only rebuildable analysis sidecars.

The v4.3 Release Factory reads a standalone JSON recipe. Both
`.openrecordrecipe` and `publish.json` are accepted names; the recipe's
`formatVersion` is currently `1`. A recipe contains an ordered `outputs` array
with stable output names and declarative settings. A representative recipe is:

```json
{
  "formatVersion": 1,
  "outputs": [
    {
      "name": "release-demo",
      "kind": "video",
      "aspect": "16:9",
      "codec": "h264",
      "resolution": "1080p"
    },
    {
      "name": "social",
      "kind": "video",
      "aspect": "9:16",
      "maxDuration": 60
    },
    {
      "name": "feature-loop",
      "kind": "gif",
      "storyBeat": "save-theme"
    },
    {
      "name": "guide",
      "kind": "markdown",
      "screenshots": "actions"
    }
  ]
}
```

Output entries may select a story beat, duration cap, safe area, filename,
codec, resolution, caption delivery, template, or overwrite policy. They must
remain declarative: no secrets, account identifiers, callbacks, arbitrary
executable commands, machine-specific destination paths, or remote-service
requirements are valid recipe data. Unsupported recipe versions and unknown
required fields fail before output installation.

The wire-level output fields are `name`, `kind`, `aspect`, `storyBeat`,
`maxDuration`, `templateID`, `codec`, `resolution`, `quality`, `frameRate`,
`captionDelivery`, `filename`, `overwrite`, `screenshots`, and
`includeTranscript`, plus normalized `safeArea` geometry. `kind` is `video`, `gif`, `markdown`, `html`, or
`tutorial`; `aspect` accepts `16:9`, `9:16`, `1:1`, or the compatibility
`4:3` standard. Documentation and tutorial screenshot settings can derive
action-centered still images without adding a new authored project format.

## RenderPlan and output compatibility

`RenderPlan` derives all requested variants from the same v8 project, shared
`FrameScene`, and `ProjectTimeMapper`. It can resolve:

- 16:9 tutorial/video;
- 9:16 social/changelog clip;
- 1:1 preview;
- story-beat GIF; and
- action-centered still images.

Responsive framing may reflow semantic focus and reserve safe areas for
captions, webcam, annotations, and redactions. It cannot select different
source content unless the recipe explicitly selects a story beat. Thus a
recipe is repeatable while each aspect remains legible and protected.

## Deterministic release manifest

`publish` writes one `manifest.json` in the output directory. The manifest is
the verification boundary and includes, at minimum:

- recipe and project format versions;
- source media and telemetry fingerprints;
- analyzer and render versions;
- each output's stable name, relative filename, kind, settings, and
  source/output durations;
- byte size and SHA-256 checksum for every generated file; and
- warnings, privacy-review state, and reproducibility limitations.

Manifest entries use portable relative paths, sorted output names, and stable
JSON encoding. A repeated publish from the same supported project, recipe,
and toolchain therefore produces a byte-stable manifest. `verify-output`
rejects missing, extra, changed, absolute, or escaping paths, checksum
mismatches, unsupported versions, and package privacy/network violations.

## CLI behavior

The dependency-free CLI supports the following Phase 3 flow:

```text
openrecord-cli analyze Demo.openrecord [--no-vision] [--json]
openrecord-cli publish Demo.openrecord --recipe release.openrecordrecipe --output ./Artifacts [--json]
openrecord-cli verify-output ./Artifacts/manifest.json [--json]
```

`analyze` reads capture evidence and may atomically refresh rebuildable local
analysis. `publish` is non-interactive once the recipe is complete and returns
success only after every requested output and the manifest are installed.
`verify-output` reads only the generated artifact set and can be used as a CI
or handoff gate. Existing `inspect`, `validate`, `export`, and `batch`
commands remain supported.

Exit behavior is stable for scripts:

| Condition | Exit code |
|---|---:|
| Requested analysis, publish, or verification completed | `0` |
| Project, recipe, rendering, output, checksum, or package failure | `1` |
| Invalid arguments or unsupported command/recipe option | `64` |

Failures are actionable and written to stderr. A failed publish does not
rewrite the source project and must not leave a manifest that claims success.

## Documentation outputs

Markdown and HTML documentation are generated from approved ActionMap steps,
approved labels, transcript ranges, and exact action-centered screenshots.
Structured templates produce a step title, a short approved transcript
explanation, keyboard shortcut or click notes, a tutorial-player timestamp
link, alt text, and caption files where requested. Relative asset references
are checked against the generated output directory so a document cannot point
at a missing or absolute-path asset.

## Open Tutorial Package contract

The package is a separate static directory with this exact v4.3 file set:

```text
Tutorial.openrecordweb/
  index.html
  player.js
  player.css
  video.mp4
  manifest.json
  captions.vtt
  cursor.png
  poster.jpg
```

`video.mp4` is the rendered derivative with accepted redactions baked in;
`manifest.json` carries the package schema, output duration, approved steps,
transcript, and privacy-filtered cursor/click/shortcut timing. The outer
release manifest carries package byte sizes and checksums. `index.html`, `player.js`, and
`player.css` implement searchable transcript and ActionMap step navigation,
optional pause-after-step behavior, cursor visibility/scale, click and
approved shortcut overlays, and standard MP4 playback. `captions.vtt` may be
empty when no captions were approved, but the file remains part of the stable
package shape. `cursor.png` and `poster.jpg` are local assets only.

The package never includes raw display media, rejected actions, private OCR
evidence, or unrestricted keyboard telemetry. Copyable commands or links are
included only when explicitly authored. It makes no external requests: no
analytics, remote fonts, CDN assets, account, callback, or OpenRecord server is
needed. It works from a local folder (`file://`) and from a generic static
host using relative links only. The editable `.openrecord` source remains
untouched and retains original capture media; this package is not a claim that
the source bundle is sanitized.

## Multi-source timeline and Patch Takes

In OpenRecord v4.4.0, format v8 is extended with explicit multi-source ownership:

- `mediaSources` describes all source streams (primary display and patch takes) with stable UUIDs, relative paths, timing origins, track offsets, capture health, and video dimensions.
- `timelineSpans` defines ordered output spans referencing a `sourceID`, half-open source interval (`sourceStart` ..< `sourceEnd`), seam transition, transition duration, and audio mode.
- Single-source projects omit `mediaSources` and `timelineSpans` during encoding. Older format v8 documents and migrated v1–v7 projects decode these fields as empty arrays and fall back seamlessly to single-source mapping.
- Replacement takes are stored immutably in `recording/takes/<source-id>/` and never mutate the primary recording. Reverting a take restores original spans losslessly.
- Unreferenced temporary takes in `staging/recording/takes` are pruned automatically during `ProjectLibrary.saveCopy`.

The deterministic fixtures under `Tests/OpenRecordTests/Fixtures/ProjectMigration` cover v1 through v8. The historical v7 schema remains documented in [`PROJECT_FORMAT_V7.md`](PROJECT_FORMAT_V7.md).
