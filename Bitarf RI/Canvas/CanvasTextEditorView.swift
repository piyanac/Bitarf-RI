//
//  CanvasTextEditorView.swift
//  Bitarf RI
//
//  The live editor for one text box.
//
//  It is a plain `UITextView` on purpose. The alternative — a custom Core Text
//  editor, or contenteditable in a web view — costs the system Chinese IME,
//  which is the single thing this app cannot afford to get wrong.
//
//  The view works in *dot* units and is scaled by an affine transform, so
//  TextKit lays out against exactly the metrics `TextLayoutEngine` will use when
//  the same string is measured for the model and rasterised for the paper.
//

import UIKit

final class CanvasTextEditorView: UITextView {

    let objectID: UUID

    /// Which cell of `objectID`'s table this session is editing, or nil when the
    /// object is a plain text box. Identity only — the view itself does not know
    /// anything else about tables.
    let cell: TableCellAddress?

    var onChange: ((NSAttributedString) -> Void)?
    var onFinish: (() -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?
    var onRequestFontPicker: (() -> Void)?
    var onRequestSizePicker: ((UIBarButtonItem) -> Void)?
    var onSetBold: ((Bool) -> Void)?
    var onSetItalic: ((Bool) -> Void)?
    var onSetUnderline: ((Bool) -> Void)?
    var onSetLanguageTag: ((String?) -> Void)?
    /// Pick one face of the current family — the font file's own weights, not
    /// a synthesised one.
    var onSetFontName: ((String) -> Void)?
    var onSetAlignment: ((TextAlignment) -> Void)?
    /// Move to the next cell, or the previous one when the flag is true.
    var onAdvanceCell: ((Bool) -> Void)?
    /// Move one column right without leaving the row.
    var onMoveCellRight: (() -> Void)?

    private weak var styleItem: UIBarButtonItem?
    private weak var variantsItem: UIBarButtonItem?
    private weak var weightItem: UIBarButtonItem?
    private weak var alignItem: UIBarButtonItem?
    private weak var advanceItem: UIBarButtonItem?

    /// The two ways forward through a table. Only one is on the bar at a time:
    /// the other waits in the button's long-press menu, and picking it there
    /// both moves the caret and takes the button over, so the move the user
    /// just chose is the one a plain tap repeats.
    private enum CellAdvance {
        case right, next

        var title: String {
            switch self {
            case .right: return "往右一格"
            case .next: return "下一格"
            }
        }

        var symbolName: String {
            switch self {
            case .right: return "chevron.right"
            case .next: return "arrow.turn.down.right"
            }
        }

        var other: CellAdvance { self == .right ? .next : .right }
    }

    private var cellAdvance: CellAdvance = .right

    /// UIKit has no placeholder API for `UITextView`. This label is deliberately
    /// a sibling of TextKit's content rather than a character in its storage, so
    /// it can never leak into the model, undo history, export, or marked text.
    private let placeholderLabel = UILabel()

    /// The accessory is part of the text-input system, not the canvas render
    /// tree. Keep its UIKit objects stable and only rebuild their menus when
    /// the formatting state actually changes; replacing a toolbar menu during
    /// every SwiftUI representable update feeds keyboard layout back into the
    /// update that caused it.
    private struct FormattingControlsState: Equatable {
        var style: RunStyle
        var supportsRegionalVariants: Bool
        var alignment: TextAlignment
    }

    private var formattingControlsState: FormattingControlsState?

    /// Set while a panel is being presented over the canvas. The text view has
    /// to give up first responder to the sheet, but that is not the user saying
    /// they are done — so the resignation must not end the editing session.
    var isYieldingToPanel = false

    /// True while `replaceContent` is rewriting the storage, so the selection
    /// churn that causes is not mistaken for the user moving the caret.
    private var isReplacingContent = false

    init(objectID: UUID, cell: TableCellAddress? = nil) {
        self.objectID = objectID
        self.cell = cell

        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // Zero padding and zero inset are what make TextKit's frame agree with
        // the Core Text frame the renderer builds; the default 5 pt padding
        // would shift every line by five dots on paper.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        super.init(frame: .zero, textContainer: container)

        textContainerInset = .zero
        isScrollEnabled = false
        // The paper is white in every appearance, so the editor's chrome has to
        // be pinned to its light-appearance colour. Left to inherit, the caret
        // and the selection highlight take the app accent, which is near-white
        // in dark mode and all but disappears against the page.
        tintColor = Self.editorTint
        backgroundColor = Self.editorTint.withAlphaComponent(0.04)
        layer.borderColor = Self.editorTint.withAlphaComponent(0.5).cgColor
        layer.borderWidth = 0.5
        autocorrectionType = .no
        spellCheckingType = .no
        // Smart punctuation rewrites straight quotes, which is a surprise when
        // the point of the document is exactly what gets printed.
        smartQuotesType = .no
        smartDashesType = .no
        delegate = self

        placeholderLabel.backgroundColor = .clear
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.numberOfLines = 0
        addSubview(placeholderLabel)

        installAccessory()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Push new content in from the model, keeping the caret where the user left
    /// it. Assigning `attributedText` does not call the delegate, so this cannot
    /// echo back out as a user edit.
    ///
    /// `typing` matters as much as the string does: after a replacement UIKit
    /// resets the typing attributes, and an empty box has no run for it to infer
    /// them from — the next character typed would come out in the system default
    /// rather than in the style the user just chose.
    func replaceContent(_ attributed: NSAttributedString, typing: [NSAttributedString.Key: Any]) {
        let previous = selectedRange
        // Assigning the storage walks the selection to zero and back, and each
        // step calls the delegate. Reporting those would publish a bogus
        // selection in the middle of a view update.
        isReplacingContent = true
        defer { isReplacingContent = false }
        attributedText = attributed
        let length = (attributed.string as NSString).length
        let location = min(previous.location, length)
        selectedRange = NSRange(location: location, length: min(previous.length, length - location))
        typingAttributes = typing
        updatePlaceholder(using: typing)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = bounds.inset(by: textContainerInset)
    }

    /// Match the style of the next real character while keeping the guidance
    /// visibly secondary. A marked IME string already has non-zero length, so
    /// the label disappears on the first composition update and returns only if
    /// that composition is cancelled back to an empty value.
    private func updatePlaceholder(using attributes: [NSAttributedString.Key: Any]? = nil) {
        var placeholderAttributes = attributes ?? typingAttributes
        placeholderAttributes[.foregroundColor] = UIColor.placeholderText.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        placeholderLabel.attributedText = NSAttributedString(
            string: CanvasRenderer.emptyTextPlaceholder,
            attributes: placeholderAttributes
        )
        placeholderLabel.isHidden = !text.isEmpty
    }

    /// The bar that rides above the keyboard while a box is being edited.
    ///
    /// It carries the four character controls used mid-sentence. Finishing
    /// lives in the navigation bar, while font, size, BIU and regional glyphs
    /// stay beside the keyboard and apply without a trip through a format sheet.
    ///
    /// A real `UIToolbar` owns the four items as one system surface. Keeping the
    /// items native also lets UIKit manage spacing, menus and accessibility as a
    /// single keyboard accessory instead of four unrelated floating buttons.
    private func installAccessory() {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.autoresizingMask = .flexibleWidth

        let fontItem = UIBarButtonItem(
            image: UIImage(systemName: "textformat"),
            style: .plain,
            target: self,
            action: #selector(requestFontPicker)
        )
        fontItem.accessibilityLabel = "字體"

        // The family is chosen by name in a picker; the weight is a property of
        // the file that family resolves to, so it gets its own control rather
        // than hiding inside the font sheet. A semibold "character" says which
        // axis the button moves without spelling out a weight name that only
        // applies to some families.
        let weightItem = UIBarButtonItem(
            image: UIImage(
                systemName: "character",
                withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
            ),
            menu: UIMenu()
        )
        weightItem.accessibilityLabel = "字重"
        self.weightItem = weightItem

        let sizeItem = UIBarButtonItem(
            image: UIImage(systemName: "textformat.size"),
            style: .plain,
            target: self,
            action: #selector(requestSizePicker(_:))
        )
        sizeItem.accessibilityLabel = "文字大小"

        let styleItem = UIBarButtonItem(image: UIImage(systemName: "bold.italic.underline"), menu: UIMenu())
        styleItem.accessibilityLabel = "粗體、斜體與底線"
        self.styleItem = styleItem

        // Four states, one button: the icon is the current alignment, and a tap
        // moves to the next. A four-way segmented control would cost more of a
        // 320-point bar than the setting is worth mid-sentence.
        let alignItem = UIBarButtonItem(
            image: UIImage(systemName: TextAlignment.left.symbolName),
            style: .plain,
            target: self,
            action: #selector(cycleAlignment)
        )
        alignItem.accessibilityLabel = "對齊"
        self.alignItem = alignItem

        let variantsItem = UIBarButtonItem(image: UIImage(systemName: "textformat.characters"), menu: UIMenu())
        variantsItem.accessibilityLabel = "地區變體"
        self.variantsItem = variantsItem

        // On iOS 26 every spacer partitions Liquid Glass into a separate
        // background group. Keep only the two outer spacers so all four
        // controls share one continuous toolbar surface, centred as a unit.
        let space = { UIBarButtonItem(systemItem: .flexibleSpace) }
        var items = [space(), fontItem, weightItem, sizeItem, styleItem, alignItem, variantsItem]

        // Tab moves between cells, but the software keyboard has no tab key —
        // so a table session gets the move as a button. Going backwards is left
        // to ⇧Tab and to tapping the cell: it is the rarer direction, and the
        // bar is already carrying six controls.
        //
        // The spacer before it is load-bearing. Moving the caret is not
        // formatting, and on iOS 26 a spacer starts a new background group —
        // which is exactly the separation this button wants.
        if cell != nil {
            let advanceItem = UIBarButtonItem()
            self.advanceItem = advanceItem
            updateAdvanceItem()
            items.append(contentsOf: [space(), advanceItem])
        }

        items.append(space())
        toolbar.items = items
        inputAccessoryView = toolbar
    }

    // MARK: - Cell navigation

    /// Rebuild the one navigation button around whichever move is currently in
    /// force. The menu holds only the other one, so the button always reads as
    /// "this is what a tap does, and here is the alternative".
    private func updateAdvanceItem() {
        guard let advanceItem else { return }
        let mode = cellAdvance
        let other = mode.other

        advanceItem.primaryAction = UIAction(
            image: UIImage(systemName: mode.symbolName)
        ) { [weak self] _ in
            self?.performAdvance(mode)
        }
        // Set after the primary action: assigning one clears the item's title,
        // image and menu, so the menu has to come second or it disappears.
        advanceItem.menu = UIMenu(children: [
            UIAction(title: other.title, image: UIImage(systemName: other.symbolName)) { [weak self] _ in
                guard let self else { return }
                self.cellAdvance = other
                self.updateAdvanceItem()
                self.performAdvance(other)
            },
        ])
        advanceItem.accessibilityLabel = mode.title
    }

    private func performAdvance(_ mode: CellAdvance) {
        switch mode {
        case .right: onMoveCellRight?()
        case .next: onAdvanceCell?(false)
        }
    }

    @objc private func goToNextCell() {
        onAdvanceCell?(false)
    }

    @objc private func goToPreviousCell() {
        onAdvanceCell?(true)
    }

    /// Tab and ⇧Tab, for the hardware keyboard. A `UITextView` would otherwise
    /// insert a tab character into the cell, which on a fixed grid does nothing
    /// a user ever wants.
    override var keyCommands: [UIKeyCommand]? {
        guard cell != nil else { return super.keyCommands }
        let next = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(goToNextCell))
        let previous = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(goToPreviousCell))
        for command in [next, previous] {
            command.wantsPriorityOverSystemBehavior = true
        }
        return (super.keyCommands ?? []) + [next, previous]
    }

    @objc private func cycleAlignment() {
        onSetAlignment?(formattingControlsState?.alignment.nextInCycle ?? .center)
    }

    @objc private func requestFontPicker() {
        onRequestFontPicker?()
    }

    @objc private func requestSizePicker(_ sender: UIBarButtonItem) {
        onRequestSizePicker?(sender)
    }

    /// Refresh menu states whenever the caret, selection or document style
    /// changes. `UIMenu` takes a snapshot, so rebuilding it is the supported way
    /// to keep its checkmarks honest. The state guard is equally important:
    /// UIKit treats assigning a new menu to an item in an input accessory
    /// toolbar as a toolbar configuration change, even when it looks identical.
    func updateFormattingControls(
        style: RunStyle,
        supportsRegionalVariants: Bool,
        alignment: TextAlignment
    ) {
        let state = FormattingControlsState(
            style: style,
            supportsRegionalVariants: supportsRegionalVariants,
            alignment: alignment
        )
        guard state != formattingControlsState else { return }
        formattingControlsState = state

        styleItem?.menu = UIMenu(children: [
            UIAction(
                title: "粗體",
                image: UIImage(systemName: "bold"),
                state: style.bold ? .on : .off
            ) { [weak self] _ in self?.onSetBold?(!style.bold) },
            UIAction(
                title: "斜體",
                image: UIImage(systemName: "italic"),
                state: style.italic ? .on : .off
            ) { [weak self] _ in self?.onSetItalic?(!style.italic) },
            UIAction(
                title: "底線",
                image: UIImage(systemName: "underline"),
                state: style.underline ? .on : .off
            ) { [weak self] _ in self?.onSetUnderline?(!style.underline) },
        ])

        alignItem?.image = UIImage(systemName: alignment.symbolName)
        alignItem?.accessibilityValue = alignment.label

        // The names come out of the font file — "Semibold", "Heavy", "W6" —
        // rather than from a weight vocabulary of our own that no family
        // actually uses in full.
        let family = FontCatalog.familyName(forPostScriptName: style.fontName)
        let faces = FontCatalog.faces(inFamily: family)
        weightItem?.menu = UIMenu(children: faces.map { face in
            UIAction(
                title: FontCatalog.faceLabel(postScriptName: face, family: family),
                state: face == style.fontName ? .on : .off
            ) { [weak self] _ in self?.onSetFontName?(face) }
        })
        // A single-face family has nothing to choose between.
        weightItem?.isEnabled = faces.count > 1

        let selectedLanguage = RunStyle.normalizedLanguageTag(style.languageTag)
        let languages: [(String, String?)] = [
            ("不指定", nil),
            ("繁體中文", "zh-Hant"),
            ("簡體中文", "zh-Hans"),
            ("日文", "ja"),
            ("韓文", "ko"),
        ]
        variantsItem?.menu = UIMenu(children: languages.map { label, tag in
            UIAction(title: label, state: selectedLanguage == tag ? .on : .off) { [weak self] _ in
                self?.onSetLanguageTag?(tag)
            }
        })
        variantsItem?.isEnabled = supportsRegionalVariants
    }

    /// The colour the text itself is drawn in while it is being edited. Also
    /// pinned to the light appearance: `.label` goes white in dark mode, and
    /// white ink on the white page leaves the user typing into nothing.
    static let ink = UIColor.label.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light)
    )

    /// The blue used for the caret, the selection highlight and the box outline,
    /// resolved once against the light appearance so it stays legible on paper.
    private static let editorTint = UIColor.systemBlue.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light)
    )

    /// Come back from a panel: take the keyboard again and put the selection
    /// back exactly where it was, so the words the user styled are still the
    /// words under the highlight.
    func resumeEditing(selecting range: NSRange) {
        isYieldingToPanel = false
        becomeFirstResponder()
        let length = (attributedText?.length ?? 0)
        let location = min(range.location, length)
        selectedRange = NSRange(location: location, length: min(range.length, length - location))
    }
}

extension CanvasTextEditorView: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
        onChange?(textView.attributedText ?? NSAttributedString())
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        onChange?(textView.attributedText ?? NSAttributedString())
        // Yielding to a sheet is not finishing. The session resumes, with the
        // same selection, as soon as the sheet goes away.
        guard !isYieldingToPanel else { return }
        onFinish?()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isReplacingContent else { return }
        onSelectionChange?(textView.selectedRange)
    }
}
