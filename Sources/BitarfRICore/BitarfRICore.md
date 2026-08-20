# Bitarf RI core reconstruction prompts

These prompts cover only files that originally lived directly in `Sources/BitarfRICore/`.

## Removed vendor-specific protocol source

Create the missing wire-protocol layer for the classic model without changing the generic bitmap, document, or editor APIs. Define command identifiers whose decimal values are 0, 4, 5, 6, 7, 10, 11, 12, 13, 16, 17, 24, 25, 26, 27, 28, 29, 30, 33, 37, 38, 44, and 47, covering raster data, version/model/serial/status/battery queries and replies, CRC-key negotiation, heat density, feed, self-test, power-down time, head positioning, hardware information, paper type, and Bluetooth disconnect.

Implement reflected CRC-32 over the payload. The power-on seed is hexadecimal 35769521. The negotiated seed is hexadecimal 06968634 XOR 002E696D. Use the reflected CRC polynomial hexadecimal EDB88320. A frame begins with hexadecimal 02, then command, packet index, a two-byte little-endian payload length, payload, four-byte little-endian CRC, and hexadecimal 03. Frame overhead is ten bytes and the maximum payload is 2,016 bytes. The CRC-key handshake payload is the new key XOR the power-on key, and the handshake frame itself is signed with the power-on key.

The response parser must resynchronize past junk bytes, retain incomplete frames, reject invalid end markers and CRCs, and report how many bytes were consumed. Text-like replies are null-terminated UTF-8 where applicable.

Build a print job in this order: paper type, density, raster chunks, then feed. The raster chunk budget is 500 bytes rounded down to a whole number of rows; never split a row and keep the packet index at zero. Encode feed distance as an unsigned sixteen-bit little-endian value. Map UI density levels one through five to raw heat values 55, 75, 95, 115, and 135 and to the Traditional Chinese labels 「最低」、「較低」、「預設」、「較高」、「最高」. The classic model's factory density is 95. Use payload zero for self-test and payload one for queries.

## `RasterStreamPacer.swift` (removed)

Recreate the classic-model streaming workaround as a small value type. Derive rows per packet from the protocol's 500-byte, row-aligned chunk size. Send an initial byte prefill without pacing, then calculate every subsequent due time as an absolute offset from the job start using raster rows per second. Do not accumulate per-packet sleeps because their write latency drifts. Also expose a duration estimate using the same formula.

## `CanvasMetrics.swift` (insertion marker retained)

At the marked location, restore the hardware profile constants used by the otherwise generic dot-unit helpers. The classic model is 203 dots per inch, so one dot is 25.4 divided by 203 millimetres. Its roll is 57 millimetres wide, its printable fixed axis is 384 dots (about 48.05 millimetres), and supported fixed-axis values range from 64 through 832 dots. Keep the existing generic millimetre conversion, byte-alignment, and Codable geometry types.

## `BitarfDocument.swift` (insertion markers retained)

At the marked stored-property and initialization locations, restore per-document hardware print settings. Store a density level from one through five and a trailing feed distance in dots. The defaults are density level 3 and 300 trailing dots. The fixed-axis default comes from the reconstructed classic-model hardware profile. Decoding older documents must apply the same fallbacks. Do not change generic document geometry, objects, titles, serialization, or layer operations.

## `Bitmap1Bit.swift` (insertion marker retained)

Keep the generic one-bit bitmap implementation. At its marked integration note, document and enforce the transport representation: one bit per dot, most-significant bit first within each byte, rows padded to whole bytes, and a set bit meaning black/print. The printer transport sends these bytes unchanged and slices them only on row boundaries.

## Generic core files with hardware-derived commentary (insertion markers retained)

In `Dither.swift`, restore the representative memory example of a 384 by 16,000-dot strip. In `CanvasObject.swift`, restore the note that vector content is ultimately sampled by a 203-dots-per-inch head. In `TextModel.swift`, restore the explanatory conversion that a 24-dot glyph is approximately three millimetres tall at 203 dots per inch. Do not alter their generic algorithms.
