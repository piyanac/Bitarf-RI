//
//  Bitmap1Bit.swift
//  Bitarf RI
//
//  Generic one-bit raster storage and image conversion.
//
//  此處應插入經典機型的位元順序、黑白語意、列對齊與 wire 傳輸整合說明。
//

import CoreGraphics
import Foundation
import ImageIO

/// One-bit bitmap. Transport-specific representation is intentionally omitted.
public struct Bitmap1Bit: Hashable, Sendable {

    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public private(set) var bytes: [UInt8]

    public init(width: Int, height: Int) {
        let w = max(0, width)
        let h = max(0, height)
        self.width = w
        self.height = h
        self.bytesPerRow = CanvasMetrics.bytesPerRow(fixedAxisDots: w)
        self.bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
    }

    /// Adopt an existing buffer. A wrong-sized buffer is padded or truncated
    /// rather than trapping — a malformed document should not crash the printer
    /// path, it should print something obviously wrong.
    public init(width: Int, height: Int, bytes: [UInt8]) {
        let w = max(0, width)
        let h = max(0, height)
        self.width = w
        self.height = h
        self.bytesPerRow = CanvasMetrics.bytesPerRow(fixedAxisDots: w)
        let expected = self.bytesPerRow * h
        if bytes.count == expected {
            self.bytes = bytes
        } else if bytes.count > expected {
            self.bytes = Array(bytes[0..<expected])
        } else {
            self.bytes = bytes + [UInt8](repeating: 0, count: expected - bytes.count)
        }
    }

    // MARK: Pixels

    public subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return bytes[y * bytesPerRow + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0
        }
        set { setPixel(x, y, black: newValue) }
    }

    public mutating func setPixel(_ x: Int, _ y: Int, black: Bool) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let index = y * bytesPerRow + (x >> 3)
        let mask: UInt8 = 0x80 >> UInt8(x & 7)
        if black {
            bytes[index] |= mask
        } else {
            bytes[index] &= ~mask
        }
    }

    /// Overwrite the rectangle at (`x`, `y`) with `patch`, replacing whatever is
    /// there rather than OR-ing into it.
    ///
    /// Replacing is the point: this is how a region dithered under its own
    /// algorithm displaces the document-wide pass, and OR-ing would leave the
    /// document's dots showing through as grit.
    public mutating func blit(_ patch: Bitmap1Bit, atX x: Int, y: Int) {
        guard patch.width > 0, patch.height > 0 else { return }
        for row in 0..<patch.height {
            let destinationY = y + row
            guard destinationY >= 0, destinationY < height else { continue }
            for column in 0..<patch.width {
                setPixel(x + column, destinationY, black: patch[column, row])
            }
        }
    }

    public func row(_ y: Int) -> ArraySlice<UInt8> {
        guard y >= 0, y < height else { return ArraySlice<UInt8>() }
        let start = y * bytesPerRow
        return bytes[start..<(start + bytesPerRow)]
    }

    // MARK: Trimming

    /// Number of rows at the end that are entirely white.
    public var trailingBlankRows: Int {
        guard height > 0, bytesPerRow > 0 else { return 0 }
        var blank = 0
        var y = height - 1
        while y >= 0 {
            let start = y * bytesPerRow
            var isBlank = true
            for index in start..<(start + bytesPerRow) where bytes[index] != 0 {
                isBlank = false
                break
            }
            if !isBlank { break }
            blank += 1
            y -= 1
        }
        return blank
    }

    public func trimmingTrailingBlankRows() -> Bitmap1Bit {
        let blank = trailingBlankRows
        guard blank > 0 else { return self }
        let keep = height - blank
        return Bitmap1Bit(
            width: width,
            height: keep,
            bytes: Array(bytes[0..<(keep * bytesPerRow)])
        )
    }

    // MARK: Rotation

    /// Rotate 90° clockwise. Needed for landscape documents, whose growing axis
    /// is horizontal but whose print head is not.
    public func rotated90Clockwise() -> Bitmap1Bit {
        guard width > 0, height > 0 else { return Bitmap1Bit(width: height, height: width) }
        var result = Bitmap1Bit(width: height, height: width)
        for y in 0..<height {
            let destinationX = height - 1 - y
            for x in 0..<width where self[x, y] {
                result.setPixel(destinationX, x, black: true)
            }
        }
        return result
    }

    // MARK: Preview

    /// Expand to 8-bit gray so ImageIO and the screen have something to chew on.
    private func grayscaleBytes() -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height)
        out.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                let outStart = y * width
                for x in 0..<width {
                    let bit = bytes[rowStart + (x >> 3)] & (0x80 >> UInt8(x & 7))
                    buffer[outStart + x] = bit != 0 ? 0 : 255
                }
            }
        }
        return out
    }

    /// A CGImage for on-screen preview.
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let gray = grayscaleBytes()
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// PNG data for previewing and for "share the strip" export.
    public func pngData() -> Data? {
        guard let image = makeCGImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
