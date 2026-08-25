# Compositor golden fixtures

`manifest.json` stores compact block-average fingerprints of deterministic
320×180 frames rendered through the production `ExportCompositor.render` path
into BGRA pixel buffers. The cases cover the v2 overlay stack without checking
in large media or platform-sensitive PNG encodings.

The plain solid/source frame also enforces an exact FNV-1a pixel hash. Filtered
and text cases use per-frame maximum and mean channel tolerances recorded in the
manifest so small Core Image/Core Text rasterization differences are explicit.

These are export raster goldens. Preview parity is tested through the shared
layout and timestamp authorities; SwiftUI, AVPlayerLayer, Core Image, and Core
Text are not expected to rasterize every antialiased edge identically.
