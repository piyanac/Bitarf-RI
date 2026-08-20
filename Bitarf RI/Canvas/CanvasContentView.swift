//
//  CanvasContentView.swift
//  Bitarf RI
//
//  The paper itself. Draws the document and nothing else — no selection chrome,
//  no handles, no guides beyond the margin. Keeping the chrome in a sibling
//  overlay is what lets the loupe magnify the artwork without magnifying the
//  editor's own furniture.
//
//  The whole strip is one view; UIScrollView only ever asks us to draw the
//  visible rect, and we cull per object against that rect. A two-metre canvas is
//  此處應插入經典機型點陣尺寸的記憶體案例；the cost here is object
//  count, not canvas length.
//

import CoreGraphics
import UIKit

final class CanvasContentView: UIView {

    /// Points per dot. Fixed for the lifetime of a layout pass; the canvas does
    /// not zoom (two-finger gestures belong to the selected object instead).
    var displayScale: CGFloat = 1 {
        didSet { if displayScale != oldValue { setNeedsDisplay() } }
    }

    var document = BitarfDocument() {
        didSet { setNeedsDisplay() }
    }

    /// Suppressed while its glyphs are being drawn by a live `UITextView`,
    /// otherwise the text renders twice and looks bolder than it is.
    var editingObjectID: UUID? {
        didSet { if editingObjectID != oldValue { setNeedsDisplay() } }
    }

    var showsMarginGuide = true {
        didSet { if showsMarginGuide != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Coordinate conversion

    func dotPoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / displayScale, y: viewPoint.y / displayScale)
    }

    func viewPoint(from dotPoint: CGPoint) -> CGPoint {
        CGPoint(x: dotPoint.x * displayScale, y: dotPoint.y * displayScale)
    }

    var canvasViewSize: CGSize {
        CGSize(
            width: document.canvasWidth * displayScale,
            height: document.canvasHeight * displayScale
        )
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)

        context.saveGState()
        context.scaleBy(x: displayScale, y: displayScale)

        let dirtyInDots = CGRect(
            x: rect.minX / displayScale,
            y: rect.minY / displayScale,
            width: rect.width / displayScale,
            height: rect.height / displayScale
        ).insetBy(dx: -2, dy: -2)

        var options = CanvasRenderOptions.editor
        options.drawsBackground = false
        options.showsMarginGuide = false

        if showsMarginGuide, document.margin > 0 {
            drawMarginGuide(in: context)
        }

        for object in document.objects where !object.isHidden {
            if object.id == editingObjectID { continue }
            guard object.boundingBox.insetBy(dx: -4, dy: -4).intersects(dirtyInDots) else { continue }
            CanvasRenderer.draw(object: object, in: context, options: options)
        }

        context.restoreGState()
    }

    private func drawMarginGuide(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        // A hairline at any display scale: the guide is an editor affordance and
        // must not read as content.
        context.setStrokeColor(UIColor.systemGray4.cgColor)
        context.setLineWidth(1 / displayScale)
        context.setLineDash(phase: 0, lengths: [6, 6])
        context.stroke(document.contentRect)
    }

    /// Draw a region of the canvas into an arbitrary context at an arbitrary
    /// magnification. The loupe uses this instead of `layer.render(in:)` so it
    /// never has to rasterise the whole strip to show 40 dots of it.
    func drawRegion(_ dotRect: CGRect, into context: CGContext, magnification: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(
            origin: .zero,
            size: CGSize(width: dotRect.width * magnification, height: dotRect.height * magnification)
        ))

        context.scaleBy(x: magnification, y: magnification)
        context.translateBy(x: -dotRect.minX, y: -dotRect.minY)

        var options = CanvasRenderOptions.editor
        options.drawsBackground = false
        options.showsMarginGuide = false

        for object in document.objects where !object.isHidden {
            guard object.boundingBox.insetBy(dx: -4, dy: -4).intersects(dotRect) else { continue }
            CanvasRenderer.draw(object: object, in: context, options: options)
        }
    }
}
