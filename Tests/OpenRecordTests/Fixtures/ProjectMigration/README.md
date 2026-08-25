# Migration schema fixtures

The v1, v2, and v3 `.openrecord` directories are deterministic document-schema
fixtures. They retain the transparent bundle shape while intentionally omitting
large captured media; media discovery and complete bundle layout are covered by
`ProjectLibraryTests`, while these fixtures isolate JSON migration and save
integrity. The v1 cursor entry deliberately exercises preservation of a legacy
asset reference without requiring the referenced bitmap to be decoded.
