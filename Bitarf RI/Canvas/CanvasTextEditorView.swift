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

    var onChange: ((NSAttributedString) -> Void)?
    var onFinish: (() -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?
    var onRequestFontPicker: (() -> Void)?
    var onRequestSizePicker: ((UIBarButtonItem) -> Void)?
    var onSetBold: ((Bool) -> Void)?
    var onSetItalic: ((Bool) -> Void)?
    var onSetUnderline: ((Bool) -> Void)?
    var onSetLanguageTag: ((String?) -> Void)?

    private weak var styleItem: UIBarButtonItem?
    private weak var variantsItem: UIBarButtonItem?

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
    }

    private var formattingControlsState: FormattingControlsState?

    /// Set while a panel is being presented over the canvas. The text view has
    /// to give up first responder to the sheet, but that is not the user saying
    /// they are done — so the resignation must not end the editing session.
    var isYieldingToPanel = false

    /// True while `replaceContent` is rewriting the storage, so the selection
    /// churn that causes is not mistaken for the user moving the caret.
    private var isReplacingContent = false

    init(objectID: UUID) {
        self.objectID = objectID

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
            image: UIImage(systemName: "character"),
            style: .plain,
            target: self,
            action: #selector(requestFontPicker)
        )
        fontItem.accessibilityLabel = "字體"

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

        let variantsItem = UIBarButtonItem(image: UIImage(systemName: "textformat.characters"), menu: UIMenu())
        variantsItem.accessibilityLabel = "地區變體"
        self.variantsItem = variantsItem

        // On iOS 26 every spacer partitions Liquid Glass into a separate
        // background group. Keep only the two outer spacers so all four
        // controls share one continuous toolbar surface, centred as a unit.
        let space = { UIBarButtonItem(systemItem: .flexibleSpace) }
        toolbar.items = [space(), fontItem, sizeItem, styleItem, variantsItem, space()]
        inputAccessoryView = toolbar
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
    func updateFormattingControls(style: RunStyle, supportsRegionalVariants: Bool) {
        let state = FormattingControlsState(
            style: style,
            supportsRegionalVariants: supportsRegionalVariants
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
