//
//  VectorImportService.swift
//  Bitarf RI
//
//  Turning a file the user picked into a `VectorContent`.
//
//  Both accepted formats end up as a one-page PDF, because CoreGraphics can
//  replay a PDF page into any context at any scale — which is what lets a vector
//  object stay sharp until output rasterisation.
//  此處應插入經典機型的輸出解析度說明，而非在匯入時凍結像素。
//  frozen into pixels here at import time.
//
//  iOS has no PDF-quality SVG renderer, so an SVG is laid out once in an
//  offscreen WKWebView and printed to PDF. That is a real dependency on WebKit's
//  SVG support, but it is the only route that keeps the artwork vector; the
//  alternative — snapshotting to a bitmap — would throw away the whole reason to
//  accept SVG in the first place.
//

import CoreGraphics
import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

enum VectorImportError: LocalizedError {
    case unreadable
    case unsupportedType
    case tooLarge
    case notAVectorPage
    case svgConversionFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "載入失敗"
        case .unsupportedType: return "不支援的檔案類型。"
        case .tooLarge: return "檔案太大。向量上限 \(VectorImportService.maximumBytes / 1_000_000) MB。"
        case .notAVectorPage: return "這個 PDF 檔案沒有可用的頁面"
        case .svgConversionFailed: return "繪製 SVG 失敗"
        }
    }
}

enum VectorImportService {

    /// Ceiling on the stored PDF. The document is JSON with the bytes inlined
    /// and it is rewritten on every autosave, so a fat file is paid for over and
    /// over — and nothing a 48 mm strip prints needs megabytes of paths.
    static let maximumBytes = 10_000_000

    /// Read `url` and produce artwork ready to drop on the canvas.
    ///
    /// The URL comes from `fileImporter`, so it is security-scoped and has to be
    /// opened before it can be read.
    @MainActor
    static func load(from url: URL) async throws -> VectorContent {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw VectorImportError.unreadable }
        let name = url.deletingPathExtension().lastPathComponent

        switch kind(of: url, data: data) {
        case .pdf:
            guard data.count <= maximumBytes else { throw VectorImportError.tooLarge }
            guard let size = CanvasRenderer.vectorPageSize(of: data) else {
                throw VectorImportError.notAVectorPage
            }
            return VectorContent(
                pdfData: data,
                intrinsicSize: DotSize(size),
                sourceKind: .pdf,
                sourceName: name
            )

        case .svg:
            let pdf = try await pdfData(fromSVG: data)
            guard pdf.count <= maximumBytes else { throw VectorImportError.tooLarge }
            guard let size = CanvasRenderer.vectorPageSize(of: pdf) else {
                throw VectorImportError.svgConversionFailed
            }
            return VectorContent(
                pdfData: pdf,
                intrinsicSize: DotSize(size),
                sourceKind: .svg,
                sourceName: name
            )

        case nil:
            throw VectorImportError.unsupportedType
        }
    }

    // MARK: - Format sniffing

    /// The extension is what the user chose with, but a file provider can hand
    /// back an extensionless copy, so the bytes get the final say.
    private static func kind(of url: URL, data: Data) -> VectorSourceKind? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "svg", "svgz": return .svg
        default: break
        }
        if data.starts(with: Array("%PDF".utf8)) { return .pdf }
        if let head = String(data: data.prefix(1024), encoding: .utf8), head.contains("<svg") {
            return .svg
        }
        return nil
    }

    // MARK: - SVG → PDF

    @MainActor
    private static func pdfData(fromSVG data: Data) async throws -> Data {
        guard let source = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw VectorImportError.svgConversionFailed
        }
        let size = layoutSize(forSVG: source)

        let configuration = WKWebViewConfiguration()
        // The file came from outside the app and SVG can carry script. Nothing
        // here needs JavaScript, and the page is loaded with no base URL, so it
        // has neither code nor a way to reach the file system.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        // WebKit will not lay out a view that belongs to no window, and an
        // unlaid-out page prints blank. Zero alpha keeps it invisible while it
        // is technically on screen.
        webView.alpha = 0
        let host = Self.hostWindow()
        host?.addSubview(webView)
        host?.sendSubviewToBack(webView)
        defer { webView.removeFromSuperview() }

        let delegate = LoadObserver()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html(wrapping: source, size: size), baseURL: nil)
        try await delegate.waitForLoad()

        let configurationPDF = WKPDFConfiguration()
        configurationPDF.rect = CGRect(origin: .zero, size: size)
        guard let pdf = try? await webView.pdf(configuration: configurationPDF) else {
            throw VectorImportError.svgConversionFailed
        }
        return pdf
    }

    private static func hostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    /// Margin-free page holding exactly one SVG at the size we measured.
    ///
    /// The CSS rule beats whatever `width`/`height` the file declares, so the
    /// printed page is the drawing and nothing else.
    private static func html(wrapping svg: String, size: CGSize) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        svg { display: block; width: \(size.width)px; height: \(size.height)px; }
        </style></head><body>\(svg)</body></html>
        """
    }

    // MARK: - SVG measuring

    /// Point size to lay the drawing out at.
    ///
    /// Only the *ratio* survives into the document — the object is scaled to the
    /// canvas on insert — so this needs to be proportionally right, not
    /// physically right. `viewBox` leads because `width`/`height` are routinely
    /// percentages or absent in exported files.
    private static func layoutSize(forSVG source: String) -> CGSize {
        let fallback = CGSize(width: 512, height: 512)
        guard let tag = openingSVGTag(in: source) else { return fallback }

        var size = fallback
        if let box = attribute("viewBox", in: tag) {
            let numbers = box
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 {
                size = CGSize(width: numbers[2], height: numbers[3])
            }
        } else if let width = attribute("width", in: tag).flatMap(length),
                  let height = attribute("height", in: tag).flatMap(length),
                  width > 0, height > 0 {
            size = CGSize(width: width, height: height)
        }

        // A huge web view costs memory for no gain: the ratio is all we keep.
        let longest = max(size.width, size.height)
        if longest > 2000 {
            let scale = 2000 / longest
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }

    private static func openingSVGTag(in source: String) -> Substring? {
        guard let start = source.range(of: "<svg", options: .caseInsensitive),
              let end = source[start.upperBound...].firstIndex(of: ">") else { return nil }
        return source[start.lowerBound...end]
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        for quote in ["\"", "'"] {
            let needle = "\(name)=\(quote)"
            guard let start = tag.range(of: needle, options: .caseInsensitive),
                  let end = tag[start.upperBound...].range(of: quote) else { continue }
            return String(tag[start.upperBound..<end.lowerBound])
        }
        return nil
    }

    /// A CSS length in px. Percentages return nil — they say nothing about the
    /// drawing's proportions.
    private static func length(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [
            ("px", 1), ("pt", 96.0 / 72), ("pc", 16), ("mm", 96.0 / 25.4),
            ("cm", 96.0 / 2.54), ("in", 96), ("em", 16), ("rem", 16),
        ]
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)) else { return nil }
            return value * factor
        }
        return Double(trimmed)
    }

    // MARK: - Load gate

    /// Bridges `didFinish` / `didFail` into one `await`.
    private final class LoadObserver: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var settled = false

        func waitForLoad() async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
            // Loading finished is not the same as laid out; one turn of the
            // run loop is what keeps a freshly parsed SVG from printing blank.
            try? await Task.sleep(for: .milliseconds(80))
        }

        private func settle(_ result: Result<Void, Error>) {
            guard !settled else { return }
            settled = true
            continuation?.resume(with: result)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            settle(.success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            settle(.failure(VectorImportError.svgConversionFailed))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            settle(.failure(VectorImportError.svgConversionFailed))
        }
    }
}
