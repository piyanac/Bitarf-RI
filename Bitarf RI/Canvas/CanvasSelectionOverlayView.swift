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

/// The object's own chrome: one corner that scales both ways, one edge handle
/// per axis, and the rotation stalk.
///
/// Four corners were four ways to do the same thing — the anchor moved, but the
/// result did not — while neither "just the width" nor "just the height" had a
/// handle at all. One corner and two edges cover every case once each.
enum CanvasHandle: CaseIterable {
    case bottomRight
    /// Right edge, vertically centred: width only.
    case rightEdge
    /// Bottom edge, horizontally centred: height only.
    case bottomEdge
    case rotate
}

/// The table-only grips: the two ends of a cell block, and one per rule that
/// can be dragged from outside the table's frame.
///
/// Separate from `CanvasHandle` on purpose. That enum is the object's own
/// chrome — every selected object has all five — while these exist only on a
/// table, come and go with the grid, and carry an index. Folding them together
/// would have put a `CaseIterable` list of five next to an open-ended one.
enum CanvasTableGrip: Hashable {
    /// The block's top-left end; dragging it moves the far corner's opposite.
    case rangeStart
    /// The block's bottom-right end.
    case rangeEnd
    /// The rule to the right of column `index`. Widens that column, narrows
    /// its neighbour: the table's own width does not move.
    case column(Int)
    /// The rule below row `index`. Makes that row taller and the table with it.
    case row(Int)
    /// The bar running along the outside of column `index`. Tapping it takes
    /// the whole column.
    case columnHeader(Int)
    /// The bar running down the outside of row `index`.
    case rowHeader(Int)

    var isRangeGrip: Bool {
        self == .rangeStart || self == .rangeEnd
    }

    var isColumnar: Bool {
        switch self {
        case .column, .columnHeader: return true
        default: return false
        }
    }
}

final class CanvasSelectionOverlayView: UIView {

    /// Corners of the selected object in view (point) space, clockwise from
    /// top-left, already rotated. Empty unless exactly one object is selected.
    private(set) var selectionCorners: [CGPoint] = []

    var isLocked = false

    /// Whether this object's height is its own to drag. A text box and a table
    /// measure their height from their content, so the bottom handle is left
    /// off rather than offered and ignored.
    private var hasHeightHandle = false

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

    /// The picked-out block of cells, as four already-rotated corners in view
    /// space, and the grips that go with the selected table. Both are computed
    /// by the canvas controller — this view knows about points, not about dots
    /// or grids.
    private(set) var tableRangeCorners: [CGPoint] = []
    private(set) var tableGrips: [(kind: CanvasTableGrip, position: CGPoint, angle: CGFloat)] = []

    /// The header bars, as already-rotated quads. `selected` is what the block
    /// covers, so the bars say which rows and columns are in hand.
    private(set) var tableHeaders: [(kind: CanvasTableGrip, corners: [CGPoint], selected: Bool)] = []

    /// Hit radius for a handle. Larger than the drawn dot because the drawn dot
    /// is a target, not a button.
    static let handleHitRadius: CGFloat = 22
    static let handleDrawRadius: CGFloat = 7
    static let rotateHandleOffset: CGFloat = 40

    /// A grip is smaller than a corner handle and there are more of them, so it
    /// gets a smaller catchment — otherwise two neighbouring rules would fight
    /// over the same finger.
    static let gripHitRadius: CGFloat = 14
    /// How thick the header bars are, and the gap between them and the table.
    static let headerThickness: CGFloat = 15
    static let headerGap: CGFloat = 3
    /// A rule grip rides the middle of the bars, on the boundary between two.
    static var gripOffset: CGFloat { headerGap + headerThickness / 2 }
    private static let gripLength: CGFloat = 20
    private static let gripThickness: CGFloat = 6

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

    func update(corners: [CGPoint], locked: Bool, heightIsDraggable: Bool) {
        selectionCorners = corners
        isLocked = locked
        hasHeightHandle = heightIsDraggable
        objectQuads = []
        unionCorners = []
        setNeedsDisplay()
    }

    func updateSelectionSet(quads: [(corners: [CGPoint], locked: Bool)], union: [CGPoint]) {
        selectionCorners = []
        isLocked = false
        // A set has no cell block and no rules to drag: those commands all
        // address one table.
        tableRangeCorners = []
        tableGrips = []
        objectQuads = quads
        unionCorners = union
        setNeedsDisplay()
    }

    func clearSelection() {
        selectionCorners = []
        objectQuads = []
        unionCorners = []
        tableRangeCorners = []
        tableGrips = []
        tableHeaders = []
        setNeedsDisplay()
    }

    /// Hand over the table chrome for the current selection. Empty arrays are
    /// the normal case — every object that is not a table passes them.
    func updateTable(
        rangeCorners: [CGPoint],
        grips: [(kind: CanvasTableGrip, position: CGPoint, angle: CGFloat)],
        headers: [(kind: CanvasTableGrip, corners: [CGPoint], selected: Bool)]
    ) {
        tableRangeCorners = rangeCorners
        tableGrips = grips
        tableHeaders = headers
        setNeedsDisplay()
    }

    /// The header bar under `point`, if any. Asked *after* `grip(at:)`: the
    /// grips sit on the boundary between two bars, and the rule is the finer
    /// target of the two.
    func header(at point: CGPoint) -> CanvasTableGrip? {
        guard !isLocked else { return nil }
        return tableHeaders.first { contains(point, in: $0.corners) }?.kind
    }

    /// Point in convex quad, by keeping every cross product on one side.
    private func contains(_ point: CGPoint, in corners: [CGPoint]) -> Bool {
        guard corners.count == 4 else { return false }
        var sign: CGFloat = 0
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 0.0001 { continue }
            if sign == 0 {
                sign = cross
            } else if (cross > 0) != (sign > 0) {
                return false
            }
        }
        return true
    }

    /// Nearest table grip within its hit radius, or nil.
    func grip(at point: CGPoint) -> CanvasTableGrip? {
        guard !isLocked else { return nil }
        var best: (kind: CanvasTableGrip, distance: CGFloat)?
        for grip in tableGrips {
            let distance = hypot(grip.position.x - point.x, grip.position.y - point.y)
            guard distance <= Self.gripHitRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (grip.kind, distance)
            }
        }
        return best?.kind
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
        case .bottomRight: return selectionCorners[2]
        case .rightEdge: return midpoint(selectionCorners[1], selectionCorners[2])
        case .bottomEdge:
            guard hasHeightHandle else { return nil }
            return midpoint(selectionCorners[3], selectionCorners[2])
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

        // The cell block sits under the object's own handles: it is what is
        // selected *inside* the thing the handles resize.
        drawTableRange(in: context)

        guard !isLocked else { return }

        drawTableHeaders(in: context)
        drawTableGrips(in: context)

        // Rotation handle first, so its stalk sits under the corner dots.
        if let rotateHandle = handlePosition(.rotate) {
            let topMid = midpoint(selectionCorners[0], selectionCorners[1])
            context.setStrokeColor(tint.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            context.beginPath()
            context.move(to: topMid)
            context.addLine(to: rotateHandle)
            context.strokePath()
            drawHandle(at: rotateHandle, in: context)
        }

        for handle in [CanvasHandle.bottomRight, .rightEdge, .bottomEdge] {
            guard let position = handlePosition(handle) else { continue }
            drawHandle(at: position, in: context)
        }
    }

    private func drawTableRange(in context: CGContext) {
        guard tableRangeCorners.count == 4 else { return }
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(Self.accentTint.withAlphaComponent(0.14).cgColor)
        context.beginPath()
        context.move(to: tableRangeCorners[0])
        for corner in tableRangeCorners.dropFirst() {
            context.addLine(to: corner)
        }
        context.closePath()
        context.fillPath()

        context.setStrokeColor(Self.accentTint.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2)
        stroke(tableRangeCorners, in: context)
    }

    private func drawTableHeaders(in context: CGContext) {
        for header in tableHeaders where header.corners.count == 4 {
            context.setFillColor(Self.accentTint.withAlphaComponent(header.selected ? 0.5 : 0.15).cgColor)
            context.beginPath()
            context.move(to: header.corners[0])
            for corner in header.corners.dropFirst() {
                context.addLine(to: corner)
            }
            context.closePath()
            context.fillPath()
        }
    }

    private func drawTableGrips(in context: CGContext) {
        for grip in tableGrips {
            if grip.kind.isRangeGrip {
                drawHandle(at: grip.position, in: context)
            } else {
                drawRuleGrip(at: grip.position, angle: grip.angle, kind: grip.kind, in: context)
            }
        }
    }

    /// A rule grip is a bar, not a dot: its long axis is the rule it moves, so
    /// the shape says which way it will travel before it is touched.
    private func drawRuleGrip(
        at point: CGPoint,
        angle: CGFloat,
        kind: CanvasTableGrip,
        in context: CGContext
    ) {
        let isColumn = kind.isColumnar

        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)

        // The bar lies along the rule it moves: a column grip is upright like
        // the vertical rule under it, a row grip lies flat like its horizontal
        // one. Reading the grip then means reading the line it belongs to,
        // rather than working out which way it is about to travel.
        let size = isColumn
            ? CGSize(width: Self.gripThickness, height: Self.gripLength)
            : CGSize(width: Self.gripLength, height: Self.gripThickness)
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: Self.gripThickness / 2).cgPath

        // White-filled, not grey like the round handles: a bar sits over the
        // page rather than over the object, and it has to stay legible against
        // both the paper and the header bar it rides.
        context.setFillColor(UIColor.white.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(Self.accentTint.cgColor)
        context.setLineWidth(2)
        context.addPath(path)
        context.strokePath()
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
        drawHandle(at: rotateHandle, in: context)
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
    /// The app's own accent, pinned to its light-appearance value for the same
    /// reason everything else here is: this chrome is drawn over the page, and
    /// the page is white whatever the app's appearance is.
    static let accentTint = (UIColor(named: "AccentColor") ?? .darkGray).resolvedColor(with: light)
    private static let handleFill = UIColor.systemGray.resolvedColor(with: light)
    private static let handleRim = UIColor.white
    /// Pink rather than the selection blue: a guide is not part of the thing you
    /// are holding, and it has to stay legible where it crosses the outline.
    private static let guideTint = UIColor.systemPink.resolvedColor(with: light).withAlphaComponent(0.9)

    /// One grey dot, white-rimmed, on a shadow soft enough to lift it off the
    /// page without reading as an object of its own.
    ///
    /// Every handle is drawn the same: what a handle does is said by where it
    /// sits — a corner, an edge, the end of the rotation stalk — and a second
    /// visual language on top of that would only be another thing to learn.
    private func drawHandle(at point: CGPoint, in context: CGContext) {
        let radius = Self.handleDrawRadius
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        // The shadow belongs to the dot, so it is cast by the fill alone and
        // turned off again before the rim is drawn over it.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 1),
            blur: 3,
            color: UIColor.black.withAlphaComponent(0.22).cgColor
        )
        context.setFillColor(Self.handleFill.cgColor)
        context.fillEllipse(in: rect)
        context.restoreGState()

        context.setStrokeColor(Self.handleRim.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
    }
}
