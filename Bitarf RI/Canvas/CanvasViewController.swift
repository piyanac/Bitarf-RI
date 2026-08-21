//
//  CanvasViewController.swift
//  Bitarf RI
//
//  The editor surface: a UIScrollView whose content is one very tall (or very
//  wide) sheet of paper.
//
//  Two decisions from the one-pager are baked in here and are worth restating
//  because they explain what is *missing*:
//
//  1. The canvas never zooms. Two-finger gestures always belong to the selected
//     object, which removes the mode conflict between "scale the thing" and
//     "scale the view" — the fixed axis already fits the screen exactly.
//  2. Dragging is 1:1 and the loupe makes the result visible; accuracy comes
//     from the numeric inspector. Alignment guides and snapping sit on top of
//     that as two separate opt-ins (`EditorState.guidesEnabled` /
//     `snapEnabled`) — never as the only way to place something, because the
//     one dot a user cannot reach is the one the editor pulled them off.
//

import Combine
import CoreGraphics
import UIKit

@MainActor
final class CanvasViewController: UIViewController {

    // MARK: Dependencies

    let editor: EditorState

    /// Raised when a tap lands on more than one object and the user needs to say
    /// which one they meant.
    var onDisambiguate: (([UUID]) -> Void)?

    // MARK: Views

    private let scrollView = UIScrollView()
    private let contentView = CanvasContentView()
    private let overlayView = CanvasSelectionOverlayView()
    private lazy var loupe = LoupeView(source: contentView)
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    /// The menu is built lazily after the tap has made this object the selection.
    private var editMenuObjectID: UUID?

    private var textEditor: CanvasTextEditorView?
    private weak var presentedFontPicker: UIFontPickerViewController?

    /// Last `EditorState.liveTextRevision` this controller has reacted to.
    private var seenLiveTextRevision = 0

    // MARK: Gesture state

    private enum DragMode {
        case none
        /// One entry per unlocked member. A single selection is the one-element
        /// case, so there is no second code path to keep in step.
        case move(startOrigins: [UUID: CGPoint], startUnion: CGRect)
        case resize(handle: CanvasHandle, anchor: CGPoint, startObject: CanvasObject)
        /// Dragging the rule between column `index` and `index + 1` of a table.
        case resizeColumn(index: Int, startObject: CanvasObject)
        /// Dragging the rule below row `index`. The heights are captured at the
        /// start because the row's own height is what the drag adds to, and
        /// re-reading it each frame would compound the rounding.
        case resizeRow(index: Int, startObject: CanvasObject, startHeights: [CGFloat])
        /// Dragging a table's bottom edge, which is every row at once.
        case resizeAllRows(startObject: CanvasObject, startHeights: [CGFloat])
        /// Dragging one end of the cell block. `fromAnchorEnd` is the top-left
        /// grip, which moves the anchor and leaves the far corner standing.
        case tableRange(objectID: UUID, fromAnchorEnd: Bool)
        case rotate(startRotation: CGFloat, startAngle: CGFloat, centre: CGPoint)
        /// Turning a whole selection. `startObjects` and `centre` are both
        /// captured once here and never recomputed: an axis-aligned union swells
        /// as its members turn, so a per-frame centre would spiral.
        case rotateSet(startObjects: [CanvasObject], startAngle: CGFloat, centre: CGPoint)
    }

    private var dragMode: DragMode = .none

    /// Built once per drag, because the lines cannot change while one object is
    /// being moved — every other object is standing still, and rebuilding the
    /// candidate list on each touch would be the one part of dragging that
    /// scales with document size.
    private var snapEngine: SnapEngine?

    private var pinchStartSize: CGSize?
    private var pinchStartFontScale: CGFloat = 1
    private var rotationStart: CGFloat?
    private var rotationSetStart: (objects: [CanvasObject], centre: CGPoint)?

    /// Whether the rotation currently being dragged is sitting on a right angle.
    /// Tracked only so the tick fires on the way in and not on every frame after.
    private var isAngleSnapped = false

    /// Horizontal / vertical padding around the sheet, in points.
    private let canvasPadding: CGFloat = 12

    /// How far the chrome overlay reaches past the paper, in points.
    ///
    /// A `draw(_:)` is clipped to its view's bounds, and a table's header bars
    /// and rotation handle both sit *outside* the object — which for an object
    /// against the edge of the sheet is outside the sheet. The overlay is grown
    /// instead, and every point handed to it carries this offset.
    private let overlayMargin: CGFloat = 44

    private var cancellables: Set<AnyCancellable> = []

    // MARK: Init

    init(editor: EditorState) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .always
        view.addSubview(scrollView)

        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.12
        contentView.layer.shadowRadius = 6
        contentView.layer.shadowOffset = CGSize(width: 0, height: 2)
        scrollView.addSubview(contentView)
        scrollView.addSubview(overlayView)
        contentView.addInteraction(editMenuInteraction)

        view.addSubview(loupe)

        installGestures()
        observeKeyboard()

        editor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        warmTextInput()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCanvas()
    }

    /// Tell the editor what part of the paper is on screen, in dots, so a new
    /// object can be dropped in the middle of it. `adjustedContentInset` is the
    /// right inset here — unlike the scale above, an object inserted while the
    /// keyboard is up should land in the strip still visible above it.
    private func publishVisibleRect() {
        let scale = max(contentView.displayScale, 0.0001)
        let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        guard visible.width > 1, visible.height > 1 else { return }
        let inCanvas = contentView.convert(visible, from: scrollView)
        editor.visibleRectDots = CGRect(
            x: inCanvas.minX / scale,
            y: inCanvas.minY / scale,
            width: inCanvas.width / scale,
            height: inCanvas.height / scale
        )
    }

    /// Wake the text input system up before the user needs it.
    ///
    /// Two costs land on the first box edited in the app's life, and both of
    /// them are what makes the first character typed arrive late while every
    /// one after it is instant:
    ///
    /// - the keyboard, which lives in another process that the first
    ///   `becomeFirstResponder` has to start, along with the input mode and IME;
    /// - Writing Tools, whose coordinator a `UITextView` builds lazily. The
    ///   property is read-only, so it cannot be handed one made earlier — but
    ///   reading it is what makes the text view build it, so a read is the way
    ///   to ask for that work now.
    ///
    /// The canvas appearing is the moment to spend both: the user still has to
    /// place or double-tap a box before they can type, so the work happens in
    /// dead time. The warm-up is the real editor class, on a throwaway ID that
    /// belongs to no object, so the same TextKit stack, input traits and
    /// accessory bar get built as well. Asking for the keyboard and giving it
    /// up in one run-loop turn means it never gets as far as animating in —
    /// nothing shows on screen — and what was loaded stays loaded for the rest
    /// of the process, so this is done once.
    private func warmTextInput() {
        guard !Self.didWarmTextInput, view.window != nil else { return }
        Self.didWarmTextInput = true

        let warm = CanvasTextEditorView(objectID: UUID())
        warm.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        view.addSubview(warm)
        if #available(iOS 18.2, *) {
            _ = warm.writingToolsCoordinator
        }
        warm.becomeFirstResponder()
        warm.resignFirstResponder()
        warm.removeFromSuperview()
    }

    private static var didWarmTextInput = false

    // MARK: - Layout

    private func layoutCanvas() {
        let document = editor.document
        // Safe area only, not `adjustedContentInset`: the keyboard also lives in
        // the content inset, and a sheet that rescaled itself every time the
        // keyboard appeared would move the words out from under the caret.
        let available = scrollView.bounds.inset(by: scrollView.safeAreaInsets).size
        guard available.width > 1, available.height > 1 else { return }

        // The fixed axis is what has to fit on screen.
        // 此處應插入經典機型固定軸尺寸的版面比例案例。
        let scale: CGFloat
        if document.orientation.isPortrait {
            scale = max(0.05, (available.width - canvasPadding * 2) / CGFloat(document.fixedAxisDots))
        } else {
            scale = max(0.05, (available.height - canvasPadding * 2) / CGFloat(document.fixedAxisDots))
        }

        contentView.displayScale = scale
        contentView.document = document
        contentView.showsMarginGuide = editor.showsMarginGuide

        let canvasSize = contentView.canvasViewSize
        let originX = document.orientation.isPortrait
            ? max(canvasPadding, (available.width - canvasSize.width) / 2)
            : canvasPadding
        let originY = document.orientation.isPortrait
            ? canvasPadding
            : max(canvasPadding, (available.height - canvasSize.height) / 2)

        contentView.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: canvasSize)
        contentView.layer.shadowPath = UIBezierPath(rect: contentView.bounds).cgPath
        overlayView.frame = contentView.frame.insetBy(dx: -overlayMargin, dy: -overlayMargin)

        scrollView.contentSize = CGSize(
            width: max(available.width, canvasSize.width + originX + canvasPadding),
            height: max(available.height, canvasSize.height + originY + canvasPadding)
        )

        publishVisibleRect()
        refreshSelectionOverlay()
        layoutTextEditor()
    }

    /// Pull fresh state out of the editor after any published change.
    func refresh() {
        guard isViewLoaded else { return }
        contentView.document = editor.document
        contentView.showsMarginGuide = editor.showsMarginGuide
        contentView.editingObjectID = editor.editingTextID
        contentView.editingCell = editor.editingCell

        let revision = editor.liveTextRevision
        let rewrittenElsewhere = revision != seenLiveTextRevision
        seenLiveTextRevision = revision

        // The strip grows as objects move, so the scroll content has to be
        // re-measured on every document change, not only on rotation.
        layoutCanvas()
        syncTextEditorPresence(rewrittenElsewhere: rewrittenElsewhere)
    }

    private func refreshSelectionOverlay() {
        guard editor.editingTextID == nil else {
            overlayView.clearSelection()
            return
        }

        if let object = editor.selectedObject {
            let corners = object.corners.map { overlayPoint(contentView.viewPoint(from: $0)) }
            overlayView.update(
                corners: corners,
                locked: object.isLocked,
                heightIsDraggable: heightIsDraggable(object)
            )
            refreshTableChrome(for: object)
            return
        }

        let members = editor.selectedObjects
        guard members.count > 1 else {
            overlayView.clearSelection()
            return
        }

        // The union is re-derived here, on every layout, rather than held from
        // the start of a gesture: it is chrome, and chrome has to track the art.
        // The maths keeps its own captured copy — see `DragMode.rotateSet`.
        let union = SelectionGeometry.unionBoundingBox(members)
        let scale = contentView.displayScale
        let unionCorners = [
            CGPoint(x: union.minX, y: union.minY),
            CGPoint(x: union.maxX, y: union.minY),
            CGPoint(x: union.maxX, y: union.maxY),
            CGPoint(x: union.minX, y: union.maxY),
        ].map { overlayPoint(CGPoint(x: $0.x * scale, y: $0.y * scale)) }

        overlayView.updateSelectionSet(
            quads: members.map {
                (corners: $0.corners.map { overlayPoint(contentView.viewPoint(from: $0)) }, locked: $0.isLocked)
            },
            union: unionCorners
        )
    }

    /// Is this object's height its own to set?
    ///
    /// A text box measures its height from its content and a line has only a
    /// length, so for those two the bottom handle would be a control the
    /// renderer is free to ignore, and it is not offered.
    private func heightIsDraggable(_ object: CanvasObject) -> Bool {
        // A table's height is the sum of its rows, so the bottom handle has
        // somewhere to put what it is given: every row takes an equal share.
        if object.isTable { return true }
        if object.isText { return false }
        if case .shape(let shape) = object.content, shape.kind == .line { return false }
        return true
    }

    // MARK: - Table chrome

    /// The cell block and the rule grips for a selected table, in the overlay's
    /// point space.
    ///
    /// Everything is measured in dots against the object's own upright frame and
    /// then rotated, so a turned table's grips ride its edges instead of drifting
    /// off into the page.
    private func refreshTableChrome(for object: CanvasObject) {
        guard FeatureFlags.tableEditor, let table = object.table, !object.isLocked else {
            overlayView.updateTable(rangeCorners: [], grips: [], headers: [])
            return
        }

        let frame = object.frame
        let scale = max(contentView.displayScale, 0.0001)
        let thickness = CanvasSelectionOverlayView.headerThickness / scale
        let gap = CanvasSelectionOverlayView.headerGap / scale
        let gripOffset = CanvasSelectionOverlayView.gripOffset / scale
        let range = editor.tableRange(for: object.id)

        let columnEdges = TableLayout.columnEdges(table, width: frame.width)
        let rowEdges = TableLayout.rowEdges(table, width: frame.width)

        var grips: [(kind: CanvasTableGrip, position: CGPoint, angle: CGFloat)] = []
        var headers: [(kind: CanvasTableGrip, corners: [CGPoint], selected: Bool)] = []

        // Column bars lie along the top edge, row bars down the left edge. A
        // bar is the whole row or column, so every one of them can be taken in
        // a tap; the rule grips ride the boundaries between bars.
        for column in 0..<table.columnCount {
            let rect = CGRect(
                x: frame.minX + columnEdges[column],
                y: frame.minY - gap - thickness,
                width: columnEdges[column + 1] - columnEdges[column],
                height: thickness
            )
            headers.append((
                .columnHeader(column),
                quad(rect, in: object),
                range?.columnRange.contains(column) ?? false
            ))
        }
        for row in 0..<table.rowCount {
            let rect = CGRect(
                x: frame.minX - gap - thickness,
                y: frame.minY + rowEdges[row],
                width: thickness,
                height: rowEdges[row + 1] - rowEdges[row]
            )
            headers.append((
                .rowHeader(row),
                quad(rect, in: object),
                range?.rowRange.contains(row) ?? false
            ))
        }

        // The outer left and right edges are the object's own resize handles, so
        // only the internal column rules get a grip. Rows are different: the
        // last rule is the table's bottom edge, and dragging it is how the final
        // row grows.
        if table.columnCount > 1 {
            for index in 0..<(table.columnCount - 1) {
                let dot = CGPoint(x: frame.minX + columnEdges[index + 1], y: frame.minY - gripOffset)
                grips.append((.column(index), overlayPoint(rotating: dot, in: object), object.rotation))
            }
        }
        for index in 0..<table.rowCount {
            let dot = CGPoint(x: frame.minX - gripOffset, y: frame.minY + rowEdges[index + 1])
            grips.append((.row(index), overlayPoint(rotating: dot, in: object), object.rotation))
        }

        var rangeCorners: [CGPoint] = []
        if let range, let rect = TableLayout.rangeRect(range, content: table, frame: frame) {
            rangeCorners = quad(rect, in: object)
            grips.append((.rangeStart, rangeCorners[0], object.rotation))
            grips.append((.rangeEnd, rangeCorners[2], object.rotation))
        }

        overlayView.updateTable(rangeCorners: rangeCorners, grips: grips, headers: headers)
    }

    /// A dot-space rectangle in `object`'s upright frame, as four view-space
    /// corners turned by the object's rotation.
    private func quad(_ rect: CGRect, in object: CanvasObject) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ].map { overlayPoint(rotating: $0, in: object) }
    }

    /// A dot-space point in `object`'s upright frame, turned by the object's
    /// rotation and converted into the overlay's space.
    private func overlayPoint(rotating dot: CGPoint, in object: CanvasObject) -> CGPoint {
        overlayPoint(contentView.viewPoint(from: rotated(dot, in: object)))
    }

    /// A point in the content view's space, moved into the overlay's.
    private func overlayPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + overlayMargin, y: point.y + overlayMargin)
    }

    // MARK: - Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        contentView.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        contentView.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.45
        longPress.delegate = self
        contentView.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        contentView.addGestureRecognizer(pan)
        // Only defer scrolling until our pan has had a chance to claim the touch;
        // it fails immediately when the touch is not on the selection, so this
        // costs nothing perceptible.
        scrollView.panGestureRecognizer.require(toFail: pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        contentView.addGestureRecognizer(pinch)

        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))
        rotate.delegate = self
        contentView.addGestureRecognizer(rotate)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        endTextEditing()
        let point = gesture.location(in: contentView)
        let dot = contentView.dotPoint(from: point)
        let slop = 6 / max(contentView.displayScale, 0.0001)

        // The table's chrome sits outside the object, on paper that belongs to
        // nothing, so it has to be asked about before the hit test: a tap that
        // fell through would clear the very selection it was aimed at. A header
        // bar takes its whole row or column — the same thing a header cell does
        // everywhere else — and a rule grip is drag-only but still swallows the
        // tap it caught.
        if !editor.isSelectionMode, let object = editor.selectedObject {
            let overlayPoint = gesture.location(in: overlayView)
            if overlayView.grip(at: overlayPoint) != nil { return }
            switch overlayView.header(at: overlayPoint) {
            case .rowHeader(let index):
                editor.selectTableRow(object.id, index)
                UISelectionFeedbackGenerator().selectionChanged()
                return
            case .columnHeader(let index):
                editor.selectTableColumn(object.id, index)
                UISelectionFeedbackGenerator().selectionChanged()
                return
            default:
                break
            }
        }

        let hits = editor.document.hitTestAll(dot, slop: slop)

        if editor.isSelectionMode {
            // A tap on empty paper does nothing here. Clearing on a stray miss
            // would throw away a set the user had just finished assembling, and
            // the way out is already a permanent button in the corner.
            guard let top = hits.first else { return }
            editor.toggleSelection(top.id)
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }

        guard let top = hits.first else {
            editMenuInteraction.dismissMenu()
            editor.select(nil)
            return
        }

        // A tap on a table that is *already* the selection points at a cell
        // rather than raising the edit menu again: the menu's commands are all
        // about the object, and by this point the user has moved on to what is
        // inside it. The menu is still one tap away — deselect, or tap the
        // table from elsewhere.
        if FeatureFlags.tableEditor,
           editor.selectedID == top.id,
           !top.isLocked,
           let cell = tableCell(at: dot, in: top) {
            editMenuInteraction.dismissMenu()
            editor.selectTableCell(top.id, cell)
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }

        editor.select(top.id)
        editMenuObjectID = top.id
        editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // In 選取模式 a tap means membership and nothing else. `tap` already
        // requires this one to fail, so a double tap settles into exactly one
        // toggle rather than opening a text box.
        guard !editor.isSelectionMode else { return }
        let dot = contentView.dotPoint(from: gesture.location(in: contentView))
        let slop = 6 / max(contentView.displayScale, 0.0001)
        guard let object = editor.document.hitTest(dot, slop: slop) else { return }
        editor.select(object.id)
        if object.isText {
            editMenuInteraction.dismissMenu()
            beginTextEditing(object.id)
        } else if FeatureFlags.tableEditor, let cell = tableCell(at: dot, in: object) {
            editMenuInteraction.dismissMenu()
            beginTextEditing(object.id, cell: cell)
        }
    }

    /// Which cell of `object`'s table `dot` lands in, in canvas space.
    private func tableCell(at dot: CGPoint, in object: CanvasObject) -> TableCellAddress? {
        guard let table = object.table else { return nil }
        // The table lays out upright; rotate the point back into the object's
        // own space before asking the grid about it.
        return TableLayout.cell(at: unrotated(dot, in: object), content: table, frame: object.frame)
    }

    /// `point` moved into `object`'s unrotated space.
    private func unrotated(_ point: CGPoint, in object: CanvasObject) -> CGPoint {
        guard object.rotation != 0 else { return point }
        let centre = object.center
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let cosine = cos(-object.rotation)
        let sine = sin(-object.rotation)
        return CGPoint(
            x: centre.x + dx * cosine - dy * sine,
            y: centre.y + dx * sine + dy * cosine
        )
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let dot = contentView.dotPoint(from: gesture.location(in: contentView))
        let slop = 8 / max(contentView.displayScale, 0.0001)
        let hits = editor.document.hitTestAll(dot, slop: slop)

        if editor.isSelectionMode {
            // Add everything under the finger. The disambiguation picker this
            // would otherwise raise is single-selection by construction, and
            // with no marquee this is the only way to take several objects at
            // once from the canvas itself.
            guard !hits.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            editor.setSelection(editor.selectedIDs.union(hits.map(\.id)))
            return
        }

        guard hits.count > 1 else {
            if let single = hits.first { editor.select(single.id) }
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onDisambiguate?(hits.map(\.id))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let pointInContent = gesture.location(in: contentView)
        let pointInView = gesture.location(in: view)

        switch gesture.state {
        case .began:
            let members = editor.selectedObjects
            let movable = members.filter { !$0.isLocked }
            guard !movable.isEmpty else {
                dragMode = .none
                return
            }
            editor.beginInteraction()

            // A set offers the rotation handle and no other, so there are only
            // three ways this can begin.
            // The table grips come first: the block's ends sit inside the object
            // where a drag would otherwise move it, and the rule grips sit
            // outside it where nothing would claim the touch at all.
            if let object = editor.selectedObject,
               let grip = overlayView.grip(at: gesture.location(in: overlayView)),
               beginGripDrag(grip, object: object) {
                if case .tableRange = dragMode {} else {
                    showLoupe(focusOn: pointInContent, touch: pointInView)
                }
                return
            }

            // A column rule is inside the object, so it never competes with the
            // corner handles — but it must be asked about before the drag falls
            // through to moving the whole table.
            if let object = editor.selectedObject,
               let divider = columnDivider(near: contentView.dotPoint(from: pointInContent), in: object) {
                dragMode = .resizeColumn(index: divider, startObject: object)
                showLoupe(focusOn: pointInContent, touch: pointInView)
                return
            }

            switch (overlayView.handle(at: gesture.location(in: overlayView)), editor.selectedObject) {
            case (.some(let handle), .some(let object)):
                beginHandleDrag(handle, object: object)
            case (.some, .none):
                dragMode = .rotateSet(
                    startObjects: members,
                    startAngle: .nan, // filled in on the first .changed, where there is a point
                    centre: centreOf(members)
                )
            case (.none, _):
                dragMode = .move(
                    startOrigins: Dictionary(uniqueKeysWithValues: movable.map { ($0.id, $0.origin.cgPoint) }),
                    startUnion: SelectionGeometry.unionBoundingBox(movable)
                )
            }
            prepareSnapping(excluding: editor.selectedIDs)
            showLoupe(focusOn: pointInContent, touch: pointInView)

        case .changed:
            applyDrag(translation: gesture.translation(in: contentView), pointInContent: pointInContent)
            showLoupe(focusOn: loupeFocus(defaultingTo: pointInContent), touch: pointInView)

        case .ended, .cancelled, .failed:
            commitDrag()
            loupe.hide()

        default:
            break
        }
    }

    /// The internal table rule under `dot`, if the flag is on and the selection
    /// is a single unlocked table.
    private func columnDivider(near dot: CGPoint, in object: CanvasObject) -> Int? {
        guard FeatureFlags.tableEditor, !object.isLocked, let table = object.table else { return nil }
        let tolerance = max(SnapEngine.defaultTolerance, 8 / max(contentView.displayScale, 0.0001))
        return TableLayout.columnDivider(
            near: unrotated(dot, in: object),
            content: table,
            frame: object.frame,
            tolerance: tolerance
        )
    }

    /// Start whichever drag `grip` stands for. Returns false when the grip no
    /// longer matches the object — a stale index after an undo, say — so the
    /// caller can fall through to the ordinary drags.
    private func beginGripDrag(_ grip: CanvasTableGrip, object: CanvasObject) -> Bool {
        guard let table = object.table, !object.isLocked else { return false }
        switch grip {
        case .rangeStart, .rangeEnd:
            guard editor.tableRange(for: object.id) != nil else { return false }
            dragMode = .tableRange(objectID: object.id, fromAnchorEnd: grip == .rangeStart)
            return true
        case .column(let index):
            guard index >= 0, index + 1 < table.columnCount else { return false }
            dragMode = .resizeColumn(index: index, startObject: object)
            return true
        case .row(let index):
            guard index >= 0, index < table.rowCount else { return false }
            dragMode = .resizeRow(
                index: index,
                startObject: object,
                startHeights: TableLayout.rowHeights(table, width: object.size.width)
            )
            return true
        case .columnHeader, .rowHeader:
            // The bars are for tapping. A drag that started on one is the user
            // reaching for the rule they missed, so let it move the object
            // rather than doing nothing at all.
            return false
        }
    }

    private func beginHandleDrag(_ handle: CanvasHandle, object: CanvasObject) {
        switch handle {
        case .rotate:
            let centre = object.center
            dragMode = .rotate(
                startRotation: object.rotation,
                startAngle: .nan, // filled in on the first .changed, where we have a point
                centre: centre
            )
        case .bottomEdge where object.isTable:
            // Not a resize: the object's height is not a number a table keeps,
            // so the drag has to be spent on the rows that make it up.
            guard let table = object.table else { return }
            dragMode = .resizeAllRows(
                startObject: object,
                startHeights: TableLayout.rowHeights(table, width: object.size.width)
            )

        case .bottomRight, .rightEdge, .bottomEdge:
            // The anchor is whatever must not move: the opposite corner for the
            // corner handle, and the opposite edge's midpoint for an edge one —
            // an edge handle changes one axis, so the other has to stay put.
            let corners = object.corners
            let anchor: CGPoint
            switch handle {
            case .bottomRight: anchor = corners[0]
            case .rightEdge: anchor = midpoint(corners[0], corners[3])
            case .bottomEdge: anchor = midpoint(corners[0], corners[1])
            case .rotate: anchor = object.center
            }
            dragMode = .resize(handle: handle, anchor: anchor, startObject: object)
        }
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func applyDrag(translation: CGPoint, pointInContent: CGPoint) {
        let scale = max(contentView.displayScale, 0.0001)
        let dot = contentView.dotPoint(from: pointInContent)

        switch dragMode {
        case .none:
            return

        case .resizeColumn(let index, let startObject):
            guard let table = startObject.table else { return }
            // Rotation is a property of the object, not of the rule: measure the
            // drag along the table's own horizontal axis.
            let delta = (translation.x * cos(startObject.rotation)
                + translation.y * sin(startObject.rotation)) / scale
            let resized = TableLayout.resizingColumns(
                table,
                divider: index,
                by: delta,
                width: startObject.size.width
            )
            editor.updateObject(startObject.id) { $0.content = .table(resized) }

        case .resizeRow(let index, let startObject, let startHeights):
            guard let table = startObject.table else { return }
            // Measured along the table's own vertical axis, for the same reason
            // the column drag is measured along its horizontal one.
            let delta = (translation.y * cos(startObject.rotation)
                - translation.x * sin(startObject.rotation)) / scale
            let resized = TableLayout.resizingRow(
                table,
                row: index,
                by: delta,
                width: startObject.size.width,
                from: startHeights
            )
            editor.updateObject(startObject.id) { $0.content = .table(resized) }

        case .resizeAllRows(let startObject, let startHeights):
            guard let table = startObject.table else { return }
            let delta = (translation.y * cos(startObject.rotation)
                - translation.x * sin(startObject.rotation)) / scale
            let resized = TableLayout.resizingAllRows(
                table,
                by: delta,
                width: startObject.size.width,
                from: startHeights
            )
            editor.updateObject(startObject.id) { $0.content = .table(resized) }

        case .tableRange(let objectID, let fromAnchorEnd):
            guard let object = editor.document[objectID], let table = object.table else { return }
            let cell = TableLayout.nearestCell(
                to: unrotated(dot, in: object),
                content: table,
                frame: object.frame
            )
            guard editor.tableSelection.map({ fromAnchorEnd ? $0.anchor : $0.focus }) != cell else { return }
            editor.extendTableSelection(objectID, to: cell, fromAnchorEnd: fromAnchorEnd)
            UISelectionFeedbackGenerator().selectionChanged()

        case .move(let startOrigins, let startUnion):
            let delta = CGPoint(x: translation.x / scale, y: translation.y / scale)
            var offset = CGPoint(x: delta.x.rounded(), y: delta.y.rounded())

            // Align by the visible extent, not by any origin: a rotated box's
            // top-left corner is nowhere near the top-left of what the eye sees,
            // and for a set there is no single origin to speak of anyway. One
            // box for the whole selection also means the guides describe what is
            // being dragged rather than one arbitrary member of it.
            let box = startUnion.offsetBy(dx: offset.x, dy: offset.y)
            let result = applySnapResult(snapEngine?.result(for: box, snapping: editor.snapEnabled))
            offset.x += result.offset.x
            offset.y += result.offset.y

            editor.moveSelection(from: startOrigins, by: offset)

        case .resize(let handle, let anchor, let start):
            guard let id = editor.selectedID else { return }
            // Snap the corner under the finger, then let the existing geometry
            // turn it into a size. The alternative — resizing first and nudging
            // the result — would fight the aspect-ratio and measured-height
            // rules below, which are allowed to overrule the drag.
            let result = applySnapResult(snapEngine?.result(for: dot, snapping: editor.snapEnabled))
            let snapped = CGPoint(x: dot.x + result.offset.x, y: dot.y + result.offset.y)
            resize(id: id, handle: handle, anchor: anchor, start: start, to: snapped)

        case .rotate(let startRotation, let startAngle, let centre):
            guard let id = editor.selectedID else { return }
            let angle = atan2(dot.y - centre.y, dot.x - centre.x)
            if startAngle.isNaN {
                dragMode = .rotate(startRotation: startRotation, startAngle: angle, centre: centre)
                return
            }
            editor.updateObject(id) { [self] object in
                object.rotation = snapped(startRotation + (angle - startAngle))
            }

        case .rotateSet(let startObjects, let startAngle, let centre):
            let angle = atan2(dot.y - centre.y, dot.x - centre.x)
            if startAngle.isNaN {
                dragMode = .rotateSet(startObjects: startObjects, startAngle: angle, centre: centre)
                return
            }
            // Total angle since the gesture began, against the objects as they
            // were then — never the last frame's increment against the last
            // frame's result. Origins round to whole dots, and re-rounding an
            // increment sixty times a second walks the selection off the paper.
            // The *turn* snaps, not each member's own angle: a set whose members
            // sit at assorted angles has no single rotation to put on a right
            // angle, and a quarter turn of the whole thing is what was asked for.
            // For the usual set — everything upright — the two are the same.
            editor.rotateSelection(by: snapped(angle - startAngle), about: centre, from: startObjects)
        }
    }

    /// Pull a rotation onto the nearest quarter turn, with a tick when it takes.
    ///
    /// Positional snapping shows a line, so the user can see the pull coming and
    /// see it land. An angle has nothing to draw, so the feedback has to be felt
    /// instead — otherwise the difference between "I am holding it at 90°" and
    /// "it has decided I meant 90°" is invisible.
    private func snapped(_ radians: CGFloat) -> CGFloat {
        let snapped = SnapEngine.snappedAngle(radians)
        let didSnap = snapped != radians
        if didSnap != isAngleSnapped {
            isAngleSnapped = didSnap
            if didSnap { UISelectionFeedbackGenerator().selectionChanged() }
        }
        return snapped
    }

    /// The point a set turns about: the centre of the box around all of it,
    /// locked members included. They anchor the turn without joining it.
    private func centreOf(_ objects: [CanvasObject]) -> CGPoint {
        let union = SelectionGeometry.unionBoundingBox(objects)
        return CGPoint(x: union.midX, y: union.midY)
    }

    private func resize(id: UUID, handle: CanvasHandle, anchor: CGPoint, start: CanvasObject, to dot: CGPoint) {
        // Work in the object's own unrotated frame: rotate the anchor→touch
        // vector back by -rotation and the problem becomes axis-aligned.
        let rotation = start.rotation
        let dx = dot.x - anchor.x
        let dy = dot.y - anchor.y
        let cosine = cos(-rotation)
        let sine = sin(-rotation)
        let localX = dx * cosine - dy * sine
        let localY = dx * sine + dy * cosine

        let minimum: CGFloat = 8
        // An edge handle moves one axis and leaves the other exactly as it was.
        var newWidth = handle == .bottomEdge
            ? start.size.width
            : max(minimum, abs(localX).rounded())
        var newHeight = handle == .rightEdge
            ? start.size.height
            : max(minimum, abs(localY).rounded())

        if start.isText {
            // A text box's height is measured, never dragged — there is no page
            // bottom for it to overflow past, so a manual height would be a
            // number the renderer is free to ignore.
            newHeight = start.size.height
        }
        // Artwork keeps its aspect ratio; a squashed 1-bit photo is almost never
        // what was meant, and there is no formatting panel to un-squash it from.
        // Which side leads depends on the handle: the bottom one is asking about
        // the height, so there the width is what follows.
        let intrinsicRatio: CGFloat?
        switch start.content {
        case .image(let image) where image.pixelSize.width > 0:
            intrinsicRatio = image.pixelSize.height / image.pixelSize.width
        case .vector(let vector) where vector.intrinsicSize.width > 0:
            intrinsicRatio = vector.intrinsicSize.height / vector.intrinsicSize.width
        default:
            intrinsicRatio = nil
        }
        if let intrinsicRatio, intrinsicRatio > 0 {
            if handle == .bottomEdge {
                newWidth = max(minimum, (newHeight / intrinsicRatio).rounded())
            } else {
                newHeight = max(minimum, (newWidth * intrinsicRatio).rounded())
            }
        }
        if case .shape(let shape) = start.content, shape.kind == .line {
            newHeight = start.size.height
        }
        newWidth = min(newWidth, 20_000)
        newHeight = min(newHeight, 20_000)

        // Where the anchor sits in the new box's own space, as a share of half
        // its size. An edge handle anchors to the middle of the opposite edge,
        // so the axis it does not touch has no sign at all.
        let anchorSignX: CGFloat = handle == .bottomEdge ? 0 : -1
        let anchorSignY: CGFloat = handle == .rightEdge ? 0 : -1

        let localAnchor = CGPoint(x: anchorSignX * newWidth / 2, y: anchorSignY * newHeight / 2)
        let forwardCos = cos(rotation)
        let forwardSin = sin(rotation)
        let rotatedAnchor = CGPoint(
            x: localAnchor.x * forwardCos - localAnchor.y * forwardSin,
            y: localAnchor.x * forwardSin + localAnchor.y * forwardCos
        )
        let newCentre = CGPoint(x: anchor.x - rotatedAnchor.x, y: anchor.y - rotatedAnchor.y)

        editor.updateObject(id) { object in
            object.size = DotSize(width: newWidth, height: newHeight)
            object.setCenter(newCentre)
            object.origin = DotPoint(x: object.origin.x.rounded(), y: object.origin.y.rounded())
        }
    }

    private func commitDrag() {
        if case .none = dragMode {} else {
            editor.endInteraction()
        }
        dragMode = .none
        snapEngine = nil
        isAngleSnapped = false
        overlayView.clearGuides()
        loupe.updateGuides(x: [], y: [])
    }

    // MARK: - Snapping

    /// Collect the lines this drag can align to, or nothing at all when the user
    /// has turned both halves off — in which case every `result(for:)` call
    /// below short-circuits and dragging costs exactly what it did before.
    private func prepareSnapping(excluding ids: Set<UUID>) {
        guard editor.snapEnabled || editor.guidesEnabled else {
            snapEngine = nil
            return
        }
        snapEngine = SnapEngine(
            document: editor.document,
            // The whole selection, not one member: a set that kept its own
            // members as candidates would snap to itself the moment it moved.
            excluding: ids,
            // Tolerance is a *screen* distance, so convert it through the
            // current display scale instead of treating it as a document value.
            // 此處應插入經典機型窄幅與標準幅面的吸附比例案例。
            tolerance: SnapEngine.defaultTolerance / max(contentView.displayScale, 0.0001)
        )
    }

    /// Show `result`'s lines and hand back the offset the caller should apply.
    ///
    /// The two are separate everywhere else in this feature and they stay
    /// separate here: the engine was asked whether to snap, so `offset` is
    /// already zero when it should be, and this only decides whether the lines
    /// are drawn.
    @discardableResult
    private func applySnapResult(_ result: SnapEngine.Result?) -> SnapEngine.Result {
        guard let result else {
            overlayView.clearGuides()
            loupe.updateGuides(x: [], y: [])
            return .none
        }
        if editor.guidesEnabled {
            let scale = contentView.displayScale
            overlayView.updateGuides(
                x: result.verticalLines.map { $0 * scale + overlayMargin },
                y: result.horizontalLines.map { $0 * scale + overlayMargin }
            )
            loupe.updateGuides(x: result.verticalLines, y: result.horizontalLines)
        } else {
            overlayView.clearGuides()
            loupe.updateGuides(x: [], y: [])
        }
        return result
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let object = editor.selectedObject, !object.isLocked else { return }

        switch gesture.state {
        case .began:
            editor.beginInteraction()
            pinchStartSize = object.size.cgSize
            pinchStartFontScale = 1

        case .changed:
            guard let startSize = pinchStartSize else { return }
            let factor = max(0.1, min(gesture.scale, 20))
            let id = object.id
            let centre = object.center
            editor.updateObject(id) { object in
                let newWidth = max(8, (startSize.width * factor).rounded())
                object.size.width = newWidth
                if !object.isText {
                    object.size.height = max(8, (startSize.height * factor).rounded())
                }
                object.setCenter(centre)
                object.origin = DotPoint(x: object.origin.x.rounded(), y: object.origin.y.rounded())
            }
            // Scaling a text box that only got wider would not read as "bigger",
            // so the type scales with it and the height follows from reflow.
            if object.isText {
                let incremental = factor / pinchStartFontScale
                pinchStartFontScale = factor
                scaleFontSizes(of: id, by: incremental)
            }

        case .ended, .cancelled, .failed:
            pinchStartSize = nil
            editor.endInteraction()

        default:
            break
        }
    }

    private func scaleFontSizes(of id: UUID, by factor: CGFloat) {
        guard abs(factor - 1) > 0.001 else { return }
        editor.updateRichText(id) { rich in
            for paragraphIndex in rich.paragraphs.indices {
                for runIndex in rich.paragraphs[paragraphIndex].runs.indices {
                    let current = rich.paragraphs[paragraphIndex].runs[runIndex].style.fontSize
                    rich.paragraphs[paragraphIndex].runs[runIndex].style.fontSize =
                        min(400, max(4, (current * factor).rounded()))
                }
            }
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        // A two-finger twist on a multi-selection turns the whole set. The pinch
        // that shares those fingers guards on `selectedObject`, which is nil for
        // a set, so the set turns without also scaling — which is exactly the
        // scope, and it costs nothing to get.
        if editor.hasMultipleSelection {
            handleSetRotation(gesture)
            return
        }

        guard let object = editor.selectedObject, !object.isLocked else { return }

        switch gesture.state {
        case .began:
            editor.beginInteraction()
            rotationStart = object.rotation
        case .changed:
            guard let start = rotationStart else { return }
            let id = object.id
            editor.updateObject(id) { [self] in $0.rotation = snapped(start + gesture.rotation) }
        case .ended, .cancelled, .failed:
            rotationStart = nil
            isAngleSnapped = false
            editor.endInteraction()
        default:
            break
        }
    }

    private func handleSetRotation(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            let members = editor.selectedObjects
            guard members.contains(where: { !$0.isLocked }) else { return }
            editor.beginInteraction()
            // Captured once, like the handle drag: the union's own centre moves
            // as the set turns, so reading it again per frame would spiral.
            rotationSetStart = (objects: members, centre: centreOf(members))
        case .changed:
            guard let start = rotationSetStart else { return }
            editor.rotateSelection(by: snapped(gesture.rotation), about: start.centre, from: start.objects)
        case .ended, .cancelled, .failed:
            rotationSetStart = nil
            isAngleSnapped = false
            editor.endInteraction()
        default:
            break
        }
    }

    // MARK: - Loupe

    private func loupeFocus(defaultingTo point: CGPoint) -> CGPoint {
        // While resizing or rotating, the interesting place is the handle being
        // dragged, which is where the finger already is; while moving, it is the
        // object's leading corner, because that is the edge being aligned.
        guard case .move = dragMode else { return point }
        if let object = editor.selectedObject {
            return contentView.viewPoint(from: object.corners[0])
        }
        // For a set, the leading corner of the box around it — the same edge the
        // guides are being measured against.
        let union = SelectionGeometry.unionBoundingBox(editor.selectedObjects)
        guard !union.isNull else { return point }
        return contentView.viewPoint(from: CGPoint(x: union.minX, y: union.minY))
    }

    private func showLoupe(focusOn focus: CGPoint, touch: CGPoint) {
        loupe.show(focus: focus, in: view, near: touch)
        view.bringSubviewToFront(loupe)
    }

    // MARK: - Text editing

    private func syncTextEditorPresence(rewrittenElsewhere: Bool = false) {
        if let id = editor.editingTextID {
            if textEditor?.objectID != id || textEditor?.cell != editor.editingCell {
                installTextEditor(for: id, cell: editor.editingCell)
            } else {
                if rewrittenElsewhere { reloadTextEditorContent() }
                layoutTextEditor()
            }
        } else if textEditor != nil {
            // A rewrite from outside is the newer truth, so the string the text
            // view is still holding is stale and must not be committed over it.
            teardownTextEditor(commit: !rewrittenElsewhere)
        }
        syncPanelSuspension()
    }

    /// Take the keyboard back once the panel that borrowed it has gone.
    private func syncPanelSuspension() {
        guard let editorView = textEditor else { return }
        if editor.isTextEditingSuspended {
            editorView.isYieldingToPanel = true
        } else if editorView.isYieldingToPanel {
            editorView.resumeEditing(selecting: editor.textSelection ?? editorView.selectedRange)
        }
    }

    /// Pull the model back into the live text view after the format panel, a
    /// pinch or an undo rewrote the same object.
    private func reloadTextEditorContent() {
        guard let editorView = textEditor,
              let rich = editor.document.richText(editorView.objectID, cell: editorView.cell) else { return }
        // Mid-composition the IME owns the text view; replacing the storage would
        // drop the half-typed syllable, which is the one thing this app cannot
        // afford to get wrong.
        guard editorView.markedTextRange == nil else { return }

        let foreground = CanvasTextEditorView.ink.cgColor
        let attributed = rich.attributedString(foreground: foreground)
        editorView.replaceContent(attributed, typing: typingAttributes(for: rich, string: attributed, in: editorView))
        refreshFormattingAccessory()
    }

    /// Style for the next character typed: whatever sits at the caret, falling
    /// back to the box's own leading style when there is no text to read.
    private func typingAttributes(
        for rich: RichText,
        string: NSAttributedString,
        in editorView: CanvasTextEditorView
    ) -> [NSAttributedString.Key: Any] {
        let length = string.length
        guard length > 0 else { return rich.typingAttributes(foreground: CanvasTextEditorView.ink.cgColor) }
        let caret = min(editorView.selectedRange.location, length)
        return string.attributes(at: max(0, caret - 1), effectiveRange: nil)
    }

    func beginTextEditing(_ id: UUID, cell: TableCellAddress? = nil) {
        guard let object = editor.document[id], !object.isLocked else { return }
        guard cell == nil ? object.isText : object.table?.contains(cell!) == true else { return }
        editor.select(id)
        editor.editingTextID = id
        editor.editingCell = cell
    }

    func endTextEditing() {
        guard editor.editingTextID != nil else { return }
        editor.editingTextID = nil
    }

    private func installTextEditor(for id: UUID, cell: TableCellAddress? = nil) {
        teardownTextEditor(commit: true)
        guard let rich = editor.document.richText(id, cell: cell) else { return }

        let editorView = CanvasTextEditorView(objectID: id, cell: cell)
        let attributed = rich.attributedString(foreground: CanvasTextEditorView.ink.cgColor)
        // A brand-new box is empty, and an empty text view types in the system
        // default — 17 *dots* of SF, not the size the box was created with.
        editorView.replaceContent(
            attributed,
            typing: typingAttributes(for: rich, string: attributed, in: editorView)
        )
        // Weak on the view, and checked against the installed one: a text view
        // that has just been torn down still reports a change while it is being
        // resigned, and that late callback used to be read as belonging to
        // whatever session came after it.
        editorView.onChange = { [weak self, weak editorView] attributed in
            guard let self, let editorView, self.textEditor === editorView else { return }
            self.textDidChange(editorView, attributed: attributed)
        }
        editorView.onFinish = { [weak self] in
            self?.editor.editingTextID = nil
        }
        editorView.onSelectionChange = { [weak self] range in
            guard let self else { return }
            self.editor.textSelection = range
            self.refreshFormattingAccessory()
        }
        editorView.onRequestFontPicker = { [weak self] in
            self?.showFontPicker(for: id)
        }
        editorView.onRequestSizePicker = { [weak self] source in
            self?.showSizePicker(for: id, from: source)
        }
        editorView.onSetBold = { [weak self] value in
            self?.updateFormattingStyle(for: id) { $0.bold = value }
        }
        editorView.onSetItalic = { [weak self] value in
            self?.updateFormattingStyle(for: id) { $0.italic = value }
        }
        editorView.onSetUnderline = { [weak self] value in
            self?.updateFormattingStyle(for: id) { $0.underline = value }
        }
        editorView.onSetLanguageTag = { [weak self] value in
            self?.updateFormattingStyle(for: id) { $0.languageTag = value }
        }
        editorView.onSetFontName = { [weak self] name in
            self?.updateFormattingStyle(for: id) { $0.fontName = name }
        }
        editorView.onSetAlignment = { [weak self] alignment in
            guard let self else { return }
            self.editor.updateFormattingParagraphStyle(for: id) { $0.alignment = alignment }
            self.reloadTextEditorContent()
            self.seenLiveTextRevision = self.editor.liveTextRevision
            self.refreshFormattingAccessory()
        }
        editorView.onAdvanceCell = { [weak self] reverse in
            self?.editor.advanceEditingCell(reverse: reverse)
        }
        editorView.onMoveCellRight = { [weak self] in
            self?.editor.moveEditingCellRight()
        }
        contentView.addSubview(editorView)
        textEditor = editorView
        contentView.editingObjectID = id
        contentView.editingCell = cell
        overlayView.clearSelection()
        layoutTextEditor()
        refreshFormattingAccessory()
        editorView.becomeFirstResponder()
        scrollEditingBoxIntoView()
    }

    private func refreshFormattingAccessory() {
        guard let editorView = textEditor,
              let style = editor.formattingRunStyle(for: editorView.objectID) else { return }
        editorView.updateFormattingControls(
            style: style,
            supportsRegionalVariants: FontCatalog.hasGSUB(postScriptName: style.fontName),
            alignment: editor.formattingParagraphStyle(for: editorView.objectID)?.alignment ?? .left
        )
    }

    /// Formatting commands originate in the input accessory and update that
    /// same surface directly. They do not wait for a SwiftUI canvas refresh to
    /// round-trip back into UIKit.
    private func updateFormattingStyle(
        for id: UUID,
        _ transform: (inout RunStyle) -> Void
    ) {
        editor.updateFormattingRunStyle(for: id, transform)
        reloadTextEditorContent()
        seenLiveTextRevision = editor.liveTextRevision
        refreshFormattingAccessory()
    }

    private func showFontPicker(for id: UUID) {
        guard presentedViewController == nil,
              let style = editor.formattingRunStyle(for: id) else { return }

        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        configuration.displayUsingSystemFont = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = self
        picker.selectedFontDescriptor = UIFontDescriptor(fontAttributes: [
            .family: FontCatalog.familyName(forPostScriptName: style.fontName),
        ])
        picker.title = "選擇字體"

        // The system catalogue is the same picker the format sheet uses. It
        // temporarily borrows first responder without ending text editing, then
        // restores the exact selection when it closes.
        textEditor?.isYieldingToPanel = true
        editor.isTextEditingSuspended = true
        picker.presentationController?.delegate = self
        presentedFontPicker = picker
        present(picker, animated: true)
    }

    private func showSizePicker(for id: UUID, from source: UIBarButtonItem) {
        guard presentedViewController == nil,
              let style = editor.formattingRunStyle(for: id) else { return }
        // 此處應插入經典機型硬體衍生的字級上限。
        let upper = style.fontSize.rounded(.up)
        let picker = FontSizePickerViewController(
            value: style.fontSize,
            upperBound: upper,
            onEditingChanged: { [weak self] editing in
                if editing { self?.editor.beginInteraction() } else { self?.editor.endInteraction() }
            },
            onChange: { [weak self] value in
                self?.editor.updateFormattingRunStyle(for: id) { $0.fontSize = value }
            }
        )
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceItem = source
        picker.popoverPresentationController?.permittedArrowDirections = .down
        picker.popoverPresentationController?.delegate = self
        present(picker, animated: true)
    }

    private func finishFontPicking() {
        presentedFontPicker = nil
        editor.isTextEditingSuspended = false
    }

    private func layoutTextEditor() {
        guard let editorView = textEditor,
              let object = editor.document[editorView.objectID] else { return }

        // A cell session is laid out over its own rectangle inside the object.
        // The rectangle is measured, not stored, so it is right even while the
        // row is still growing under the caret.
        var box = object.frame
        if let cell = editorView.cell, let table = object.table {
            guard let rect = TableLayout.textRect(cell, content: table, frame: object.frame) else { return }
            box = rect
        }

        let scale = contentView.displayScale
        // The text view works in *dot* units and is scaled by a transform, so
        // Core Text sees exactly the metrics the renderer will use. Setting a
        // point-sized font instead would drift from the printed result.
        editorView.transform = .identity
        editorView.bounds = CGRect(origin: .zero, size: CGSize(
            width: box.width,
            height: max(box.height, 8)
        ))
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        if object.rotation != 0 {
            transform = transform.rotated(by: object.rotation)
        }
        editorView.transform = transform
        // The cell's centre has to travel with the object's rotation, which the
        // object's own centre does not tell us.
        editorView.center = contentView.viewPoint(
            from: rotated(CGPoint(x: box.midX, y: box.midY), in: object)
        )
    }

    /// `point` moved out of `object`'s unrotated space into canvas space.
    private func rotated(_ point: CGPoint, in object: CanvasObject) -> CGPoint {
        guard object.rotation != 0 else { return point }
        let centre = object.center
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let cosine = cos(object.rotation)
        let sine = sin(object.rotation)
        return CGPoint(
            x: centre.x + dx * cosine - dy * sine,
            y: centre.y + dx * sine + dy * cosine
        )
    }

    /// `editorView` is the session that produced the string, not whatever is
    /// installed now — the two are the same view in every ordinary edit, and
    /// telling them apart is what stops a dying text view from writing into the
    /// next session's target.
    private func textDidChange(_ editorView: CanvasTextEditorView, attributed: NSAttributedString) {
        commitText(attributed, to: editorView.objectID, cell: editorView.cell)
        layoutTextEditor()
        refreshFormattingAccessory()
        scrollEditingBoxIntoView()
    }

    /// Write the live string back into whichever `RichText` this session owns.
    private func commitText(_ attributed: NSAttributedString, to id: UUID, cell: TableCellAddress?) {
        let rich = RichText.from(attributedString: attributed)
        guard let cell else {
            // A box session only ever owns a text box. Anything else under this
            // id means the session outlived what it was editing, and rewriting
            // the content would turn that object into a text box.
            editor.updateObject(id) { object in
                guard case .text = object.content else { return }
                object.content = .text(rich)
            }
            return
        }
        editor.updateObject(id) { object in
            guard case .table(var table) = object.content else { return }
            table[cell] = rich
            object.content = .table(table)
        }
    }

    private func teardownTextEditor(commit: Bool) {
        guard let editorView = textEditor else { return }
        if commit, let attributed = editorView.attributedText {
            commitText(attributed, to: editorView.objectID, cell: editorView.cell)
        }
        // Resigning is what makes the text view emit its last change — after the
        // commit above, so it carries nothing new, and with the callbacks cut it
        // cannot reach the model at all.
        editorView.onChange = nil
        editorView.onFinish = nil
        editorView.onSelectionChange = nil
        editorView.resignFirstResponder()
        editorView.removeFromSuperview()
        textEditor = nil
        contentView.editingObjectID = nil
        contentView.editingCell = nil
        refreshSelectionOverlay()
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        // Only a box being edited should push the canvas up. Any other keyboard
        // — the warm-up above, or one belonging to something presented over the
        // canvas — would otherwise leave an inset behind that nothing removes.
        guard textEditor != nil else { return }
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let converted = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - converted.minY - view.safeAreaInsets.bottom)
        scrollView.contentInset.bottom = overlap
        scrollView.verticalScrollIndicatorInsets.bottom = overlap
        scrollEditingBoxIntoView()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    /// Keep the box being typed into above the keyboard. This is the detail LOCL
    /// spent the most time on: on a phone the keyboard takes half the screen,
    /// and a text box that grows downwards will walk itself under it.
    private func scrollEditingBoxIntoView() {
        guard let editorView = textEditor,
              let object = editor.document[editorView.objectID] else { return }

        let boxInScroll = contentView.convert(
            CGRect(
                x: object.boundingBox.minX * contentView.displayScale,
                y: object.boundingBox.minY * contentView.displayScale,
                width: object.boundingBox.width * contentView.displayScale,
                height: object.boundingBox.height * contentView.displayScale
            ),
            to: scrollView
        )
        // A generous margin: the caret is usually at the bottom of the box while
        // typing, and landing it flush against the keyboard reads as clipped.
        scrollView.scrollRectToVisible(boxInScroll.insetBy(dx: 0, dy: -32), animated: true)
    }
}

// MARK: - UIScrollViewDelegate

extension CanvasViewController: UIScrollViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        publishVisibleRect()
    }
}

// MARK: - Object edit menu

@available(iOS 16.0, *)
extension CanvasViewController: @MainActor UIEditMenuInteractionDelegate {

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let id = editMenuObjectID, let object = editor.document[id] else { return nil }

        let cut = UIAction(title: "剪下", image: UIImage(systemName: "scissors")) { [weak self] _ in
            guard let self, self.editor.cutObject(id) else { return }
            self.editor.statusMessage = "已剪下「\(object.displayName)」"
        }
        let copy = UIAction(title: "拷貝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self, self.editor.copyObject(id) else { return }
            self.editor.statusMessage = "已拷貝「\(object.displayName)」"
        }
        let paste = UIAction(
            title: "貼上",
            image: UIImage(systemName: "doc.on.clipboard"),
            attributes: editor.canPasteObject ? [] : [.disabled]
        ) { [weak self] _ in
            guard let self, let pasted = self.editor.pasteObject() else { return }
            self.editor.statusMessage = "已貼上「\(pasted.displayName)」"
        }

        // Set apart from the three above: those do something to this object,
        // while this one changes what a tap means. It is also the only way into
        // 選取模式, which is why it lives on the menu every object already has
        // rather than costing a slot in the bottom bar.
        let multiSelect = UIAction(title: "選取", image: UIImage(systemName: "checklist")) { [weak self] _ in
            self?.editor.enterSelectionMode(seededWith: id)
        }

        return UIMenu(children: [
            UIMenu(title: "", options: .displayInline, children: [cut, copy, paste]),
            UIMenu(title: "", options: .displayInline, children: [multiSelect]),
        ])
    }
}

// MARK: - UIGestureRecognizerDelegate

extension CanvasViewController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }

        // The object pan only claims the touch when it starts on the selection
        // or one of its handles; every other touch is a scroll.
        guard editor.editingTextID == nil, !editor.selectedIDs.isEmpty else { return false }

        let location = pan.location(in: overlayView)
        if overlayView.handle(at: location) != nil { return true }
        // The rule grips hang *outside* the table, so without this the scroll
        // view would take every one of those touches.
        if overlayView.grip(at: location) != nil { return true }

        let dot = contentView.dotPoint(from: pan.location(in: contentView))
        let slop = 6 / max(contentView.displayScale, 0.0001)
        return editor.selectedObjects.contains { !$0.isLocked && $0.contains(dot, slop: slop) }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Pinch and twist are one continuous two-finger action; a single-finger
        // drag is never simultaneous with anything.
        let twoFinger: (UIGestureRecognizer) -> Bool = {
            $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer
        }
        return twoFinger(gestureRecognizer) && twoFinger(other)
    }
}

// MARK: - Keyboard formatting presentations

extension CanvasViewController: UIFontPickerViewControllerDelegate, UIPopoverPresentationControllerDelegate {

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        guard let id = textEditor?.objectID,
              let descriptor = viewController.selectedFontDescriptor else {
            viewController.dismiss(animated: true) { [weak self] in self?.finishFontPicking() }
            return
        }
        editor.updateFormattingRunStyle(for: id) {
            $0.fontName = FontCatalog.postScriptName(for: descriptor)
        }
        viewController.dismiss(animated: true) { [weak self] in self?.finishFontPicking() }
    }

    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
        viewController.dismiss(animated: true) { [weak self] in self?.finishFontPicking() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === presentedFontPicker {
            finishFontPicking()
        }
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

/// A compact, fully system-built size control. The label gives the exact dot
/// value while `UISlider` supplies the continuous adjustment and interaction
/// semantics; forcing popover adaptation off keeps the keyboard in place.
private final class FontSizePickerViewController: UIViewController {

    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let onEditingChanged: (Bool) -> Void
    private let onChange: (CGFloat) -> Void
    private var isAdjusting = false

    init(
        value: CGFloat,
        upperBound: CGFloat,
        onEditingChanged: @escaping (Bool) -> Void,
        onChange: @escaping (CGFloat) -> Void
    ) {
        self.onEditingChanged = onEditingChanged
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 286, height: 104)
        slider.minimumValue = 4
        slider.maximumValue = Float(upperBound)
        slider.value = Float(min(max(value, 4), upperBound))
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        valueLabel.font = .preferredFont(forTextStyle: .headline)
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontForContentSizeCategory = true

        slider.isContinuous = true
        slider.accessibilityLabel = "文字大小"
        slider.addTarget(self, action: #selector(beginEditing), for: .touchDown)
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        slider.addTarget(
            self,
            action: #selector(endEditing),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )

        let stack = UIStackView(arrangedSubviews: [valueLabel, slider])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        finishInteractionIfNeeded()
    }

    @objc private func beginEditing() {
        guard !isAdjusting else { return }
        isAdjusting = true
        onEditingChanged(true)
    }

    @objc private func valueChanged() {
        slider.value = slider.value.rounded()
        updateLabel()
        onChange(CGFloat(slider.value))
    }

    @objc private func endEditing() {
        finishInteractionIfNeeded()
    }

    private func finishInteractionIfNeeded() {
        guard isAdjusting else { return }
        isAdjusting = false
        onEditingChanged(false)
    }

    private func updateLabel() {
        valueLabel.text = "\(Int(slider.value.rounded())) 點"
        slider.accessibilityValue = valueLabel.text
    }
}
