//
//  LoupeView.swift
//  Bitarf RI
//
//  The first line of defence for precision, and the one that gets built first.
//
//  It solves *occlusion*, not accuracy: a fingertip is about 8 mm across and one
//  dot is 0.125 mm, so the thing you are trying to place is underneath the thing
//  you are placing it with. The loupe puts a magnified copy above the finger.
//  Accuracy itself is the inspector's job.
//

import CoreGraphics
import UIKit

final class LoupeView: UIView {

    static let diameter: CGFloat = 132

    /// Magnification relative to the on-screen canvas, not to dots. 3× makes a
    /// single dot roughly 3 pt across on an iPhone — visible, still honest.
    static let magnification: CGFloat = 3

    private weak var source: CanvasContentView?

    /// Focus point in the source view's coordinate space (points).
    private var focusInSource: CGPoint = .zero

    /// Vertical / horizontal alignment guides to draw through the magnified
    /// region, in canvas dots.
    ///
    /// The one-pager asked for this specifically: the loupe exists because the
    /// finger is covering the thing being placed, and a guide that only appears
    /// underneath the finger would be covered by exactly the same hand.
    private(set) var guideDotsX: [CGFloat] = []
    private(set) var guideDotsY: [CGFloat] = []

    func updateGuides(x: [CGFloat], y: [CGFloat]) {
        guard x != guideDotsX || y != guideDotsY else { return }
        guideDotsX = x
        guideDotsY = y
        // No `setNeedsDisplay` here: guides only ever change during a drag, and
        // `show(focus:in:near:)` is already redrawing on every touch.
    }

    init(source: CanvasContentView) {
        self.source = source
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        alpha = 0
        contentMode = .redraw

        // Clipping happens in `draw` via a circular clip, so the layer can stay
        // unmasked and carry a shadow.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Presentation

    /// - Parameters:
    ///   - focus: the point being manipulated, in the content view's space.
    ///   - container: the view the loupe is a subview of.
    ///   - touch: the finger position, in `container`'s space.
    func show(focus: CGPoint, in container: UIView, near touch: CGPoint) {
        focusInSource = focus
        position(in: container, near: touch)
        setNeedsDisplay()
        guard alpha == 0 else { return }
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
    }

    func hide() {
        guard alpha != 0 else { return }
        UIView.animate(withDuration: 0.12) { self.alpha = 0 }
    }

    /// Sit above the finger, and flip below it when there is no room — the whole
    /// point is to be somewhere the hand is not.
    private func position(in container: UIView, near touch: CGPoint) {
        let gap: CGFloat = 46
        var centre = CGPoint(x: touch.x, y: touch.y - gap - Self.diameter / 2)

        let safeTop = container.safeAreaInsets.top + Self.diameter / 2 + 8
        if centre.y < safeTop {
            centre.y = touch.y + gap + Self.diameter / 2
        }
        centre.x = min(
            max(centre.x, Self.diameter / 2 + 8),
            max(Self.diameter / 2 + 8, container.bounds.width - Self.diameter / 2 - 8)
        )
        center = centre
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let source else { return }

        let circle = bounds.insetBy(dx: 1.5, dy: 1.5)

        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()

        context.setFillColor(UIColor.white.cgColor)
        context.fill(bounds)

        let scale = max(source.displayScale, 0.0001)
        let totalMagnification = scale * Self.magnification
        let visibleDots = Self.diameter / totalMagnification
        let focusDots = CGPoint(x: focusInSource.x / scale, y: focusInSource.y / scale)
        let dotRect = CGRect(
            x: focusDots.x - visibleDots / 2,
            y: focusDots.y - visibleDots / 2,
            width: visibleDots,
            height: visibleDots
        )

        source.drawRegion(dotRect, into: context, magnification: totalMagnification)
        drawGuides(dotRect: dotRect, magnification: totalMagnification, in: context)

        context.restoreGState()

        drawCrosshair(in: context)

        context.setStrokeColor(UIColor.systemBackground.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: circle)
        context.setStrokeColor(UIColor.separator.cgColor)
        context.setLineWidth(0.5)
        context.strokeEllipse(in: bounds.insetBy(dx: 0.25, dy: 0.25))
    }

    private func drawGuides(dotRect: CGRect, magnification: CGFloat, in context: CGContext) {
        guard !guideDotsX.isEmpty || !guideDotsY.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.beginPath()
        for x in guideDotsX {
            let viewX = (x - dotRect.minX) * magnification
            context.move(to: CGPoint(x: viewX, y: 0))
            context.addLine(to: CGPoint(x: viewX, y: bounds.height))
        }
        for y in guideDotsY {
            let viewY = (y - dotRect.minY) * magnification
            context.move(to: CGPoint(x: 0, y: viewY))
            context.addLine(to: CGPoint(x: bounds.width, y: viewY))
        }
        context.strokePath()
    }

    private func drawCrosshair(in context: CGContext) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 11

        context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.beginPath()
        context.move(to: CGPoint(x: centre.x - arm, y: centre.y))
        context.addLine(to: CGPoint(x: centre.x - 3, y: centre.y))
        context.move(to: CGPoint(x: centre.x + 3, y: centre.y))
        context.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
        context.move(to: CGPoint(x: centre.x, y: centre.y - arm))
        context.addLine(to: CGPoint(x: centre.x, y: centre.y - 3))
        context.move(to: CGPoint(x: centre.x, y: centre.y + 3))
        context.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
        context.strokePath()
    }
}
