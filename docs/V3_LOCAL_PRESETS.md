# OpenRecord v3 local style presets

OpenRecord stores user-created editor style presets as individual JSON files in:

```text
~/Library/Application Support/OpenRecord/Presets/
```

Each file uses preset format version 1. The editor can create these files with
**Reusable Presets → Save Current**, load them on launch, and apply them without
an account or network connection.

```json
{
  "formatVersion": 1,
  "id": "user-product-tutorial",
  "name": "Product Tutorial",
  "cursor": {
    "scale": 0.65,
    "clickEmphasis": true,
    "halo": true,
    "motionBlur": {
      "enabled": true,
      "amount": 0.6
    }
  }
}
```

The optional top-level style families are `caption`, `webcam`, `annotation`,
`cursor`, and `export`. Missing families leave the corresponding project values
unchanged. Presets with a newer `formatVersion`, malformed JSON, or unsupported
payloads are ignored rather than partially applied.

Applying a preset copies its concrete values into `project.json`; the project
does not depend on the preset file afterward. `appliedPresetIDs` records only
provenance, so moving a `.openrecord` bundle to another Mac preserves its look.
