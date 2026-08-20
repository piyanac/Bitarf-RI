# Canvas reconstruction prompts

## `CanvasViewController.swift` (insertion marker retained)

Keep the generic scrolling, selection, editing, keyboard, gesture, zoom, and text-control behavior. At the marked location restore the hardware-derived font control ceiling of 288 dots. The original layout commentary used a common 384-dot document and a 96-dot narrow document as examples; preserve those values only in this prompt, not in the generic controller.

## `CanvasContentView.swift` (insertion marker retained)

Keep generic SwiftUI canvas hosting and rendering behavior. Restore the marked performance rationale using a representative one-bit raster of 384 by approximately 16,000 dots.

