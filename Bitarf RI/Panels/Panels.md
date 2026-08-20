# Panel reconstruction prompts

## `DocumentSettingsPanel.swift` (insertion markers retained)

Keep the generic title, orientation, margin, dither, threshold, defaults, and settings-form UI. At the marked locations restore hardware presets: 57 millimetres maps to 384 dots and 80 millimetres maps to 576 dots; custom width ranges from 64 through 832 dots in steps of eight; density ranges from one through five and uses the reconstructed adapter's Traditional Chinese names; trailing feed ranges from 0 through 2,000 dots in steps of 20; physical measurement uses 203 dots per inch.

## `TextFormatPanel.swift` (insertion marker retained)

Keep the typography controls and font picker. Restore the marked maximum font-size constraint to 288 dots, described to users as 36 millimetres. This cap is chosen for a roughly 48-millimetre printable strip.

