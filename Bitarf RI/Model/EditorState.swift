//
//  EditorState.swift
//  Bitarf RI
//
//  The single mutable truth for the editor. Every change to the document goes
//  through here so that undo, autosave and text reflow can never be forgotten at
//  a call site.
//

import Combine
import CoreGraphics
import Foundation
import UIKit

@MainActor
final class EditorState: ObservableObject {

    /// A private pasteboard type keeps a Bitarf RI object self-contained (including
    /// image bytes) without claiming that another app knows how to render it.
    private static let objectPasteboardType = "com.user.bitarfri.canvas-object"

    // MARK: Document

    @Published private(set) var document: BitarfDocument

    /// What is selected. Empty, one, or many.
    ///
    /// The set is transient — nothing about it reaches the document — and it is
    /// built inside 選取模式, which the object's edit menu opens and the
    /// checkmark in the top-left corner closes. Leaving the mode empties it,
    /// which is why there is no 「取消全選」 anywhere: the way out *is* the way to
    /// clear.
    ///
    /// Private setter on purpose. Every write goes through `setSelection` so
    /// that a live text box can never be left editing something that just fell
    /// out of the selection.
    @Published private(set) var selectedIDs: Set<UUID> = []

    /// Back to front, i.e. document order, which is layer order. A Set has no
    /// order of its own; this is the only one the user can see or control, so
    /// every operation that needs one takes it from here.
    var selectedObjects: [CanvasObject] {
        document.objects.filter { selectedIDs.contains($0.id) }
    }

    var selectionCount: Int { selectedIDs.count }

    var hasMultipleSelection: Bool { selectedIDs.count > 1 }

    /// Non-nil only when *exactly one* object is selected.
    ///
    /// Everything that reads this is single-object UI — the inspector's fields,
    /// the format panel, the resize handles, pinch, text editing. Handing one of
    /// five selected objects to any of them would silently apply a font or a
    /// resize to whichever member the set happened to yield first. Going nil
    /// instead drops each of them into the empty state they already have.
    var selectedID: UUID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { setSelection(newValue.map { [$0] } ?? []) }
    }

    /// Transient input mode. Deliberately not persisted: a mode you did not
    /// leave is not a preference, and relaunching into one would be a trap.
    @Published private(set) var isSelectionMode = false

    /// Non-nil while a text box is being edited in a live `UITextView`.
    @Published var editingTextID: UUID? {
        didSet {
            // Leaving the box takes its selection with it; a stale range would
            // otherwise be waiting the next time a panel opened.
            if editingTextID == nil {
                textSelection = nil
                isTextEditingSuspended = false
                editingCell = nil
            }
        }
    }

    /// Which cell of `editingTextID`'s table is being edited, or nil when the
    /// object being edited is a plain text box.
    ///
    /// Deliberately a second property rather than a richer `editingTextID`: the
    /// text-box path is the one that has to keep working exactly as it does, and
    /// every existing `editingTextID = nil` clears this too.
    @Published var editingCell: TableCellAddress? {
        didSet {
            // The block follows the caret, so stepping through cells with ⇥
            // leaves the one you stopped on highlighted rather than leaving a
            // block behind somewhere the user has walked away from. Clearing
            // the caret deliberately does *not* clear the block: coming out of
            // a cell should leave that cell in hand.
            if let editingCell { tableSelection = TableCellRange(editingCell) }
        }
    }

    /// The block of cells picked out on the selected table, with no cell being
    /// edited. Nil when the selection is not a single table, or when nothing
    /// inside it has been pointed at yet.
    ///
    /// This is a selection *within* one object, so it is cleared by the same
    /// call that changes which objects are selected — see `setSelection`.
    /// Formatting and the structure commands read it: 「這幾格」 and 「這張表」
    /// are different commands, and answering the wrong one rewrites cells the
    /// user was not looking at.
    @Published var tableSelection: TableCellRange?

    /// What is selected *inside* the box being edited, in UTF-16 offsets over
    /// the box's plain text. Nil when no box is being edited.
    ///
    /// The live text view is the only writer. It is published because the format
    /// panel is the only reader, and the panel has to know whether the user
    /// meant "these three characters" or "this box" — those are different
    /// commands and answering the wrong one destroys work.
    @Published var textSelection: NSRange?

    /// Set while a panel is up over a box that is still being edited: the text
    /// view has given up first responder to the sheet, but the editing session
    /// is not over and must not be torn down.
    @Published var isTextEditingSuspended = false

    /// Bumped whenever a text object's content is rewritten by something *other*
    /// than the live text view — the format panel, a pinch, undo.
    ///
    /// The text view owns its own string while it is up, and on the way out it
    /// commits that string back to the model. Without this signal every such
    /// change would be silently overwritten by the stale text the view was still
    /// holding, which is exactly the "I changed the font and nothing happened"
    /// bug. The canvas watches the counter and reloads instead.
    @Published private(set) var liveTextRevision = 0

    /// Draw the alignment lines a dragged object is lining up with.
    ///
    /// Independent of `snapEnabled` on purpose. Showing the line is information
    /// — it costs the user nothing and takes nothing away — while being pulled
    /// onto it is a decision, and the one-pager's whole argument against
    /// snapping was about the pull, not about the line. So this one defaults on
    /// and the pull defaults off.
    @Published var guidesEnabled = UserDefaults.standard.object(forKey: EditorState.guidesKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(guidesEnabled, forKey: Self.guidesKey) }
    }

    /// Pull a dragged object onto the lines it is near.
    ///
    /// Off by default, and stays that way until the user asks: on a free canvas
    /// wanting to nudge something one dot and being dragged back is worse than
    /// having no snapping at all.
    @Published var snapEnabled = UserDefaults.standard.bool(forKey: EditorState.snapKey) {
        didSet { UserDefaults.standard.set(snapEnabled, forKey: Self.snapKey) }
    }

    private static let guidesKey = "editorGuidesEnabled"
    private static let snapKey = "editorSnapEnabled"

    /// Draw the dashed rectangle marking the document's margins.
    ///
    /// Set from the app's 設定 tab rather than from the editor, because unlike
    /// the two above it is not something you reach for mid-drag — it is how you
    /// want the canvas to look, once.
    @Published var showsMarginGuide = UserDefaults.standard.object(forKey: EditorState.marginGuideKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsMarginGuide, forKey: Self.marginGuideKey) }
    }

    static let marginGuideKey = "editorShowsMarginGuide"

    /// Transient banner text for failures that are not worth an alert.
    @Published var statusMessage: String?

    /// The part of the canvas the user can currently see, in dots. Deliberately
    /// *not* published: it changes on every scroll frame and only matters at the
    /// moment an object is inserted, so republishing it would redraw the whole
    /// UI for nothing. Empty until the canvas has laid itself out once.
    var visibleRectDots: CGRect = .zero

    // MARK: Undo

    private var undoStack: [BitarfDocument] = []
    private var redoStack: [BitarfDocument] = []
    private var interactionSnapshot: BitarfDocument?
    private let undoLimit = 60

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // MARK: Persistence

    private let store = DocumentStore()
    private let library = DocumentLibrary()
    private var autosaveCancellable: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []
    private let autosaveSubject = PassthroughSubject<Void, Never>()

    /// The template this content came from, if any. It exists so the editor can
    /// offer 「更新範本」 — opening a template always yields a *copy*, because the
    /// common case is printing it with two words changed, and that must not
    /// quietly rewrite the thing the user saved to reuse.
    private(set) var sourceTemplateID: UUID?

    /// True once this content has been printed or saved as a template. Drives
    /// nothing but the rescue prompt: committed content is already somewhere the
    /// user can find it.
    private(set) var isCommitted = false

    /// Has the user actually done anything to this document?
    ///
    /// The blank canvas the app opens on already contains a placeholder text
    /// box, so "is it empty" cannot answer "is this worth keeping". Opening the
    /// app, looking at it and leaving must cost the user nothing — no file, no
    /// prompt, no row in a list.
    private(set) var hasBeenEdited = false

    /// The 最近 row this content already occupies, if it has one — either
    /// because it was opened from there, or because it was filed there on the
    /// way out. Reusing the id is what makes leaving twice update one row
    /// instead of breeding near-identical copies.
    private(set) var recoveredID: UUID?

    /// How many launches in a row have found this content still in the scratch
    /// slot. One means the app died once and the work is being handed straight
    /// back; two means opening it is a good bet for what killed the app, so it
    /// gets filed instead of reopened.
    private(set) var uncleanLaunches = 0

    // MARK: Init

    init(document: BitarfDocument? = nil, sourceTemplateID: UUID? = nil) {
        self.document = document ?? BitarfDocument.starter()
        self.document.reflow()
        self.sourceTemplateID = sourceTemplateID

        autosaveCancellable = autosaveSubject
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.save() }

        // The margin guide is switched from the 設定 tab, which lives behind the
        // editor and talks to `UserDefaults` directly. This editor outlives that
        // screen, so without listening it would keep showing whatever the guide
        // was when the app launched.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pullPreferences() }
            .store(in: &cancellables)
    }

    /// Re-read the preferences another screen may have changed.
    private func pullPreferences() {
        let defaults = UserDefaults.standard
        let margin = defaults.object(forKey: Self.marginGuideKey) as? Bool ?? true
        if margin != showsMarginGuide { showsMarginGuide = margin }
    }

    /// Load `document` into this editor as fresh, uncommitted work.
    ///
    /// `recoveredID` is the 最近 row this content came out of, if any, so that
    /// leaving again lands back on the same row.
    func open(_ document: BitarfDocument, sourceTemplateID: UUID? = nil, recoveredID: UUID? = nil) {
        undoStack.removeAll()
        redoStack.removeAll()
        refreshUndoFlags()
        interactionSnapshot = nil
        selectedIDs = []
        isSelectionMode = false
        editingTextID = nil
        self.sourceTemplateID = sourceTemplateID
        self.document = document
        self.document.reflow()
        liveTextRevision &+= 1
        isCommitted = false
        hasBeenEdited = false
        self.recoveredID = recoveredID
        uncleanLaunches = 0
        statusMessage = nil
        save()
    }

    /// Pick up exactly where the scratch slot left off, flags and all.
    func resume(_ document: BitarfDocument, state: DocumentLibrary.ScratchState) {
        open(document, sourceTemplateID: state.sourceTemplateID, recoveredID: state.recoveredID)
        isCommitted = state.isCommitted
        hasBeenEdited = state.hasBeenEdited
        uncleanLaunches = state.uncleanLaunches
        // `open` has already written the scratch slot with the flags reset, so
        // the restored ones have to be written again — in particular the unclean
        // launch count, which is the only thing standing between a document that
        // crashes on open and an app that reopens it for ever.
        save()
    }

    // MARK: - Mutation

    /// The document changed: schedule an autosave, and drop the committed flag.
    ///
    /// Editing after a print is how a document diverges from the copy in the
    /// history, so from here on there is once again something the app would be
    /// wrong to lose.
    private func touch() {
        isCommitted = false
        hasBeenEdited = true
        // The user is editing, so this document plainly did not crash the app on
        // the way in. Whatever the last launch suspected, it was wrong.
        uncleanLaunches = 0
        autosaveSubject.send()
    }

    /// Apply a change. Outside an interaction this pushes one undo entry; inside
    /// one (a drag, a pinch) the whole gesture collapses into a single entry.
    func apply(_ mutate: (inout BitarfDocument) -> Void) {
        if interactionSnapshot == nil {
            pushUndo(document)
        }
        mutate(&document)
        document.reflow()
        touch()
    }

    func updateObject(_ id: UUID, _ mutate: (inout CanvasObject) -> Void) {
        apply { document in
            guard let index = document.index(of: id) else { return }
            mutate(&document.objects[index])
        }
    }

    /// Rewrite a text object's rich text from outside the live editor, telling
    /// the canvas to reload the text view rather than let it commit stale text.
    func updateRichText(_ id: UUID, _ mutate: (inout RichText) -> Void) {
        let cells = formattingCells(for: id)
        updateObject(id) { object in
            switch object.content {
            case .text(var rich):
                mutate(&rich)
                object.content = .text(rich)
            case .table(var table):
                if let targets = cells {
                    // Editing one cell, or a block picked out on the canvas:
                    // those cells and no others.
                    for address in targets where table.contains(address) {
                        var rich = table.rows[address.row][address.column]
                        mutate(&rich)
                        table.rows[address.row][address.column] = rich
                    }
                } else {
                    // Nothing is being edited and nothing is picked out, so the
                    // command was aimed at the table as a whole — which for a
                    // font or an alignment means every cell in it.
                    for row in table.rows.indices {
                        for column in table.rows[row].indices {
                            mutate(&table.rows[row][column])
                        }
                    }
                }
                object.content = .table(table)
            default:
                return
            }
        }
        liveTextRevision &+= 1
    }

    /// The cell a text command should land in: the one being edited, when it is
    /// this object's and still in range. Nil means "the whole object".
    func formattingCell(for id: UUID) -> TableCellAddress? {
        guard editingTextID == id, let cell = editingCell else { return nil }
        guard document[id]?.table?.contains(cell) == true else { return nil }
        return cell
    }

    /// The cells a text command should land in: the one being edited, or the
    /// block picked out on the canvas. Nil means "every cell in the table",
    /// which is what an untouched table still answers.
    func formattingCells(for id: UUID) -> [TableCellAddress]? {
        guard let table = document[id]?.table else { return nil }
        if let cell = formattingCell(for: id) { return [cell] }
        guard let range = tableRange(for: id) else { return nil }
        return range.cells
    }

    /// The block picked out on `id`, clamped to the table as it is now.
    ///
    /// Clamped on every read rather than repaired on every edit: rows and
    /// columns come and go from several places, and a selection that outlived
    /// one of them would be an out-of-range index at the next command.
    func tableRange(for id: UUID) -> TableCellRange? {
        guard selectedIDs == [id],
              let table = document[id]?.table,
              let range = tableSelection?.clamped(to: table) else { return nil }
        return range
    }

    /// The rich text the formatting controls are reading, for either kind of
    /// object.
    func formattingRichText(for id: UUID) -> RichText? {
        guard let object = document[id] else { return nil }
        if let rich = object.richText { return rich }
        guard let table = object.table else { return nil }
        if let cell = formattingCell(for: id) { return table[cell] }
        if let range = tableRange(for: id) { return table[range.topLeft] }
        return table.rows.first?.first
    }

    // MARK: - Table cell selection

    /// Point at one cell, starting a new block.
    func selectTableCell(_ id: UUID, _ address: TableCellAddress) {
        guard document[id]?.table?.contains(address) == true else { return }
        if selectedIDs != [id] { select(id) }
        tableSelection = TableCellRange(address)
    }

    /// Drag one end of the block to `address`.
    func extendTableSelection(_ id: UUID, to address: TableCellAddress, fromAnchorEnd: Bool = false) {
        guard let table = document[id]?.table, table.contains(address) else { return }
        let current = tableSelection?.clamped(to: table) ?? TableCellRange(address)
        tableSelection = fromAnchorEnd
            ? current.extendedFromOpposite(to: address)
            : current.extended(to: address)
    }

    func selectTableRow(_ id: UUID, _ row: Int) {
        guard let table = document[id]?.table, row >= 0, row < table.rowCount else { return }
        if selectedIDs != [id] { select(id) }
        tableSelection = .row(row, in: table)
    }

    func selectTableColumn(_ id: UUID, _ column: Int) {
        guard let table = document[id]?.table, column >= 0, column < table.columnCount else { return }
        if selectedIDs != [id] { select(id) }
        tableSelection = .column(column, in: table)
    }

    /// What the structure commands act on when nothing is being edited and
    /// nothing has been pointed at: the last cell, so the buttons always mean
    /// something.
    func tableCommandRange(for id: UUID) -> TableCellRange? {
        guard let table = document[id]?.table else { return nil }
        if let cell = formattingCell(for: id) { return TableCellRange(cell) }
        if let range = tableRange(for: id) { return range }
        return TableCellRange(TableCellAddress(row: table.rowCount - 1, column: table.columnCount - 1))
    }

    /// Begin a continuous gesture. Everything until `endInteraction` becomes one
    /// undo step.
    func beginInteraction() {
        guard interactionSnapshot == nil else { return }
        interactionSnapshot = document
    }

    func endInteraction() {
        guard let snapshot = interactionSnapshot else { return }
        interactionSnapshot = nil
        if snapshot != document {
            pushUndo(snapshot)
            touch()
        }
    }

    /// Replace the whole document — new file, import, orientation change.
    func replaceDocument(_ new: BitarfDocument, recordUndo: Bool = true) {
        if recordUndo { pushUndo(document) }
        document = new
        document.reflow()
        selectedIDs.formIntersection(Set(document.objects.map(\.id)))
        isSelectionMode = false
        editingTextID = nil
        liveTextRevision &+= 1
        touch()
    }

    // MARK: - Undo / redo

    private func pushUndo(_ snapshot: BitarfDocument) {
        undoStack.append(snapshot)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        clampSelection()
        refreshUndoFlags()
        touch()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        clampSelection()
        refreshUndoFlags()
        touch()
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func clampSelection() {
        // Intersect rather than test each id against the document: undo can drop
        // any number of objects at once, and doing that by lookup is quadratic
        // in a document that only ever grows.
        let surviving = Set(document.objects.map(\.id))
        if !selectedIDs.isSubset(of: surviving) {
            selectedIDs.formIntersection(surviving)
        }
        editingTextID = nil
        // Undo lands here too: the text view that was up is now holding a string
        // from a version of the document that no longer exists, and must not be
        // allowed to commit it back.
        liveTextRevision &+= 1
    }

    // MARK: - Selection

    /// The character range a format command should act on, or nil when it
    /// should act on the whole object.
    ///
    /// Only a *non-empty* selection inside the box being edited counts. A bare
    /// caret is not a range, and treating it as one would mean either doing
    /// nothing visible or restyling everything — both wrong for the same tap.
    var formattingRange: Range<Int>? {
        guard editingTextID != nil,
              let range = textSelection,
              range.length > 0 else { return nil }
        return range.lowerBound..<range.upperBound
    }

    var selectedObject: CanvasObject? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return document[id]
    }

    /// The run style the formatting controls should display for this object.
    /// Both the SwiftUI format panel and the UIKit keyboard accessory ask here,
    /// so selection handling cannot drift between the two surfaces.
    func formattingRunStyle(for id: UUID) -> RunStyle? {
        guard let rich = formattingRichText(for: id) else { return nil }
        guard editingTextID == id, let range = formattingRange else { return rich.leadingRunStyle }
        return rich.runStyle(in: range)
    }

    /// Apply character formatting to the selected characters, or to every run
    /// in the text box when there is no non-empty text selection.
    func updateFormattingRunStyle(
        for id: UUID,
        _ transform: (inout RunStyle) -> Void
    ) {
        updateRichText(id) { rich in
            if editingTextID == id, let range = formattingRange {
                rich.applyRunStyle(in: range, transform)
                return
            }
            for paragraphIndex in rich.paragraphs.indices {
                for runIndex in rich.paragraphs[paragraphIndex].runs.indices {
                    transform(&rich.paragraphs[paragraphIndex].runs[runIndex].style)
                }
                if rich.paragraphs[paragraphIndex].runs.isEmpty {
                    var seed = RunStyle.default
                    transform(&seed)
                    rich.paragraphs[paragraphIndex].runs = [TextRun(text: "", style: seed)]
                }
            }
        }
    }

    /// The paragraph style the formatting controls should display — the same
    /// selection rules the run style follows, so the accessory and the format
    /// sheet cannot disagree about which line they are talking about.
    func formattingParagraphStyle(for id: UUID) -> ParagraphStyle? {
        guard let rich = formattingRichText(for: id) else { return nil }
        guard editingTextID == id, let range = formattingRange ?? textSelection.map({ $0.lowerBound..<$0.upperBound }) else {
            return rich.leadingParagraphStyle
        }
        return rich.paragraphStyle(in: range)
    }

    /// Apply paragraph formatting to the lines the selection touches, or to
    /// every paragraph when nothing is selected.
    func updateFormattingParagraphStyle(
        for id: UUID,
        _ transform: (inout ParagraphStyle) -> Void
    ) {
        updateRichText(id) { rich in
            if editingTextID == id,
               let range = formattingRange ?? textSelection.map({ $0.lowerBound..<$0.upperBound }) {
                rich.applyParagraphStyle(in: range, transform)
                return
            }
            for index in rich.paragraphs.indices {
                transform(&rich.paragraphs[index].style)
            }
        }
    }

    func select(_ id: UUID?) {
        setSelection(id.map { [$0] } ?? [])
    }

    /// The one place the selection is written.
    ///
    /// A box being edited survives only while it *is* the whole selection: the
    /// moment anything joins it, the live text view is holding a caret in a
    /// document the user has stopped looking at.
    func setSelection(_ ids: Set<UUID>) {
        if let editingTextID, ids != [editingTextID] {
            self.editingTextID = nil
        }
        if ids != selectedIDs { tableSelection = nil }
        selectedIDs = ids
    }

    func toggleSelection(_ id: UUID) {
        var ids = selectedIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        setSelection(ids)
    }

    /// Everything the canvas can actually act on. Locked and hidden objects stay
    /// out: an operation that silently skipped half of what it claimed to have
    /// selected would be worse than one that never claimed them.
    var selectableIDs: Set<UUID> {
        Set(document.objects.filter { !$0.isLocked && !$0.isHidden }.map(\.id))
    }

    /// True only when everything that *can* be picked already is. An empty
    /// canvas is not "all selected" — there would be nothing to undo.
    var isEverythingSelected: Bool {
        let selectable = selectableIDs
        return !selectable.isEmpty && selectedIDs == selectable
    }

    func selectAll() {
        setSelection(selectableIDs)
    }

    /// Three states, three glyphs — the checklist family draws all of them, so
    /// a set of two out of five need not look like a set of five.
    ///
    /// It lives here rather than in either bar because both bars show it, and a
    /// glyph that disagreed with itself across two screens would be worse than
    /// no glyph. `CanvasObject.symbolName` sets the precedent.
    var selectAllSymbolName: String {
        if selectedIDs.isEmpty { return "checklist.unchecked" }
        return isEverythingSelected ? "checklist.checked" : "checklist"
    }

    /// One button for both directions: a second press on 全選 is the only way
    /// back out of it that does not also leave 選取模式.
    func toggleSelectAll() {
        if isEverythingSelected {
            setSelection([])
        } else {
            selectAll()
        }
    }

    // MARK: - Selection mode

    /// Open 選取模式 around the object whose edit menu was raised.
    func enterSelectionMode(seededWith id: UUID) {
        editingTextID = nil
        isSelectionMode = true
        setSelection([id])
    }

    /// Opening 選取模式 around a set that already exists — the layer list is a
    /// checklist whether or not the mode is on, so ticking a second row there is
    /// itself the request to be in it.
    func enterSelectionMode(with ids: Set<UUID>) {
        editingTextID = nil
        isSelectionMode = true
        setSelection(ids)
    }

    /// The checkmark in the top-left corner. That this clears the selection is
    /// the whole reason the selection needs no other way to be emptied — and why
    /// a stray tap on empty paper is allowed to do nothing.
    func exitSelectionMode() {
        isSelectionMode = false
        setSelection([])
    }

    // MARK: - Object creation

    /// Place a new object in the middle of what the user is currently looking at,
    /// not at one fixed spot on a two-metre canvas — which is what made every
    /// new object land on top of the last one.
    ///
    /// The region is the visible rectangle clipped to the paper, so scrolling
    /// past either end still centres on paper rather than on the grey around it.
    /// An empty rectangle means nobody has reported a viewport yet: fall back to
    /// the whole canvas, which is what the first object on a fresh document gets.
    private func insertionOrigin(size: CGSize, visibleRect: CGRect) -> DotPoint {
        let canvas = CGRect(x: 0, y: 0, width: document.canvasWidth, height: document.canvasHeight)
        let clipped = visibleRect.intersection(canvas)
        let region = (clipped.width > 1 && clipped.height > 1) ? clipped : canvas
        return DotPoint(
            x: placed(region.midX - size.width / 2, extent: size.width, within: document.canvasWidth),
            y: placed(region.midY - size.height / 2, extent: size.height, within: document.canvasHeight)
        )
    }

    /// Keep one axis of a new object inside the margins — unless it is wider
    /// than the space between them, in which case the margin itself is the best
    /// we can do and the object simply runs long.
    private func placed(_ value: CGFloat, extent: CGFloat, within axis: CGFloat) -> CGFloat {
        let lower = document.margin
        let upper = axis - document.margin - extent
        guard upper > lower else { return lower }
        return min(max(value, lower), upper).rounded()
    }

    @discardableResult
    func addTextBox(visibleRect: CGRect = .zero) -> UUID {
        let width = defaultObjectWidth
        let rich = RichText(text: "", runStyle: RunStyle(fontSize: 26))
        let height = TextLayoutEngine.measureHeight(rich, width: width)
        let object = CanvasObject(
            origin: insertionOrigin(size: CGSize(width: width, height: height), visibleRect: visibleRect),
            size: DotSize(width: width, height: height),
            content: .text(rich)
        )
        apply { $0.objects.append(object) }
        select(object.id)
        editingTextID = object.id
        return object.id
    }

    /// Drop a 3 × 3 table and put the caret in its first cell.
    ///
    /// Like a text box: the width is the paper's, and the height is whatever the
    /// rows measure to — `apply` reflows, so the size below is only a seed.
    @discardableResult
    func addTable(visibleRect: CGRect = .zero) -> UUID {
        let width = defaultObjectWidth
        let content = TableContent()
        let height = TableLayout.totalHeight(content, width: width)
        let object = CanvasObject(
            origin: insertionOrigin(size: CGSize(width: width, height: height), visibleRect: visibleRect),
            size: DotSize(width: width, height: height),
            content: .table(content)
        )
        apply { $0.objects.append(object) }
        select(object.id)
        editingTextID = object.id
        editingCell = TableCellAddress(row: 0, column: 0)
        return object.id
    }

    // MARK: - Table structure

    /// Every structural edit goes through here, so each one is a single undo
    /// step and the object is reflowed to its new height on the way out.
    private func updateTable(_ id: UUID, _ mutate: (inout TableContent) -> Void) {
        updateObject(id) { object in
            guard case .table(var content) = object.content else { return }
            mutate(&content)
            content.normalize()
            object.content = .table(content)
        }
        liveTextRevision &+= 1
    }

    /// One row, for the caret walking off the end of the table. Everything the
    /// panel offers goes through the range commands below instead.
    func insertTableRow(_ id: UUID, at index: Int) {
        updateTable(id) { $0.insertRow(at: index) }
    }

    // MARK: Range commands

    /// Insert `count` rows at `index` as one undo step. A block of three rows
    /// selected means "three more rows", the way every table editor answers it.
    func insertTableRows(_ id: UUID, at index: Int, count: Int) {
        guard count > 0 else { return }
        updateTable(id) { content in
            for offset in 0..<count {
                content.insertRow(at: index + offset)
            }
        }
        if let table = document[id]?.table, let range = tableSelection?.clamped(to: table) {
            tableSelection = range
        }
    }

    func removeTableRows(_ id: UUID, _ rows: ClosedRange<Int>) {
        guard let table = document[id]?.table else { return }
        let count = rows.count
        guard table.rowCount > count else {
            statusMessage = "表格至少要有一列"
            return
        }
        if let cell = editingCell, rows.contains(cell.row) { editingTextID = nil }
        updateTable(id) { content in
            for row in rows.reversed() {
                content.removeRow(at: row)
            }
        }
        collapseTableSelection(id, toRow: rows.lowerBound)
    }

    func insertTableColumns(_ id: UUID, at index: Int, count: Int) {
        guard count > 0 else { return }
        updateTable(id) { content in
            for offset in 0..<count {
                content.insertColumn(at: index + offset)
            }
        }
        if let table = document[id]?.table, let range = tableSelection?.clamped(to: table) {
            tableSelection = range
        }
    }

    func removeTableColumns(_ id: UUID, _ columns: ClosedRange<Int>) {
        guard let table = document[id]?.table else { return }
        let count = columns.count
        guard table.columnCount > count else {
            statusMessage = "表格至少要有一欄"
            return
        }
        if let cell = editingCell, columns.contains(cell.column) { editingTextID = nil }
        updateTable(id) { content in
            for column in columns.reversed() {
                content.removeColumn(at: column)
            }
        }
        collapseTableSelection(id, toColumn: columns.lowerBound)
    }

    /// After a delete the block has to land somewhere real: the cell that took
    /// the removed one's place, or the new last one.
    private func collapseTableSelection(_ id: UUID, toRow row: Int? = nil, toColumn column: Int? = nil) {
        guard let table = document[id]?.table, tableSelection != nil else { return }
        let target = TableCellAddress(
            row: min(row ?? tableSelection?.topLeft.row ?? 0, table.rowCount - 1),
            column: min(column ?? tableSelection?.topLeft.column ?? 0, table.columnCount - 1)
        )
        tableSelection = TableCellRange(target).clamped(to: table)
    }

    /// Pin a row's height, or hand it back to its text with nil.
    func setTableRowHeight(_ id: UUID, row: Int, height: CGFloat?) {
        updateTable(id) { $0.setRowHeight(row, to: height) }
    }

    func clearTableRowHeights(_ id: UUID) {
        updateTable(id) { $0.clearRowHeights() }
    }

    func equalizeTableColumns(_ id: UUID) {
        updateTable(id) { $0.equalizeColumns() }
    }

    /// Set one column's width in dots, taking the difference from its
    /// neighbour so the table's own width does not move.
    func setTableColumnWidth(_ id: UUID, column: Int, width: CGFloat) {
        guard let object = document[id], let content = object.table else { return }
        let current = TableLayout.columnWidths(content, width: object.size.width)
        guard column >= 0, column < current.count else { return }
        // The rule to the right of a column is the one that moves it; the last
        // column has none, so it borrows the rule on its left instead.
        let divider = column == content.columnCount - 1 ? column - 1 : column
        guard divider >= 0 else { return }
        let delta = column == divider ? width - current[column] : current[column] - width
        updateTable(id) { content in
            content = TableLayout.resizingColumns(
                content,
                divider: divider,
                by: delta,
                width: object.size.width
            )
        }
    }

    /// Set the alignment of every column the block touches.
    func setTableColumnsAlignment(_ id: UUID, columns: ClosedRange<Int>, alignment: TextAlignment) {
        updateTable(id) { content in
            for column in columns where column >= 0 && column < content.columnCount {
                content.columns[column].alignment = alignment
            }
        }
    }

    func setTableBorderStyle(_ id: UUID, _ style: TableBorderStyle) {
        updateTable(id) { $0.borderStyle = style }
    }

    func setTableBorderWidth(_ id: UUID, _ width: CGFloat) {
        updateTable(id) { $0.borderWidth = max(0, width) }
    }

    func setTableCellPadding(_ id: UUID, _ padding: CGFloat) {
        updateTable(id) { $0.cellPadding = max(0, padding) }
    }

    /// Move the caret to the next (or previous) cell, reading order. Tabbing
    /// off the last cell adds a row, the way every table anyone has used does.
    func advanceEditingCell(reverse: Bool = false) {
        guard let id = editingTextID,
              let cell = editingCell,
              let content = document[id]?.table else { return }

        var index = cell.row * content.columnCount + cell.column + (reverse ? -1 : 1)
        if index < 0 { return }
        if index >= content.rowCount * content.columnCount {
            guard !reverse else { return }
            insertTableRow(id, at: content.rowCount)
            index = content.rowCount * content.columnCount
        }
        let columns = (document[id]?.table?.columnCount ?? content.columnCount)
        editingCell = TableCellAddress(row: index / columns, column: index % columns)
        textSelection = nil
    }

    /// One column to the right, staying on this row.
    ///
    /// Deliberately not 下一格: it never wraps to the next row and never grows
    /// the table, so filling a row across cannot run off the end into a row the
    /// user did not ask for. At the last column it does nothing.
    func moveEditingCellRight() {
        guard let id = editingTextID,
              let cell = editingCell,
              let content = document[id]?.table else { return }
        guard cell.column + 1 < content.columnCount else { return }
        editingCell = TableCellAddress(row: cell.row, column: cell.column + 1)
        textSelection = nil
    }

    @discardableResult
    func addShape(_ kind: ShapeKind, visibleRect: CGRect = .zero) -> UUID {
        let size: CGSize
        switch kind {
        case .rectangle: size = CGSize(width: defaultObjectWidth, height: 120)
        case .ellipse: size = CGSize(width: 160, height: 160)
        case .line: size = CGSize(width: defaultObjectWidth, height: 4)
        }
        let content = ShapeContent(
            kind: kind,
            strokeWidth: kind == .line ? 3 : 2,
            filled: false
        )
        let object = CanvasObject(
            origin: insertionOrigin(size: size, visibleRect: visibleRect),
            size: DotSize(size),
            content: .shape(content)
        )
        apply { $0.objects.append(object) }
        select(object.id)
        return object.id
    }

    @discardableResult
    func addImage(_ image: UIImage, visibleRect: CGRect = .zero) -> UUID? {
        guard let source = image.cgImage else {
            statusMessage = "載入圖片失敗"
            return nil
        }
        // 此處應插入經典機型輸出尺寸衍生的匯入影像降採樣上限。
        let cgImage = source
        guard let png = UIImage(cgImage: cgImage).pngData() else {
            statusMessage = "載入圖片失敗"
            return nil
        }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        // Scale to the canvas rather than to the photo's own pixel count.
        // 此處應插入經典機型列印頭寬度對影像縮放的理由。
        let maxWidth = defaultObjectWidth
        let scale = min(1, maxWidth / max(pixelSize.width, 1))
        let size = CGSize(
            width: max(8, (pixelSize.width * scale).rounded()),
            height: max(8, (pixelSize.height * scale).rounded())
        )
        let object = CanvasObject(
            origin: insertionOrigin(size: size, visibleRect: visibleRect),
            size: DotSize(size),
            content: .image(ImageContent(pngData: png, pixelSize: DotSize(pixelSize)))
        )
        apply { $0.objects.append(object) }
        select(object.id)
        return object.id
    }

    /// Drop imported vector artwork on the canvas at the content width.
    ///
    /// Unlike an image there is no pixel count to respect — the artwork has no
    /// native resolution — so it always arrives as wide as the paper allows and
    /// keeps its own proportions from there.
    @discardableResult
    func addVector(_ content: VectorContent, visibleRect: CGRect = .zero) -> UUID? {
        let intrinsic = content.intrinsicSize
        guard intrinsic.width > 0, intrinsic.height > 0 else {
            statusMessage = "這個向量沒有尺寸"
            return nil
        }
        let width = defaultObjectWidth
        let size = CGSize(
            width: max(8, width.rounded()),
            height: max(8, (width * intrinsic.height / intrinsic.width).rounded())
        )
        let object = CanvasObject(
            origin: insertionOrigin(size: size, visibleRect: visibleRect),
            size: DotSize(size),
            content: .vector(content)
        )
        apply { $0.objects.append(object) }
        select(object.id)
        return object.id
    }

    // 此處應插入經典機型固定軸上限所衍生的影像儲存寬度。

    /// `image` scaled so it is no wider than `maxWidth`, or itself if it already
    /// fits.
    private static func downsampled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth, image.width > 0, image.height > 0 else { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let width = maxWidth
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: width, height: height)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage ?? image
    }

    private var defaultObjectWidth: CGFloat {
        let axis = document.orientation.isPortrait ? document.canvasWidth : document.canvasHeight
        return max(32, axis - document.margin * 2)
    }

    // MARK: - Object operations

    func delete(_ id: UUID) {
        apply { document in
            document.objects.removeAll { $0.id == id }
        }
        // Not `selectedID = nil`: the layer list can delete one row out of
        // several that are selected, and the rest must stay selected.
        var remaining = selectedIDs
        remaining.remove(id)
        setSelection(remaining)
        if editingTextID == id { editingTextID = nil }
    }

    func duplicate(_ id: UUID) {
        guard var copy = document[id] else { return }
        copy.id = UUID()
        copy.origin = DotPoint(x: copy.origin.x + 12, y: copy.origin.y + 12)
        apply { $0.objects.append(copy) }
        select(copy.id)
    }

    /// Put one complete canvas object on the system pasteboard. Encoding is
    /// deliberately all-or-nothing: cutting must never remove an object that
    /// failed to reach the pasteboard.
    @discardableResult
    func copyObject(_ id: UUID) -> Bool {
        guard let object = document[id],
              let data = try? JSONEncoder().encode(object) else { return false }
        UIPasteboard.general.setData(data, forPasteboardType: Self.objectPasteboardType)
        return true
    }

    @discardableResult
    func cutObject(_ id: UUID) -> Bool {
        guard copyObject(id) else { return false }
        delete(id)
        return true
    }

    var canPasteObject: Bool {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.objectPasteboardType) else { return false }
        return (try? JSONDecoder().decode(CanvasObject.self, from: data)) != nil
    }

    /// Paste always creates a new identity and offsets it from its source so it
    /// is visible immediately rather than precisely covering the copied object.
    @discardableResult
    func pasteObject() -> CanvasObject? {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.objectPasteboardType),
              var object = try? JSONDecoder().decode(CanvasObject.self, from: data) else { return nil }
        object.id = UUID()
        object.origin = DotPoint(x: object.origin.x + 12, y: object.origin.y + 12)
        apply { $0.objects.append(object) }
        select(object.id)
        return object
    }

    func bringToFront(_ id: UUID) { apply { $0.bringToFront(id) } }
    func sendToBack(_ id: UUID) { apply { $0.sendToBack(id) } }
    func bringForward(_ id: UUID) { apply { $0.bringForward(id) } }
    func sendBackward(_ id: UUID) { apply { $0.sendBackward(id) } }

    // MARK: - Object operations on a selection

    // Every one of these mutates the whole set in a *single* `apply`.
    //
    // That is not tidiness. `apply` reflows the entire document — it re-measures
    // every text box in it — so calling `updateObject` once per member during a
    // drag would cost members × text-boxes TextKit layouts on every frame. One
    // `apply` per frame is the budget.

    func deleteSelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        apply { document in
            document.objects.removeAll { ids.contains($0.id) }
        }
        if let editingTextID, ids.contains(editingTextID) { self.editingTextID = nil }
        setSelection([])
    }

    /// Copies are appended in document order, so a caption that sat above its
    /// rule still does. Selection follows the copies, matching what duplicating
    /// a single object has always done.
    func duplicateSelection() {
        let originals = selectedObjects
        guard !originals.isEmpty else { return }

        let copies = originals.map { original -> CanvasObject in
            var copy = original
            copy.id = UUID()
            copy.origin = DotPoint(x: copy.origin.x + 12, y: copy.origin.y + 12)
            return copy
        }
        apply { $0.objects.append(contentsOf: copies) }
        setSelection(Set(copies.map(\.id)))
    }

    /// Move every unlocked member by the same offset, from the origins captured
    /// when the drag began.
    ///
    /// Absolute rather than incremental, for the same reason the rotation is:
    /// origins are whole dots, and re-rounding a delta every frame lets the
    /// error walk.
    func moveSelection(from starts: [UUID: CGPoint], by offset: CGPoint) {
        guard !starts.isEmpty else { return }
        apply { document in
            for (id, start) in starts {
                guard let index = document.index(of: id), !document.objects[index].isLocked else { continue }
                document.objects[index].origin = DotPoint(
                    x: (start.x + offset.x).rounded(),
                    y: (start.y + offset.y).rounded()
                )
            }
        }
    }

    /// Turn the whole selection about `centre`, from the objects captured when
    /// the gesture began. `centre` has to have been captured once as well — see
    /// the note on `SelectionGeometry.rotated`.
    func rotateSelection(by delta: CGFloat, about centre: CGPoint, from starts: [CanvasObject]) {
        guard !starts.isEmpty else { return }
        let turned = SelectionGeometry.rotated(starts, by: delta, about: centre)
        replaceObjects(turned)
    }

    func alignSelection(_ edge: AlignmentEdge, within bounds: CGRect? = nil, asGroup: Bool = false) {
        let members = selectedObjects
        guard members.count > 1 || bounds != nil else { return }
        replaceObjects(AlignmentEngine.aligned(members, to: edge, within: bounds, asGroup: asGroup))
    }

    func distributeSelection(_ axis: DistributionAxis) {
        let members = selectedObjects
        guard members.count >= 3 else { return }
        replaceObjects(AlignmentEngine.distributed(members, along: axis))
    }

    private func replaceObjects(_ updated: [CanvasObject]) {
        apply { document in
            for object in updated {
                guard let index = document.index(of: object.id) else { continue }
                document.objects[index] = object
            }
        }
    }

    func bringSelectionToFront() { applyToSelection { $0.bringToFront($1) } }
    func sendSelectionToBack() { applyToSelection { $0.sendToBack($1) } }
    func bringSelectionForward() { applyToSelection { $0.bringForward($1) } }
    func sendSelectionBackward() { applyToSelection { $0.sendBackward($1) } }

    private func applyToSelection(_ mutate: (inout BitarfDocument, Set<UUID>) -> Void) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        apply { mutate(&$0, ids) }
    }

    /// Lock or hide every member at once. A mixed set reads as off, so the first
    /// tap turns the whole selection on rather than inverting each member —
    /// inverting would leave the set in the mixed state it started in.
    func setSelectionLocked(_ locked: Bool) {
        mutateSelection { $0.isLocked = locked }
    }

    func setSelectionHidden(_ hidden: Bool) {
        mutateSelection { $0.isHidden = hidden }
    }

    private func mutateSelection(_ mutate: (inout CanvasObject) -> Void) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        apply { document in
            for index in document.objects.indices where ids.contains(document.objects[index].id) {
                mutate(&document.objects[index])
            }
        }
    }

    /// Fit a text box's width to its longest natural line, keeping its left edge.
    func shrinkTextToFit(_ id: UUID) {
        guard let object = document[id], let rich = object.richText else { return }
        let maximum = defaultObjectWidth
        let width = max(24, TextLayoutEngine.measureNaturalWidth(rich, maximum: maximum))
        updateObject(id) { $0.size.width = width }
    }

    // MARK: - Document settings

    func setOrientation(_ orientation: CanvasOrientation) {
        guard orientation != document.orientation else { return }
        apply { document in
            document.orientation = orientation
            // Objects keep their coordinates; anything now hanging off the fixed
            // axis is nudged back on, because an object outside the paper simply
            // will not print and silently losing it would be worse than moving it.
            let fixed = CGFloat(document.fixedAxisDots)
            for index in document.objects.indices {
                if orientation.isPortrait {
                    let maxX = max(0, fixed - document.objects[index].size.width)
                    document.objects[index].origin.x = min(document.objects[index].origin.x, maxX)
                } else {
                    let maxY = max(0, fixed - document.objects[index].size.height)
                    document.objects[index].origin.y = min(document.objects[index].origin.y, maxY)
                }
            }
        }
    }

    // 此處應插入經典機型固定軸範圍的設定操作。

    func setDither(_ algorithm: DitherAlgorithm) {
        apply { $0.dither = algorithm }
    }

    func setThreshold(_ threshold: Int) {
        apply { $0.threshold = UInt8(min(max(threshold, 1), 254)) }
    }

    // 此處應插入經典機型濃度與尾端走紙範圍的設定操作。

    func setMargin(_ margin: CGFloat) {
        apply { $0.margin = min(max(margin, 0), 64) }
    }

    func setTitle(_ title: String) {
        apply { $0.title = title }
    }

    /// Start over on a blank canvas.
    ///
    /// The work being left behind is only dropped when it is either empty or
    /// already in the library; anything else is filed as 未完成 first, because
    /// the user asked for a new document, not to destroy the old one.
    func newDocument() {
        let stashed = stashUncommittedWork()
        open(DocumentDefaults.applied(to: BitarfDocument.starter()))
        if stashed {
            statusMessage = "最近的編輯已保留在「最近」標籤頁"
        }
    }

    /// Put uncommitted, non-empty work somewhere it can be found again.
    /// Returns true if something was filed.
    ///
    /// What was printed is not excluded — only the printed version is. Editing
    /// after a print turns `isCommitted` back off, and what is on the canvas by
    /// then is no longer the thing in 列印歷史: it is unfinished work again, and
    /// 最近 is where unfinished work lives.
    @discardableResult
    func stashUncommittedWork() -> Bool {
        guard hasBeenEdited, hasContent, !isCommitted else { return false }
        do {
            // Same work, same row: a document that has already been filed once
            // is updated in place rather than added again.
            let id = recoveredID ?? UUID()
            try library.saveRecovered(document, id: id)
            recoveredID = id
            isCommitted = true
            return true
        } catch {
            statusMessage = "無法保留未完成的內容：\(error.localizedDescription)"
            return false
        }
    }

    /// Empty the canvas but keep the document's own settings — paper width,
    /// dither, density, margin, title. Swapping what you print is the common
    /// case; re-choosing the printing settings every time is not.
    func clearAll() {
        guard !document.objects.isEmpty else {
            statusMessage = "畫布上沒有物件"
            return
        }
        var cleared = document
        cleared.objects.removeAll()
        replaceDocument(cleared)
        statusMessage = "已清除全部物件"
    }

    // MARK: - Persistence

    /// Is there anything here worth not losing?
    var hasContent: Bool { document.hasPrintableContent }

    /// Write the work in progress to the scratch slot.
    ///
    /// This is the only automatic write in the app, and it never produces a
    /// document the user has to manage: the scratch slot is a single file that
    /// appears in no list. Committing is what puts something in the library.
    func save() {
        do {
            try library.writeScratch(document, state: DocumentLibrary.ScratchState(
                isCommitted: isCommitted,
                hasBeenEdited: hasBeenEdited,
                sourceTemplateID: sourceTemplateID,
                recoveredID: recoveredID,
                uncleanLaunches: uncleanLaunches
            ))
        } catch {
            statusMessage = "自動儲存失敗：\(error.localizedDescription)"
        }
    }

    /// Note that this document reached the paper. Called by the print sheet the
    /// moment the raster has been handed over.
    func recordPrint() {
        do {
            try library.recordPrint(document)
            isCommitted = true
            // This version has moved lists: the 未完成 row it came from is a
            // stale copy of what is now filed under 列印歷史, so it goes. Edits
            // made *after* this point are a different thing again, and they get
            // a 最近 row of their own on the way out.
            if let recoveredID {
                library.delete(recoveredID)
                self.recoveredID = nil
            }
            save()
        } catch {
            statusMessage = "寫入列印歷史失敗：\(error.localizedDescription)"
        }
    }

    /// Keep this document to print again.
    func saveAsTemplate() {
        do {
            let entry = try library.saveTemplate(document)
            sourceTemplateID = entry.id
            isCommitted = true
            save()
            statusMessage = "已存成範本「\(entry.title)」"
        } catch {
            statusMessage = "儲存範本失敗：\(error.localizedDescription)"
        }
    }

    /// Write the edits back onto the template this document was opened from.
    func updateSourceTemplate() {
        guard let sourceTemplateID else { return }
        do {
            let entry = try library.saveTemplate(document, id: sourceTemplateID)
            isCommitted = true
            save()
            statusMessage = "已更新範本「\(entry.title)」"
        } catch {
            statusMessage = "更新範本失敗：\(error.localizedDescription)"
        }
    }

    var canUpdateSourceTemplate: Bool { sourceTemplateID != nil }

    /// Abandon the work in progress — the user asked for a new document, or
    /// walked away from an empty canvas.
    func discardScratch() {
        library.clearScratch()
    }

    func exportDocumentFile() throws -> URL {
        try store.writeExport(document)
    }

    /// Returns whether the file actually became the open document, so a caller
    /// that was about to show the editor can stay where it is instead of
    /// covering the screen with the document the user was not asking for.
    @discardableResult
    func importDocument(from url: URL) -> Bool {
        do {
            let imported = try store.read(from: url)
            open(imported)
            return true
        } catch {
            statusMessage = "無法開啟這個檔案：\(error.localizedDescription)"
            return false
        }
    }
}
