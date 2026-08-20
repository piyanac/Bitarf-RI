//
//  CanvasSelectionOverlayView.swift
//  Bitarf RI
//
//  Selection chrome, drawn in *point* space so handles stay a fingertip's size
//  no matter what the dot-to-point scale is. Non-interactive: the gesture
//  recognisers live on the scroll view's content, and this view only ever
//  reports where its handles are.
//

import CoreGraphics
import UIKit

enum CanvasHandle: CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft, rotate
}

final class CanvasSelectionOverlayView: UIView {

    /// Corners of the selected object in view (point) space, clockwise from
    /// top-left, already rotated. Empty unless exactly one object is selected.
    private(set) var selectionCorners: [CGPoint] = []

    var isLocked = false

    /// One quad per member of a multi-selection, and the axis-aligned box around
    /// all of them. Both empty unless two or more objects are selected.
    ///
    /// The union is drawn as well as the members because it is what the group
    /// operations act on: the rotation turns about its centre, and 對齊 measures
    /// against its edges. Showing only the members would leave every one of
    /// those operations referring to a rectangle the user cannot see.
    private(set) var objectQuads: [(corners: [CGPoint], locked: Bool)] = []
    private(set) var unionCorners: [CGPoint] = []

    private var hasMultipleSelection: Bool { unionCorners.count == 4 }

    /// Alignment lines to draw, in this view's own (point) space. Vertical lines
    /// are x positions, horizontal ones y.
    ///
    /// They live here rather than on the content view for the same reason the
    /// handles do: the loupe magnifies the content view, and magnifying the
    /// editor's own furniture along with the artwork would make the guide read
    /// as a three-dot-wide rule that is about to be printed.
    private(set) var guidesX: [CGFloat] = []
    private(set) var guidesY: [CGFloat] = []

    /// Hit radius for a handle. Larger than the drawn dot because the drawn dot
    /// is a target, not a button.
    static let handleHitRadius: CGFloat = 22
    static let handleDrawRadius: CGFloat = 7
    static let rotateHandleOffset: CGFloat = 40

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - State

    func update(corners: [CGPoint], locked: Bool) {
        selectionCorners = corners
        isLocked = locked
        objectQuads = []
        unionCorners = []
        setNeedsDisplay()
    }

    func updateSelectionSet(quads: [(corners: [CGPoint], locked: Bool)], union: [CGPoint]) {
        selectionCorners = []
        isLocked = false
        objectQuads = quads
        unionCorners = union
        setNeedsDisplay()
    }

    func clearSelection() {
        selectionCorners = []
        objectQuads = []
        unionCorners = []
        setNeedsDisplay()
    }

    func updateGuides(x: [CGFloat], y: [CGFloat]) {
        guard x != guidesX || y != guidesY else { return }
        guidesX = x
        guidesY = y
        setNeedsDisplay()
    }

    func clearGuides() {
        updateGuides(x: [], y: [])
    }

    // MARK: - Handle geometry

    func handlePosition(_ handle: CanvasHandle) -> CGPoint? {
        // A multi-selection offers the rotation handle and nothing else. Scaling
        // a set is not implemented, and a corner handle that did nothing would
        // be a worse answer than no handle at all.
        if hasMultipleSelection {
            guard handle == .rotate else { return nil }
            return rotateHandlePosition(above: unionCorners)
        }
        guard selectionCorners.count == 4 else { return nil }
        switch handle {
        case .topLeft: return selectionCorners[0]
        case .topRight: return selectionCorners[1]
        case .bottomRight: return selectionCorners[2]
        case .bottomLeft: return selectionCorners[3]
        case .rotate:
            return rotateHandlePosition(above: selectionCorners)
        }
    }

    private func rotateHandlePosition(above corners: [CGPoint]) -> CGPoint? {
        guard corners.count == 4 else { return nil }
        let topMid = midpoint(corners[0], corners[1])
        let bottomMid = midpoint(corners[3], corners[2])
        var up = CGPoint(x: topMid.x - bottomMid.x, y: topMid.y - bottomMid.y)
        let length = max(sqrt(up.x * up.x + up.y * up.y), 0.0001)
        up = CGPoint(x: up.x / length, y: up.y / length)
        return CGPoint(
            x: topMid.x + up.x * Self.rotateHandleOffset,
            y: topMid.y + up.y * Self.rotateHandleOffset
        )
    }

    /// Nearest handle within the hit radius, or nil.
    func handle(at point: CGPoint) -> CanvasHandle? {
        guard !isLocked, hasMultipleSelection || selectionCorners.count == 4 else { return nil }
        var best: (handle: CanvasHandle, distance: CGFloat)?
        for handle in CanvasHandle.allCases {
            guard let position = handlePosition(handle) else { continue }
            let distance = hypot(position.x - point.x, position.y - point.y)
            guard distance <= Self.handleHitRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (handle, distance)
            }
        }
        return best?.handle
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // Guides first, so the selection outline and its handles stay readable
        // where a line runs straight through them.
        drawGuides(in: context, clippedTo: rect)

        if hasMultipleSelection {
            drawSelectionSet(in: context)
            return
        }

        guard selectionCorners.count == 4 else { return }

        // Pinned to the light appearance: this chrome is drawn over the page,
        // which is white whatever the app's appearance is, so the dark variants
        // of these colours would be washing out against paper rather than
        // sitting on a dark background.
        let tint = isLocked ? Self.lockedTint : Self.activeTint

        context.setStrokeColor(tint.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.beginPath()
        context.move(to: selectionCorners[0])
        for corner in selectionCorners.dropFirst() {
            context.addLine(to: corner)
        }
        context.closePath()
        context.strokePath()

        guard !isLocked else { return }

        // Rotation handle first, so its stalk sits under the corner dots.
        if let rotateHandle = handlePosition(.rotate) {
            let topMid = midpoint(selectionCorners[0], selectionCorners[1])
            context.setStrokeColor(tint.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            context.beginPath()
            context.move(to: topMid)
            context.addLine(to: rotateHandle)
            context.strokePath()
            drawHandle(at: rotateHandle, in: context, tint: tint, hollow: true)
        }

        for handle in [CanvasHandle.topLeft, .topRight, .bottomRight, .bottomLeft] {
            guard let position = handlePosition(handle) else { continue }
            drawHandle(at: position, in: context, tint: tint, hollow: false)
        }
    }

    private func drawSelectionSet(in context: CGContext) {
        // Members hairline and dimmed, the union solid on top. The eye should
        // read one thing being held with its parts marked, not N outlines
        // competing with each other.
        for quad in objectQuads where quad.corners.count == 4 {
            let tint = quad.locked ? Self.lockedTint : Self.activeTint
            context.setStrokeColor(tint.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1)
            stroke(quad.corners, in: context)
        }

        context.setStrokeColor(Self.activeTint.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        stroke(unionCorners, in: context)

        guard let rotateHandle = handlePosition(.rotate) else { return }
        let topMid = midpoint(unionCorners[0], unionCorners[1])
        context.beginPath()
        context.move(to: topMid)
        context.addLine(to: rotateHandle)
        context.strokePath()
        drawHandle(at: rotateHandle, in: context, tint: Self.activeTint, hollow: true)
    }

    private func stroke(_ corners: [CGPoint], in context: CGContext) {
        guard corners.count == 4 else { return }
        context.beginPath()
        context.move(to: corners[0])
        for corner in corners.dropFirst() {
            context.addLine(to: corner)
        }
        context.closePath()
        context.strokePath()
    }

    private func drawGuides(in context: CGContext, clippedTo rect: CGRect) {
        guard !guidesX.isEmpty || !guidesY.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(Self.guideTint.cgColor)
        context.setLineWidth(1)
        context.beginPath()
        // The canvas is one very tall view, so a guide is drawn only across the
        // strip being redrawn. Running it the full length of a two-metre sheet
        // would be the same line at a hundred times the cost.
        for x in guidesX {
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for y in guidesY {
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }

    private static let light = UITraitCollection(userInterfaceStyle: .light)
    private static let activeTint = UIColor.systemBlue.resolvedColor(with: light)
    private static let lockedTint = UIColor.systemGray.resolvedColor(with: light)
    private static let handleFill = UIColor.systemBackground.resolvedColor(with: light)
    /// Pink rather than the selection blue: a guide is not part of the thing you
    /// are holding, and it has to stay legible where it crosses the outline.
    private static let guideTint = UIColor.systemPink.resolvedColor(with: light).withAlphaComponent(0.9)

    private func drawHandle(at point: CGPoint, in context: CGContext, tint: UIColor, hollow: Bool) {
        let radius = Self.handleDrawRadius
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.setFillColor(Self.handleFill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(tint.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect)
        if !hollow {
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: rect.insetBy(dx: radius * 0.55, dy: radius * 0.55))
        }
    }
}
