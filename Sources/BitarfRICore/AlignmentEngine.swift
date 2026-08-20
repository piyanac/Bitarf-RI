//
//  AlignmentEngine.swift
//  Bitarf RI
//
//  Lining a set of objects up with each other, and spreading them evenly.
//
//  The single-object editor already aligns one thing to the paper's edges. This
//  is the other half the one-pager promised and never got: the operations that
//  only mean anything once more than one object is selected.
//
//  Everything measures `boundingBox`, never `frame`. A tilted object sitting
//  flush against an edge is what the eye reads as aligned, and it is what the
//  neighbouring object's selection outline would be measured against.
//
//  Locked objects are returned untouched everywhere in this file, but they still
//  count towards the extent being aligned to. That asymmetry is the point:
//  "line these up with the thing I can't move" is the most common reason to lock
//  something in the first place.
//

import CoreGraphics
import Foundation

public enum AlignmentEdge: Sendable {
    case left, centerX, right
    case top, centerY, bottom
}

public enum DistributionAxis: Sendable {
    case horizontal, vertical
}

public enum AlignmentEngine {

    // MARK: Alignment

    /// - Parameters:
    ///   - bounds: what to align to. `nil` means the objects' own union, which
    ///     is object-to-object alignment; passing the page's content rect is how
    ///     the caller aligns to paper instead.
    ///   - asGroup: `false` moves every object onto the edge, closing the set up
    ///     against it. `true` keeps the set's internal arrangement and slides the
    ///     whole thing until its union touches the edge — which is what "align
    ///     the selection to the paper" means, and is nonsense against the set's
    ///     own union (the union already touches itself).
    public static func aligned(
        _ objects: [CanvasObject],
        to edge: AlignmentEdge,
        within bounds: CGRect? = nil,
        asGroup: Bool = false
    ) -> [CanvasObject] {
        guard !objects.isEmpty else { return objects }

        let union = SelectionGeometry.unionBoundingBox(objects)
        let reference = bounds ?? union
        guard !reference.isNull else { return objects }

        if asGroup {
            let delta = offset(from: union, to: reference, edge: edge)
            return objects.map { moved($0, by: delta) }
        }

        return objects.map { object in
            moved(object, by: offset(from: object.boundingBox, to: reference, edge: edge))
        }
    }

    // MARK: Distribution

    /// Spread objects so the *gaps* between them are equal, holding the two
    /// outermost ones still.
    ///
    /// Equal gaps rather than equal centres, and no option to choose: for
    /// same-sized objects the two are identical, and for mixed sizes equal
    /// centres is the one that looks wrong — a wide box and a narrow one on
    /// evenly spaced centres leave visibly unequal air between them.
    ///
    /// Fewer than three objects is a no-op. With two there is nothing between
    /// the ends to distribute.
    public static func distributed(
        _ objects: [CanvasObject],
        along axis: DistributionAxis
    ) -> [CanvasObject] {
        guard objects.count >= 3 else { return objects }

        // Sorted by position, tie-broken by input index so two objects sharing a
        // centre cannot swap places depending on how the set happened to be
        // enumerated. A Set has no order; the result must not inherit one.
        let ordered = objects.enumerated().sorted { lhs, rhs in
            let a = leading(lhs.element.boundingBox, axis: axis) + extent(lhs.element.boundingBox, axis: axis) / 2
            let b = leading(rhs.element.boundingBox, axis: axis) + extent(rhs.element.boundingBox, axis: axis) / 2
            return a == b ? lhs.offset < rhs.offset : a < b
        }

        guard let first = ordered.first?.element, let last = ordered.last?.element else { return objects }

        let start = leading(first.boundingBox, axis: axis)
        let end = leading(last.boundingBox, axis: axis) + extent(last.boundingBox, axis: axis)
        let occupied = ordered.reduce(CGFloat.zero) { $0 + extent($1.element.boundingBox, axis: axis) }
        let gap = (end - start - occupied) / CGFloat(ordered.count - 1)

        // The cursor stays in floating point and each target is rounded off it,
        // rather than the cursor advancing by rounded steps. Five boxes with
        // fractional widths would otherwise accumulate up to two and a half dots
        // of drift by the far end.
        var result = objects
        var cursor = start
        for (index, object) in ordered {
            let target = cursor.rounded()
            cursor += extent(object.boundingBox, axis: axis) + gap

            let delta = target - leading(object.boundingBox, axis: axis)
            let vector = axis == .horizontal
                ? CGPoint(x: delta, y: 0)
                : CGPoint(x: 0, y: delta)
            result[index] = moved(object, by: vector)
        }
        return result
    }

    // MARK: Machinery

    private static func moved(_ object: CanvasObject, by delta: CGPoint) -> CanvasObject {
        guard !object.isLocked, delta != .zero else { return object }
        var moved = object
        moved.origin = DotPoint(
            x: (object.origin.x + delta.x).rounded(),
            y: (object.origin.y + delta.y).rounded()
        )
        return moved
    }

    private static func offset(from box: CGRect, to reference: CGRect, edge: AlignmentEdge) -> CGPoint {
        switch edge {
        case .left: return CGPoint(x: reference.minX - box.minX, y: 0)
        case .centerX: return CGPoint(x: reference.midX - box.midX, y: 0)
        case .right: return CGPoint(x: reference.maxX - box.maxX, y: 0)
        case .top: return CGPoint(x: 0, y: reference.minY - box.minY)
        case .centerY: return CGPoint(x: 0, y: reference.midY - box.midY)
        case .bottom: return CGPoint(x: 0, y: reference.maxY - box.maxY)
        }
    }

    private static func leading(_ box: CGRect, axis: DistributionAxis) -> CGFloat {
        axis == .horizontal ? box.minX : box.minY
    }

    private static func extent(_ box: CGRect, axis: DistributionAxis) -> CGFloat {
        axis == .horizontal ? box.width : box.height
    }
}
