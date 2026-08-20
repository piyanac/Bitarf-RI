//
//  Dither.swift
//  Bitarf RI
//
//  A thermal head can only burn a dot or not burn it. Everything between black
//  and white is a lie told by spatial arrangement, and which lie you tell is a
//  visible aesthetic choice — hence the algorithm travels with the document
//  rather than living in a settings screen.
//

import Foundation

public enum DitherAlgorithm: String, Codable, CaseIterable, Hashable, Sendable {
    case threshold
    case floydSteinberg
    case atkinson
    case ordered
    case none

    /// What the menu says. A user picking a dither is choosing what kind of
    /// picture they want out, not naming an algorithm — the algorithm's own name
    /// is still there, one line down in ``shortDescription``, for the people who
    /// came looking for it.
    public var displayName: String {
        switch self {
        case .threshold: return "黑白"
        case .floydSteinberg: return "灰階"
        case .atkinson: return "照片"
        case .ordered: return "印刷"
        case .none: return "原始"
        }
    }

    public var shortDescription: String {
        switch self {
        case .threshold: return "臨界值二值化：純黑白硬切，線條銳利但灰階全部消失。"
        case .floydSteinberg: return "Floyd–Steinberg 誤差擴散：灰階最接近原圖，細節豐富，顆粒略顯雜亂。"
        case .atkinson: return "Atkinson 誤差擴散：對比強、留白乾淨，熱感紙上最不糊，適合照片。"
        case .ordered: return "有序遞色（Bayer 8×8）：規則網點，具印刷感，大面積灰色最平均。"
        case .none: return "不遞色：直接以中間值判斷，適合黑白線稿。"
        }
    }
}

/// 8-bit grayscale buffer, row-major, 0 = black, 255 = white.
public struct GrayBuffer: Sendable {

    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        let w = max(0, width)
        let h = max(0, height)
        self.width = w
        self.height = h
        let expected = w * h
        if pixels.count == expected {
            self.pixels = pixels
        } else if pixels.count > expected {
            self.pixels = Array(pixels[0..<expected])
        } else {
            self.pixels = pixels + [UInt8](repeating: 255, count: expected - pixels.count)
        }
    }

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        let w = max(0, width)
        let h = max(0, height)
        self.width = w
        self.height = h
        self.pixels = [UInt8](repeating: fill, count: w * h)
    }

    /// A rectangular copy, clamped to the buffer. Out-of-bounds area comes back
    /// white rather than being an error: the caller is a render path, and a
    /// slightly-off rectangle should cost a white edge, not a crash.
    public func cropped(x: Int, y: Int, width: Int, height: Int) -> GrayBuffer {
        let w = max(0, width)
        let h = max(0, height)
        guard w > 0, h > 0 else { return GrayBuffer(width: 0, height: 0) }
        var out = GrayBuffer(width: w, height: h, fill: 255)
        pixels.withUnsafeBufferPointer { source in
            out.pixels.withUnsafeMutableBufferPointer { destination in
                for row in 0..<h {
                    let sourceY = y + row
                    guard sourceY >= 0, sourceY < self.height else { continue }
                    let sourceRow = sourceY * self.width
                    let destinationRow = row * w
                    for column in 0..<w {
                        let sourceX = x + column
                        guard sourceX >= 0, sourceX < self.width else { continue }
                        destination[destinationRow + column] = source[sourceRow + sourceX]
                    }
                }
            }
        }
        return out
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return 255 }
            return pixels[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            pixels[y * width + x] = newValue
        }
    }
}

public enum Dither {

    /// Returns a `Bitmap1Bit` where a set bit means BLACK (ink).
    /// `threshold` is 0...255 and only affects `.threshold` and `.none`.
    public static func apply(
        _ algorithm: DitherAlgorithm,
        to buffer: GrayBuffer,
        threshold: UInt8 = 128
    ) -> Bitmap1Bit {
        guard buffer.width > 0, buffer.height > 0 else {
            return Bitmap1Bit(width: buffer.width, height: buffer.height)
        }
        switch algorithm {
        case .threshold, .none:
            return applyThreshold(buffer, threshold: threshold)
        case .ordered:
            return applyOrdered(buffer)
        case .floydSteinberg:
            return applyErrorDiffusion(buffer, kernel: .floydSteinberg)
        case .atkinson:
            return applyErrorDiffusion(buffer, kernel: .atkinson)
        }
    }

    // MARK: Threshold

    private static func applyThreshold(_ buffer: GrayBuffer, threshold: UInt8) -> Bitmap1Bit {
        let width = buffer.width
        let height = buffer.height
        let bytesPerRow = CanvasMetrics.bytesPerRow(fixedAxisDots: width)
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        buffer.pixels.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    let sourceRow = y * width
                    let destinationRow = y * bytesPerRow
                    for x in 0..<width where source[sourceRow + x] < threshold {
                        destination[destinationRow + (x >> 3)] |= 0x80 >> UInt8(x & 7)
                    }
                }
            }
        }
        return Bitmap1Bit(width: width, height: height, bytes: bytes)
    }

    // MARK: Ordered

    /// Bayer 8×8, values 0...63 in the canonical recursive order.
    private static let bayer8: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    private static func applyOrdered(_ buffer: GrayBuffer) -> Bitmap1Bit {
        let width = buffer.width
        let height = buffer.height
        let bytesPerRow = CanvasMetrics.bytesPerRow(fixedAxisDots: width)
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        // Pre-scale the matrix to 0...255 once; the inner loop then costs one
        // compare per dot.
        var levels = [UInt8](repeating: 0, count: 64)
        for index in 0..<64 {
            levels[index] = UInt8((Int(bayer8[index]) * 2 + 1) * 255 / 128)
        }

        buffer.pixels.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { destination in
                levels.withUnsafeBufferPointer { matrix in
                    for y in 0..<height {
                        let sourceRow = y * width
                        let destinationRow = y * bytesPerRow
                        let matrixRow = (y & 7) << 3
                        for x in 0..<width where source[sourceRow + x] < matrix[matrixRow + (x & 7)] {
                            destination[destinationRow + (x >> 3)] |= 0x80 >> UInt8(x & 7)
                        }
                    }
                }
            }
        }
        return Bitmap1Bit(width: width, height: height, bytes: bytes)
    }

    // MARK: Error diffusion

    private enum DiffusionKernel {
        case floydSteinberg
        case atkinson
    }

    private static func applyErrorDiffusion(_ buffer: GrayBuffer, kernel: DiffusionKernel) -> Bitmap1Bit {
        let width = buffer.width
        let height = buffer.height
        let bytesPerRow = CanvasMetrics.bytesPerRow(fixedAxisDots: width)
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        // Three rolling error rows, flattened into one allocation: Atkinson
        // reaches two rows down, Floyd–Steinberg only one. Rolling beats a
        // 此處應插入經典機型尺寸的記憶體案例。A full-image error plane would
        // want 24 MB of Int32 nobody needs.
        let stride = width + 4
        var errors = [Int32](repeating: 0, count: stride * 3)

        buffer.pixels.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { destination in
                errors.withUnsafeMutableBufferPointer { error in
                    var current = 0
                    for y in 0..<height {
                        let next1 = (current + 1) % 3
                        let next2 = (current + 2) % 3
                        let base0 = current * stride
                        let base1 = next1 * stride
                        let base2 = next2 * stride
                        let sourceRow = y * width
                        let destinationRow = y * bytesPerRow

                        for x in 0..<width {
                            // Offset by 2 so x-1 and x+2 never fall off an end.
                            let slot = x + 2
                            var value = Int32(source[sourceRow + x]) + error[base0 + slot]
                            // Runaway error turns a dark edge into a comet trail;
                            // clamping before quantising keeps the tail bounded.
                            if value < 0 { value = 0 }
                            if value > 255 { value = 255 }

                            let isBlack = value < 128
                            if isBlack {
                                destination[destinationRow + (x >> 3)] |= 0x80 >> UInt8(x & 7)
                            }
                            let residual = value - (isBlack ? 0 : 255)

                            switch kernel {
                            case .floydSteinberg:
                                error[base0 + slot + 1] += residual * 7 / 16
                                error[base1 + slot - 1] += residual * 3 / 16
                                error[base1 + slot] += residual * 5 / 16
                                error[base1 + slot + 1] += residual / 16
                            case .atkinson:
                                // Only 6/8 of the error is passed on. Discarding
                                // the remaining quarter is exactly what keeps
                                // thermal output crisp instead of muddy.
                                let eighth = residual / 8
                                error[base0 + slot + 1] += eighth
                                error[base0 + slot + 2] += eighth
                                error[base1 + slot - 1] += eighth
                                error[base1 + slot] += eighth
                                error[base1 + slot + 1] += eighth
                                error[base2 + slot] += eighth
                            }
                        }

                        for index in base0..<(base0 + stride) { error[index] = 0 }
                        current = next1
                    }
                }
            }
        }
        return Bitmap1Bit(width: width, height: height, bytes: bytes)
    }
}
