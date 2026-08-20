# Model reconstruction prompts

## `EditorState.swift` (insertion markers retained)

Keep generic editor state, undo, selection, document mutation, clipboard, and image import. At the marked locations restore the hardware-derived image storage cap of 1,664 pixels, equal to twice the maximum 832-dot fixed axis; the common target head is 384 dots at 203 dots per inch. Restore density clamping to levels one through five and trailing-feed clamping to 0 through 2,000 dots.

## `VectorImportService.swift` (insertion marker retained)

Keep the generic SVG/PDF import pipeline. Restore only the marked explanatory note that vector content remains sharp until sampled by a 203-dots-per-inch print rasterizer.
