//
//  SelectionGeometry.swift
//  Bitarf RI
//
//  The geometry of a *set* of objects: the box that contains them, and turning
//  the whole set at once.
//
//  Multi-selection in this editor is transient — nothing about a set is written
//  to the document — so none of this is persisted. It only has to answer two
//  questions well: where is the selection, and where does it go when you twist
//  it. Both are pure functions of the objects handed in, which is what lets them
//  be tested without a screen.
//

import CoreGraphics
import Foundation

public enum SelectionGeometry {

    /// The axis-aligned box containing every object's own bounding box.
    ///
    /// `.null` for an empty set rather than `.zero`: a set with nothing in it has
    /// no position, and `.zero` would claim it sits in the paper's top-left
    /// corner. `.null` also makes `union` fold correctly from the first element.
    public static func unionBoundingBox(_ objects: [CanvasObject]) -> CGRect {
        objects.reduce(CGRect.null) { $0.union($1.boundingBox) }
    }

    /// Turn a whole set about one point.
    ///
    /// Each object does two things at once: it spins on its own centre, and that
    /// centre orbits `centre`. Doing only the first is what a naive "apply the
    /// rotation to everything" gives, and it reads as the objects breaking
    /// formation rather than the group turning.
    ///
    /// `objects` must be the state captured when the gesture *began*, and
    /// `delta` the total angle since then — never the last frame's increment.
    /// Origins are rounded to whole dots on the way out, and rounding an
    /// increment on every frame makes a slow twist walk the set across the
    /// paper. Recomputing from the start each time keeps the error bounded at
    /// half a dot no matter how long the gesture runs.
    ///
    /// Locked objects are returned untouched. They still belong to the set — and
    /// so still count towards the centre the caller passes in — but a locked
    /// object that moved would not be locked.
    public static func rotated(
        _ objects: [CanvasObject],
        by delta: CGFloat,
        about centre: CGPoint
    ) -> [CanvasObject] {
        guard delta != 0 else { return objects }

        let cosine = cos(delta)
        let sine = sin(delta)

        return objects.map { object in
            guard !object.isLocked else { return object }

            var moved = object
            let start = object.center
            let dx = start.x - centre.x
            let dy = start.y - centre.y

            // Clockwise-positive, matching `CanvasObject.rotation` and the
            // corner maths in `CanvasObject.corners`.
            moved.rotation = object.rotation + delta
            moved.setCenter(
                CGPoint(
                    x: centre.x + dx * cosine - dy * sine,
                    y: centre.y + dx * sine + dy * cosine
                )
            )
            moved.origin = DotPoint(
                x: moved.origin.x.rounded(),
                y: moved.origin.y.rounded()
            )
            return moved
        }
    }
}
