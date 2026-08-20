//
//  SnapEngine.swift
//  Bitarf RI
//
//  Alignment lines, and optionally the pull towards them.
//
//  The one-pager put this last on purpose: on a free canvas an unconditional
//  snap is worse than none, because the moment you want to nudge something by
//  one dot the editor drags it back. So the two halves are separated here and
//  stay separated all the way up to the toggles —
//
//    * finding the lines an object is nearly aligned to, which is information;
//    * moving the object onto them, which is a decision.
//
//  A caller that only wants the first asks for `snapping: false` and gets an
//  offset of zero with the lines still filled in.
//
//  Everything is in canvas dots and knows nothing about views, so the whole
//  thing is testable without a screen.
//

import CoreGraphics
import Foundation

public struct SnapEngine: Sendable {

    // MARK: Result

    public struct Result: Equatable, Sendable {
        /// Dots to add to the object being dragged so it lands on the lines.
        /// Always zero when the caller asked not to snap.
        public var offset: CGPoint
        /// Canvas x of every vertical line to draw.
        public var verticalLines: [CGFloat]
        /// Canvas y of every horizontal line to draw.
        public var horizontalLines: [CGFloat]

        public init(offset: CGPoint = .zero, verticalLines: [CGFloat] = [], horizontalLines: [CGFloat] = []) {
            self.offset = offset
            self.verticalLines = verticalLines
            self.horizontalLines = horizontalLines
        }

        public static let none = Result()

        public var hasLines: Bool { !verticalLines.isEmpty || !horizontalLines.isEmpty }
    }

    // MARK: Configuration

    /// How near an edge has to be, in dots, before it counts as aligned.
    ///
    /// Six dots is 0.75 mm — under the width of the drawn line at print
    /// resolution, and far below what a finger can hold still. Callers scale it
    /// by the display scale so the *screen* distance stays constant.
    public static let defaultTolerance: CGFloat = 6

    /// Two lines closer together than this are the same line as far as the user
    /// is concerned, and drawing both would just thicken it.
    private static let coincident: CGFloat = 0.5

    private let verticalCandidates: [CGFloat]
    private let horizontalCandidates: [CGFloat]
    private let tolerance: CGFloat

    // MARK: Init

    /// Collect every line in `document` worth aligning to, ignoring the objects
    /// being dragged.
    ///
    /// A whole selection has to be excluded, not just one member: a set that
    /// kept its own members as candidates would report every internal edge as an
    /// alignment and then snap to itself the moment it started moving.
    public init(document: BitarfDocument, excluding ids: Set<UUID>, tolerance: CGFloat = SnapEngine.defaultTolerance) {
        let fixed = CGFloat(document.fixedAxisDots)
        let margin = document.margin

        // The fixed axis is real paper with two real edges, so both of them and
        // the centre between them are worth aligning to.
        var fixedAxisLines: [CGFloat] = [0, fixed / 2, fixed]
        if margin > 0 {
            fixedAxisLines.append(contentsOf: [margin, fixed - margin])
        }

        // The growing axis has no far edge: the roll ends wherever the content
        // does, which is a function of the object currently being dragged. A
        // line that moves when you approach it is not a line, so only the start
        // of the roll gets one.
        var growingAxisLines: [CGFloat] = [0]
        if margin > 0 { growingAxisLines.append(margin) }

        var vertical = document.orientation.isPortrait ? fixedAxisLines : growingAxisLines
        var horizontal = document.orientation.isPortrait ? growingAxisLines : fixedAxisLines

        // Hidden objects put no ink on the paper, so aligning to one would mean
        // aligning to something the user cannot see. Locked ones are visible and
        // therefore count — being unable to move a thing is a good reason to
        // line other things up with it.
        for object in document.objects where !object.isHidden && !ids.contains(object.id) {
            let box = object.boundingBox
            vertical.append(contentsOf: [box.minX, box.midX, box.maxX])
            horizontal.append(contentsOf: [box.minY, box.midY, box.maxY])
        }

        self.verticalCandidates = Self.condensed(vertical)
        self.horizontalCandidates = Self.condensed(horizontal)
        self.tolerance = max(0, tolerance)
    }

    /// Single-object convenience. Kept so every caller that drags one thing —
    /// and every test that was written against one — reads the same as before.
    public init(document: BitarfDocument, excluding id: UUID?, tolerance: CGFloat = SnapEngine.defaultTolerance) {
        self.init(document: document, excluding: id.map { [$0] } ?? [], tolerance: tolerance)
    }

    private static func condensed(_ values: [CGFloat]) -> [CGFloat] {
        var out: [CGFloat] = []
        for value in values.sorted() where out.last.map({ value - $0 > coincident }) ?? true {
            out.append(value)
        }
        return out
    }

    // MARK: Angles

    /// How near a right angle counts as being on it.
    ///
    /// Tighter than the positional tolerance because it does not need to be
    /// generous: five degrees either side still leaves every other angle
    /// reachable by dragging, and the inspector's typed field reaches all of
    /// them exactly. What it buys is that 89.4° — which nobody has ever wanted —
    /// stops being the usual result of trying to stand something upright.
    public static let defaultAngleTolerance: CGFloat = 5 * .pi / 180

    /// Pull a rotation onto the nearest quarter turn, or leave it alone.
    ///
    /// Quarter turns only. Eighths sound helpful and are not: 45° is a design
    /// decision, and an editor that kept grabbing it while you were aiming for
    /// 40° would be making that decision for you.
    ///
    /// Multiples beyond one turn snap too — 450° is 90°, and the callers here
    /// accumulate a total angle rather than normalising it.
    public static func snappedAngle(
        _ radians: CGFloat,
        tolerance: CGFloat = SnapEngine.defaultAngleTolerance
    ) -> CGFloat {
        guard tolerance > 0 else { return radians }
        let quarter = CGFloat.pi / 2
        let target = (radians / quarter).rounded() * quarter
        return abs(radians - target) <= tolerance ? target : radians
    }

    // MARK: Queries

    /// Align a whole object, given the axis-aligned box it currently occupies.
    ///
    /// Rotated objects align by that box rather than by their corners: it is
    /// what the eye reads as the object's extent, and it is what the selection
    /// outline of a neighbour would be measured against.
    public func result(for box: CGRect, snapping: Bool) -> Result {
        resolve(
            verticalEdges: [box.minX, box.midX, box.maxX],
            horizontalEdges: [box.minY, box.midY, box.maxY],
            snapping: snapping
        )
    }

    /// Align a single point — the corner a resize handle is dragging.
    public func result(for point: CGPoint, snapping: Bool) -> Result {
        resolve(verticalEdges: [point.x], horizontalEdges: [point.y], snapping: snapping)
    }

    // MARK: Machinery

    private func resolve(verticalEdges: [CGFloat], horizontalEdges: [CGFloat], snapping: Bool) -> Result {
        let dx = snapping ? Self.bestDelta(edges: verticalEdges, candidates: verticalCandidates, tolerance: tolerance) : 0
        let dy = snapping ? Self.bestDelta(edges: horizontalEdges, candidates: horizontalCandidates, tolerance: tolerance) : 0

        // After snapping, only lines the object actually sits on are true — an
        // almost-match that lost to a nearer one would be drawing a claim the
        // geometry does not support. Without snapping nothing moved, so every
        // line within reach is reported and the user can see what they are
        // approaching.
        let reach = snapping ? Self.coincident : tolerance

        return Result(
            offset: CGPoint(x: dx, y: dy),
            verticalLines: Self.matches(edges: verticalEdges, candidates: verticalCandidates, offset: dx, reach: reach),
            horizontalLines: Self.matches(edges: horizontalEdges, candidates: horizontalCandidates, offset: dy, reach: reach)
        )
    }

    /// The smallest move that puts any edge onto any candidate, or zero.
    private static func bestDelta(edges: [CGFloat], candidates: [CGFloat], tolerance: CGFloat) -> CGFloat {
        var best: CGFloat?
        for edge in edges {
            for candidate in candidates {
                let delta = candidate - edge
                guard abs(delta) <= tolerance else { continue }
                if let current = best, abs(current) <= abs(delta) { continue }
                best = delta
            }
        }
        return best ?? 0
    }

    private static func matches(
        edges: [CGFloat],
        candidates: [CGFloat],
        offset: CGFloat,
        reach: CGFloat
    ) -> [CGFloat] {
        candidates.filter { candidate in
            edges.contains { abs($0 + offset - candidate) <= reach }
        }
    }
}
