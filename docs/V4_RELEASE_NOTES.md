# OpenRecord 4.3.0 release notes

OpenRecord 4.3 turns one local recording into a reproducible set of publish
artifacts. The source remains a transparent, editable `.openrecord` bundle;
recipes and generated outputs remain external to that bundle.

## Release Factory

An external `.openrecordrecipe` or `publish.json` file declares an ordered
`outputs` array and uses `formatVersion: 1`. An output can request video, GIF,
Markdown, HTML, or an Open Tutorial Package; documentation/tutorial screenshot
settings can derive action-centered stills. Entries
may select an aspect, story beat, duration cap, codec, resolution, captions,
safe area, filename, template, and overwrite policy.

Recipes are declarative and portable. They contain no secrets, account
identifiers, callbacks, arbitrary executable commands, machine-specific
destination paths, or remote-service requirements. They do not add publishing
state or destination paths to `project.json`.

## Responsive RenderPlan

Every output derives from the same project, `ProjectTimeMapper`, and shared
`FrameScene`. Supported variants are:

- 16:9 tutorial/video;
- 9:16 social/changelog clip;
- 1:1 preview;
- story-beat GIF; and
- action-centered still images.

Semantic focus can reflow for a variant while preserving caption, webcam,
annotation, and redaction safe areas. A variant cannot change source content
unless the recipe explicitly selects a story beat.

## CLI publishing flow

```text
openrecord-cli analyze Demo.openrecord [--no-vision] [--json]
openrecord-cli publish Demo.openrecord --recipe release.openrecordrecipe --output ./Artifacts [--json]
openrecord-cli verify-output ./Artifacts/manifest.json [--json]
```

`analyze` may refresh only rebuildable local analysis sidecars. `publish` is
headless and non-interactive once configured, and installs a manifest only
after all requested outputs succeed. `verify-output` is a read-only gate for
generated artifacts. Existing `inspect`, `validate`, `export`, and `batch`
commands remain available.

The stable exit contract is:

| Condition | Exit code |
|---|---:|
| All requested work completed and checks passed | `0` |
| Project, recipe, rendering, output, checksum, or package failure | `1` |
| Invalid arguments or unsupported command/option | `64` |

Diagnostics are actionable and go to stderr. A failed publish does not mutate
the source project or leave a success manifest.

## Deterministic manifest

Each publish directory contains `manifest.json` with:

- project and recipe format versions;
- source media and telemetry fingerprints;
- analyzer and render versions;
- stable output names, portable relative filenames, output kinds/settings,
  and source/output durations;
- byte sizes and SHA-256 checksums; and
- warnings, privacy-review state, and reproducibility limitations.

Manifest encoding and output ordering are stable. Repeating a publish with the
same supported project, recipe, and toolchain produces a byte-stable manifest.
Verification rejects missing, extra, absolute, or escaping paths, checksum
mismatches, unsupported versions, and package privacy/network violations.

## Documentation outputs

Generated Markdown and HTML use structured templates populated from approved
ActionMap labels, transcript ranges, and exact action-centered screenshots.
Each step can include an approved title and transcript explanation, a shortcut
or click note, a tutorial-player timestamp link, alt text, and caption files.
Relative generated-asset references are validated so the document can be
reviewed from Finder or served by a generic static host.

## Open Tutorial Package

The package is a separate static directory with the exact v4.3 file set:

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

`index.html`, `player.js`, and `player.css` implement local transcript and
ActionMap search, step navigation, optional pause-after-step mode, cursor
visibility/scale, click and approved shortcut overlays, and standard MP4
playback. `manifest.json` describes schema, duration, steps, transcript, and
the privacy-filtered cursor/click/shortcut timing used by the local player.
The outer release manifest supplies byte sizes and checksums for every package
file. `video.mp4` is the rendered derivative with
accepted redactions baked in. `captions.vtt` remains in the stable package
shape and may be empty when no captions were approved. `cursor.png` and
`poster.jpg` are local assets.

The package never contains raw display media, rejected actions, private OCR
evidence, or unrestricted keyboard telemetry. Copyable commands and links are
included only when explicitly authored. No analytics, remote fonts, CDN
assets, accounts, callbacks, or OpenRecord server are used or required. The
package works from a local folder (`file://`) and a generic static host using
relative links only. The editable source bundle remains unchanged and retains
its original capture; the package is not a sanitization claim about that
source.

## Format-v8 compatibility

v4.3.0 continues to write project document format **v8**. Recipes, RenderPlan
values, manifests, documentation, and tutorial packages are derived outputs;
they do not add authored top-level fields. Projects from v1–v7 retain the
existing read-only-open and first-save migration behavior. Unknown current
top-level fields and newer versions remain rejected, while supported nested
unknown fields remain preserved. Missing, malformed, stale, partial, or future
analysis remains rebuildable and does not block project open or publishing.

## Verification gates

The automated Phase 3 gates recorded in [`STATUS.md`](../STATUS.md) passed on
2026-09-11. They cover repeated byte-stable publishing, deterministic and
protected RenderPlan variants, headless CLI behavior, portable documentation
links, the exact tutorial package allowlist, cut-aware player timing, external
request exclusion, the full Swift test suite, and an Apple Silicon release
build.

Manual review still covers dense real-world recordings, codec playback,
captions, webcam/annotations/redactions, privacy boundaries, and clean-folder
or `file://` tutorial playback with networking disabled.
