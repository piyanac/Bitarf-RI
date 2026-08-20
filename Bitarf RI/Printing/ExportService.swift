//
//  ExportService.swift
//  Bitarf RI
//
//  Everything that leaves the app as a file. All three formats go through
//  `CanvasRenderer` so an exported PNG, an exported PDF and the paper can never
//  disagree about what the document looks like.
//

import CoreGraphics
import Foundation
import UIKit

enum ExportService {

    // MARK: - Geometry

    // 此處應插入經典機型解析度對應的 PDF points-per-dot 實體縮放值。

    // MARK: - Raster

    /// Bitmap export at `scale` device pixels per dot. `transparent` drops the
    /// paper background so the artwork can be composited elsewhere.
    static func pngData(document: BitarfDocument, scale: CGFloat = 1, transparent: Bool = false) -> Data? {
        renderImage(document: document, scale: scale, transparent: transparent)?.pngData()
    }

    static func previewImage(document: BitarfDocument, scale: CGFloat) -> UIImage? {
        renderImage(document: document, scale: scale, transparent: false)
    }

    private static func renderImage(document: BitarfDocument, scale: CGFloat, transparent: Bool) -> UIImage? {
        let source = document.reflowed
        let size = source.canvasSize
        guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = max(0.1, scale)
        format.opaque = !transparent
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            // A UIKit renderer context is already top-left origin, y-down —
            // exactly the space `CanvasRenderer` documents. No flip here; the
            // renderer applies its own per-object flips for text and images.
            var options = CanvasRenderOptions.print
            options.drawsBackground = !transparent
            CanvasRenderer.draw(document: source, in: rendererContext.cgContext, options: options)
        }
    }

    // MARK: - Vector

    /// Vector PDF, one page, sized using the reconstructed hardware scale.
    static func pdfData(document: BitarfDocument) -> Data? {
        let source = document.reflowed
        let dotSize = source.canvasSize
        guard dotSize.width >= 1, dotSize.height >= 1, dotSize.width.isFinite, dotSize.height.isFinite else { return nil }

        let pageSize = CGSize(
            width: dotSize.width * pointsPerDot,
            height: dotSize.height * pointsPerDot
        )
        let bounds = CGRect(origin: .zero, size: pageSize)

        let metadata: [String: Any] = [
            kCGPDFContextTitle as String: source.title,
            kCGPDFContextCreator as String: "Bitarf RI \(AppInfo.versionString)"
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = metadata

        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { rendererContext in
            rendererContext.beginPage()
            let context = rendererContext.cgContext
            // Draw in dots and let the page scale carry the physical size, so
            // the renderer never has to know about points.
            context.saveGState()
            context.scaleBy(x: pointsPerDot, y: pointsPerDot)
            CanvasRenderer.draw(document: source, in: context, options: .print)
            context.restoreGState()
        }
    }

    // MARK: - Print raster

    /// The 1-bit print raster as a PNG, i.e. exactly what the paper will show.
    static func ditheredPNGData(document: BitarfDocument) -> Data? {
        let result = PrintRasterizer.rasterize(document: document.reflowed)
        return result.bitmap.pngData()
    }

    // MARK: - Files

    /// Write to the temp directory and return a share-ready URL.
    static func writeTemporary(_ data: Data, name: String, ext: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory
            .appendingPathComponent(sanitized(name))
            .appendingPathExtension(ext)
        // Overwrite rather than uniquify: repeated exports of the same document
        // should not pile up a dozen near-identical files in the share sheet.
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Document titles are free text and go straight into a file name.
    private static func sanitized(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : String(cleaned.prefix(60))
    }
}
