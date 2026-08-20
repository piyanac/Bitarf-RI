//
//  CanvasRenderer.swift
//  Bitarf RI
//
//  One drawing routine, three consumers: the on-screen canvas, the PNG/PDF
//  export, and the print rasteriser. They must not diverge — a preview that
//  disagrees with the paper is worse than no preview.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO

public struct CanvasRenderOptions {
    /// Draw the paper background. Off for transparent PNG export.
    public var drawsBackground: Bool
    /// Ink colour. Always black on paper; parameterised for on-screen affordances.
    public var inkColor: CGColor
    public var backgroundColor: CGColor
    /// Draw the dotted margin guide. Editor only.
    public var showsMarginGuide: Bool
    /// Draw a placeholder box for empty text so it stays findable.
    public var showsEmptyTextPlaceholder: Bool
    /// Skip this object — the editor hides the object being live-edited in a
    /// text view so the glyphs are not drawn twice.
    public var suppressedObjectID: UUID?

    public init(
        drawsBackground: Bool = true,
        inkColor: CGColor = CanvasRenderOptions.black,
        backgroundColor: CGColor = CanvasRenderOptions.white,
        showsMarginGuide: Bool = false,
        showsEmptyTextPlaceholder: Bool = false,
        suppressedObjectID: UUID? = nil
    ) {
        self.drawsBackground = drawsBackground
        self.inkColor = inkColor
        self.backgroundColor = backgroundColor
        self.showsMarginGuide = showsMarginGuide
        self.showsEmptyTextPlaceholder = showsEmptyTextPlaceholder
        self.suppressedObjectID = suppressedObjectID
    }

    public static let black = CGColor(gray: 0, alpha: 1)
    public static let white = CGColor(gray: 1, alpha: 1)

    /// What the printer sees.
    public static let print = CanvasRenderOptions()

    /// What the editor draws.
    public static let editor = CanvasRenderOptions(
        showsMarginGuide: true,
        showsEmptyTextPlaceholder: true
    )
}

public enum CanvasRenderer {

    /// Editor-only guidance for a text box whose model contains no text.
    /// Keeping the copy here lets the canvas renderer and the live UIKit editor
    /// agree without ever inserting the placeholder into `RichText`.
    public static let emptyTextPlaceholder = "按兩下來編輯"

    /// Draw the whole document into `context`, in canvas dot coordinates with a
    /// top-left origin and y increasing downwards.
    ///
    /// The caller must already have applied any scale it wants; this routine
    /// deals only in dots.
    public static func draw(
        document: BitarfDocument,
        in context: CGContext,
        options: CanvasRenderOptions = .print
    ) {
        let canvas = CGRect(origin: .zero, size: document.canvasSize)

        if options.drawsBackground {
            context.saveGState()
            context.setFillColor(options.backgroundColor)
            context.fill(canvas)
            context.restoreGState()
        }

        if options.showsMarginGuide, document.margin > 0 {
            drawMarginGuide(document: document, in: context)
        }

        for object in document.objects where !object.isHidden {
            if let suppressed = options.suppressedObjectID, suppressed == object.id { continue }
            draw(object: object, in: context, options: options)
        }
    }

    // MARK: - Object dispatch

    public static func draw(
        object: CanvasObject,
        in context: CGContext,
        options: CanvasRenderOptions
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        // Rotate about the centre, then draw the object as if it were upright.
        if object.rotation != 0 {
            let centre = object.center
            context.translateBy(x: centre.x, y: centre.y)
            context.rotate(by: object.rotation)
            context.translateBy(x: -centre.x, y: -centre.y)
        }

        switch object.content {
        case .text(let rich):
            drawText(rich, object: object, in: context, options: options)
        case .shape(let shape):
            drawShape(shape, object: object, in: context, options: options)
        case .image(let image):
            drawImage(image, object: object, in: context)
        case .vector(let vector):
            drawVector(vector, object: object, in: context)
        }
    }

    // MARK: - Text

    private static func drawText(
        _ rich: RichText,
        object: CanvasObject,
        in context: CGContext,
        options: CanvasRenderOptions
    ) {
        if rich.isEmpty {
            guard options.showsEmptyTextPlaceholder else { return }
            let placeholder = NSAttributedString(
                string: emptyTextPlaceholder,
                attributes: rich.typingAttributes(foreground: CGColor(gray: 0.62, alpha: 1))
            )
            TextLayoutEngine.draw(placeholder, in: object.frame, context: context)
            return
        }

        let attributed = rich.attributedString(foreground: options.inkColor)
        TextLayoutEngine.draw(attributed, in: object.frame, context: context)
    }

    // MARK: - Shapes

    private static func drawShape(
        _ shape: ShapeContent,
        object: CanvasObject,
        in context: CGContext,
        options: CanvasRenderOptions
    ) {
        let rect = object.frame
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(options.inkColor)
        context.setStrokeColor(options.inkColor)
        context.setLineWidth(max(shape.strokeWidth, 0))
        context.setLineCap(.butt)
        if !shape.dashPattern.isEmpty {
            context.setLineDash(phase: 0, lengths: shape.dashPattern)
        }

        switch shape.kind {
        case .rectangle:
            let path: CGPath
            if shape.cornerRadius > 0 {
                let radius = min(shape.cornerRadius, min(rect.width, rect.height) / 2)
                path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            } else {
                path = CGPath(rect: rect, transform: nil)
            }
            context.addPath(path)
            context.drawPath(using: shape.filled ? .fill : (shape.strokeWidth > 0 ? .stroke : .fill))

        case .ellipse:
            context.addEllipse(in: rect)
            context.drawPath(using: shape.filled ? .fill : (shape.strokeWidth > 0 ? .stroke : .fill))

        case .line:
            // A line object uses its box as the vector: left edge to right edge
            // at mid-height. Rotating the object is what makes it diagonal, so
            // there is only ever one line geometry to reason about.
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.setLineWidth(max(shape.strokeWidth, 1))
            context.strokePath()
        }
    }

    // MARK: - Images

    private static func drawImage(
        _ image: ImageContent,
        object: CanvasObject,
        in context: CGContext
    ) {
        guard var cgImage = decodeImage(image.pngData) else { return }
        if image.hasToneAdjustment, let adjusted = toneAdjusted(cgImage, content: image) {
            cgImage = adjusted
        }
        let rect = object.frame

        context.saveGState()
        defer { context.restoreGState() }

        // CGContext draws images bottom-up; flip inside the object's own box so
        // the picture is not upside down relative to everything else.
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let drawRect = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height)

        if image.inverted {
            context.saveGState()
            context.clip(to: drawRect, mask: cgImage)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(drawRect)
            context.restoreGState()
            // `clip(to:mask:)` treats the mask as inverse alpha for a grayscale
            // image, which is exactly the negative we want.
        } else {
            context.draw(cgImage, in: drawRect)
        }
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Vector

    /// Draw the artwork's page stretched onto the object's box.
    ///
    /// The page is played back as PDF operators rather than as a pre-rendered
    /// bitmap, so the same object that is a few hundred dots wide on screen is
    /// re-drawn at the head's own resolution when it reaches the rasteriser.
    /// That is the entire point of accepting vector art.
    private static func drawVector(
        _ vector: VectorContent,
        object: CanvasObject,
        in context: CGContext
    ) {
        guard let page = page(for: vector.pdfData) else { return }
        let rect = object.frame
        guard rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Artwork that paints outside its own crop box would otherwise land on
        // neighbouring objects, and the user has no handle to trim it with.
        context.clip(to: rect)

        // PDF space is y-up; the canvas is y-down. Flip inside the object's box
        // so the drawing is not upside down relative to everything else.
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let target = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height)

        // `getDrawingTransform` is what honours a page's own /Rotate entry, so a
        // sideways-saved PDF imports the way its author saw it.
        context.concatenate(
            page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: false)
        )
        context.drawPDFPage(page)
    }

    /// Parsed first pages, so dragging an object does not re-parse the PDF on
    /// every frame. Bounded by count for the same reason as `toneCache`.
    private static let pageCache: NSCache<NSString, CGPDFPageBox> = {
        let cache = NSCache<NSString, CGPDFPageBox>()
        cache.countLimit = 16
        return cache
    }()

    /// `CGPDFPage` is a CoreFoundation type that `NSCache` will not take
    /// directly on all platforms, so it travels in a box.
    final class CGPDFPageBox {
        let page: CGPDFPage
        init(_ page: CGPDFPage) { self.page = page }
    }

    static func page(for data: Data) -> CGPDFPage? {
        let key = "\(data.count)|\(data.hashValue)" as NSString
        if let cached = pageCache.object(forKey: key) { return cached.page }
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages >= 1,
              let page = document.page(at: 1) else { return nil }
        pageCache.setObject(CGPDFPageBox(page), forKey: key)
        return page
    }

    /// Size of the first page's crop box in PDF points, with the page's own
    /// rotation applied. This is the aspect ratio the importer lays the object
    /// out at, so it has to agree with what `drawVector` will produce.
    public static func vectorPageSize(of data: Data) -> CGSize? {
        guard let page = page(for: data) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360
        if quarterTurns == 90 || quarterTurns == 270 {
            return CGSize(width: box.height, height: box.width)
        }
        return box.size
    }

    // MARK: - Tone

    /// Redrawn copies of tone-adjusted images, so dragging an object does not
    /// re-run the correction on every frame. Bounded by count because the images
    /// are already downsampled at import; a handful is all a 48 mm strip holds.
    private static let toneCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 16
        return cache
    }()

    /// Grayscale copy of `image` with brightness and contrast applied.
    ///
    /// Deliberately a pixel pass rather than a Core Image filter: this runs
    /// inside the print rasteriser too, and the whole point of the pipeline is
    /// that the dots are ours to account for.
    private static func toneAdjusted(_ image: CGImage, content: ImageContent) -> CGImage? {
        let key = "\(content.pngData.hashValue)|\(content.brightness)|\(content.contrast)" as NSString
        if let cached = toneCache.object(forKey: key) { return cached }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // White ground, so any transparency in the source reads as paper rather
        // than as a black block once it hits the head.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        let table = toneTable(brightness: content.brightness, contrast: content.contrast)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        table.withUnsafeBufferPointer { lookup in
            for index in 0..<(width * height) {
                pixels[index] = lookup[Int(pixels[index])]
            }
        }

        guard let result = context.makeImage() else { return nil }
        toneCache.setObject(result, forKey: key)
        return result
    }

    /// 256-entry lookup: contrast first about mid-gray, then brightness.
    ///
    /// Contrast leads because stretching an already-shifted image clips the
    /// highlights it just created, which on paper looks like the picture lost
    /// its whites for no reason the user did anything to cause.
    static func toneTable(brightness: Double, contrast: Double) -> [UInt8] {
        let shift = min(max(brightness, -1), 1) * 255
        let amount = min(max(contrast, -1), 1)
        // -1 flattens to a uniform mid-gray, +1 approaches a hard cut at 128.
        let slope = amount >= 0 ? 1 / max(0.02, 1 - amount) : 1 + amount
        return (0...255).map { level in
            let stretched = (Double(level) - 128) * slope + 128 + shift
            return UInt8(min(max(stretched, 0), 255))
        }
    }

    // MARK: - Guides

    private static func drawMarginGuide(document: BitarfDocument, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [6, 6])
        context.stroke(document.contentRect)
    }
}
