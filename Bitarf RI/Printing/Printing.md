# Printing reconstruction prompts

These prompts cover only files that originally lived directly in `Bitarf RI/Printing/`.

## `PrinterService.swift` (insertion markers retained)

Preserve the generic CoreBluetooth lifecycle, scan/connect state, remembered-device flow, GATT discovery, write machinery, diagnostics, and Traditional Chinese status UI. At the marked integration boundary, restore the classic-model adapter with these observed facts:

- Rank the Microchip/ISSC transparent UART service whose UUID is `49535343-FE7D-4AE5-8FA9-9FAFD205E455` and vendor service `FF00`, while excluding generic services `1800`, `1801`, `180A`, and `180F` from print-channel selection.
- Recognize advertising prefixes plus the vendor prefix supplied by the reconstructed adapter. Match prefixes, never an arbitrary substring containing the classic model token.
- Use an eight-second acknowledged-write timeout.
- The measured-safe default is 100 raster rows per second. The classic model prints cleanly there but drops rows at 120. Offer 60 through 320 rows per second in steps of 10. Prefill 16 KiB before pacing (approximately four centimetres) and poll status every two seconds.
- Start with the power-on CRC key, negotiate the session key, and fall back appropriately when parsing responses around the handshake.
- Build framed print jobs and support feed, self-test, and status queries through the reconstructed protocol layer.
- The classic model replies to queries twice: the echo of the request is acknowledgement only; only the dedicated reply command contains the value. Accept battery values only from 1 through 100. Treat status zero as normal and nonzero as an uninterpreted mechanical-fault code. Read density from the first byte. Decode a three-byte version least-significant component first, so 07 02 01 displays as 1.2.7, with printable ASCII as a fallback.
- Prefer a known non-system service, then a service containing both writable and notifying characteristics, then any writable characteristic. Prefer write-without-response unless the compatibility switch requests acknowledged writes.

## `PrintView.swift` (insertion markers retained)

Keep the generic print sheet, raster preview, dither selection, progress, cancellation, and visual styling. At the marked sections restore: a measured BLE estimate of 2,500 bytes per second; protocol density labels for levels one through five; trailing-feed UI from 0 through 600 dots in steps of 20; acknowledged-write compatibility mode; the stream-rate slider and duration estimate using the reconstructed pacer and 16 KiB prefill; and framed-job byte counting. The common 384-dot roll is 384 points wide in the one-to-one preview.

## `PrinterConfigurationView.swift` (insertion markers retained)

Keep generic device discovery, connection status, remembered devices, signal display, and disconnect UI. At the marked locations restore classic-model troubleshooting for a stale CRC key, fields for firmware, battery, raw factory heat density and streaming support, plus protocol-backed self-test, feed, status query, raw response trace, and diagnostics. All user-facing text remains Traditional Chinese.

## `ExportService.swift` (insertion marker retained)

Keep generic PNG, PDF, and print-raster export. At the marked PDF sizing calculation, restore the physical scale: one dot occupies 72 divided by 203 PDF points because the hardware resolution is 203 dots per inch.

