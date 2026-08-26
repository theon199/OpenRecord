# Migration schema fixtures

The v1 through v7 `.openrecord` directories are deterministic document-schema
fixtures. They retain the transparent bundle shape while intentionally omitting
large captured media; media discovery and complete bundle layout are covered by
`ProjectLibraryTests`, while these fixtures isolate JSON migration and save
integrity. The v1 cursor entry deliberately exercises preservation of a legacy
asset reference without requiring the referenced bitmap to be decoded. The v4
fixture includes representative non-destructive edit decisions; the unknown
decision fixture verifies unsupported kinds remain read-only.
The v5 fixture includes representative transcript, cursor-effect, zoom metadata,
and preset provenance. The v6 fixture adds redaction, vector drawing, richer
annotation animation, device-frame, webcam styling, and audio-polish fields.
The v7 fixture adds project-template provenance and portable caption/annotation
defaults used for newly created timed items.
