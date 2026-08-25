# OpenRecord export benchmark

`OpenRecordExportBenchmark` creates a deterministic synthetic H.264 `.openrecord`
bundle, exports it through the production `Exporter` using H.264 1080p, and
writes a sorted JSON report. By default all artifacts are kept under
`.build/openrecord-export-benchmark`.

Run a short smoke benchmark from the repository root:

```sh
swift run -c release OpenRecordExportBenchmark \
  --duration 2 \
  --work-dir .build/openrecord-export-benchmark-smoke
```

The command prints the report and writes `report.json`, the generated source
project, and `export-h264-1080p.mp4` in the selected work directory. The
default run uses a 300-second, 1920×1080, 30 fps source and is intentionally a
real export workload, not a unit test.

Useful options are `--width`, `--height`, `--fps`, `--report`,
`--prepare-only`, and `--reuse-source`. `--prepare-only` is useful for
inspecting or reusing the generated project without paying for an export;
`--reuse-source` requires a source created by an earlier run in the same work
directory.

The report includes source duration/resolution/frame rate and codec, output
codec/resolution, total export seconds, average export throughput in frames per
second, and the process peak resident memory when available. Export failures
include the underlying media error and the relevant artifact path.
