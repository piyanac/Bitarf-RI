//
//  PrintRasterizer.swift
//  Bitarf RI
//
//  The one place the editor's vector world becomes dots. It draws through
//  `CanvasRenderer`, the same routine the screen uses, so "what you see" and
//  "what burns" cannot drift apart.
//

import CoreGraphics
import Foundation

public struct PrintRasterResult: Sendable {

    /// Head-space raster: `width` is always the document's fixed axis.
    public let bitmap: Bitmap1Bit

    /// Pre-dither grayscale in the same orientation as `bitmap`, for the
    /// side-by-side "before" pane on the preview screen.
    public let gray: GrayBuffer

    public let lengthDots: Int

    public var lengthDescription: String {
        CanvasMetrics.lengthDescription(dots: CGFloat(lengthDots))
    }

    public init(bitmap: Bitmap1Bit, gray: GrayBuffer, lengthDots: Int) {
        self.bitmap = bitmap
        self.gray = gray
        self.lengthDots = lengthDots
    }
}

public enum PrintRasterizer {

    /// A runaway document (a stray object parked at y = 10 million) must not be
    /// allowed to ask CoreGraphics for a gigabyte of backing store.
    public static let maximumGrowingAxisDots = 100_000

    /// Render `document` to a 1-bit raster ready for the print head.
    public static func rasterize(
        document: BitarfDocument,
        algorithm: DitherAlgorithm? = nil,
        threshold: UInt8? = nil,
        trimTrailingBlank: Bool = true
    ) -> PrintRasterResult {
        let canvasGray = rasterizeGray(document: document)
        let landscape = !document.orientation.isPortrait
        let cut = threshold ?? document.threshold

        // Draw in canvas space, then turn the strip so the fixed axis lands on
        // the head. The gray preview is turned with it so the two panes agree.
        let headGray = landscape ? rotatedGray90Clockwise(canvasGray) : canvasGray

        var bitmap = Dither.apply(
            algorithm ?? document.dither,
            to: canvasGray,
            threshold: cut
        )
        // An explicit `algorithm` means the caller is forcing one pass over the
        // whole strip (a comparison preview); per-image overrides are a property
        // of the document and only apply when it is the document being printed.
        if algorithm == nil {
            applyImageOverrides(
                document: document.reflowed,
                gray: canvasGray,
                threshold: cut,
                into: &bitmap
            )
        }
        if landscape {
            bitmap = bitmap.rotated90Clockwise()
        }
        if trimTrailingBlank {
            bitmap = bitmap.trimmingTrailingBlankRows()
        }

        return PrintRasterResult(bitmap: bitmap, gray: headGray, lengthDots: bitmap.height)
    }

    /// Grayscale-only pass, in canvas space (not rotated), for the preview
    /// screen's "before" image and for anything that wants the raw render.
    public static func rasterizeGray(document: BitarfDocument) -> GrayBuffer {
        let reflowed = document.reflowed
        let size = reflowed.canvasSize
        let width = clampedDots(size.width)
        let height = clampedDots(size.height)
        guard width > 0, height > 0 else { return GrayBuffer(width: 0, height: 0) }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return GrayBuffer(width: width, height: height, fill: 255)
        }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // `CanvasRenderer` works in a top-left origin, y-down space; a bitmap
        // context is bottom-left, y-up. Flip once here for the whole canvas.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        CanvasRenderer.draw(document: reflowed, in: context, options: .print)

        guard let data = context.data else {
            return GrayBuffer(width: width, height: height, fill: 255)
        }

        let sourceBytesPerRow = context.bytesPerRow
        var pixels = [UInt8](repeating: 255, count: width * height)
        let source = data.bindMemory(to: UInt8.self, capacity: sourceBytesPerRow * height)
        pixels.withUnsafeMutableBufferPointer { destination in
            for y in 0..<height {
                let sourceRow = y * sourceBytesPerRow
                let destinationRow = y * width
                for x in 0..<width {
                    destination[destinationRow + x] = source[sourceRow + x]
                }
            }
        }
        return GrayBuffer(width: width, height: height, pixels: pixels)
    }

    // MARK: Per-image overrides

    /// Re-dither the area under each image that asked for its own algorithm, and
    /// stamp the result over the document-wide pass.
    ///
    /// Done as a second pass over the *rendered* gray rather than by dithering
    /// the source image separately, so an override still sees the image exactly
    /// as it was scaled, rotated and tone-corrected onto the canvas — there is
    /// only ever one rasterisation of the artwork.
    ///
    /// The patch is the object's axis-aligned bounding box, which for a rotated
    /// image takes its corners' surroundings with it. That is the honest trade:
    /// a per-pixel mask would let error diffusion run over a jagged boundary,
    /// and the seam that produces is more visible than the corner.
    private static func applyImageOverrides(
        document: BitarfDocument,
        gray: GrayBuffer,
        threshold: UInt8,
        into bitmap: inout Bitmap1Bit
    ) {
        for object in document.objects where !object.isHidden {
            guard case .image(let image) = object.content,
                  let override = image.ditherOverride else { continue }

            let box = object.boundingBox.integral
            let x = max(0, Int(box.minX))
            let y = max(0, Int(box.minY))
            let width = min(gray.width - x, Int(box.width))
            let height = min(gray.height - y, Int(box.height))
            guard width > 0, height > 0 else { continue }

            // Cropped first so error diffusion starts clean at the image edge
            // instead of carrying in the residual of whatever sat beside it.
            let region = gray.cropped(x: x, y: y, width: width, height: height)
            let patch = Dither.apply(override, to: region, threshold: threshold)
            bitmap.blit(patch, atX: x, y: y)
        }
    }

    // MARK: Helpers

    private static func clampedDots(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return min(Int(ceil(value)), maximumGrowingAxisDots)
    }

    private static func rotatedGray90Clockwise(_ buffer: GrayBuffer) -> GrayBuffer {
        guard buffer.width > 0, buffer.height > 0 else {
            return GrayBuffer(width: buffer.height, height: buffer.width)
        }
        let width = buffer.height
        let height = buffer.width
        var pixels = [UInt8](repeating: 255, count: width * height)
        buffer.pixels.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBufferPointer { destination in
                for y in 0..<buffer.height {
                    let destinationX = buffer.height - 1 - y
                    let sourceRow = y * buffer.width
                    for x in 0..<buffer.width {
                        destination[x * width + destinationX] = source[sourceRow + x]
                    }
                }
            }
        }
        return GrayBuffer(width: width, height: height, pixels: pixels)
    }
}
