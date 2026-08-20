//
//  TextModel.swift
//  Bitarf RI
//
//  Rich text inside a text box: an array of paragraphs, each an array of styled
//  runs. Deliberately the "minimum set" from the one-pager — font family, size,
//  bold / italic, alignment, line spacing, plus the OpenType language tag that
//  LOCL uses to pull regional glyph variants. No lists, no indents, no columns
//  until real use asks for them.
//
//  The model is the storage format; `NSAttributedString` is the working format.
//  Both directions of the bridge live here so that round-tripping through
//  UITextView is lossless for everything the model can express.
//

import CoreGraphics
import CoreText
import Foundation

// `NSParagraphStyle` / `NSTextAlignment` live in UIKit on iOS and AppKit on
// macOS. Importing conditionally is what keeps this file compiling under both
// the app target and `swift build` on the Mac.
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Style

public struct RunStyle: Codable, Hashable, Sendable {

    /// PostScript name preferred; a family name also resolves.
    public var fontName: String

    /// Point size in dots.
    /// 此處應插入經典機型解析度下的物理尺寸換算案例。
    public var fontSize: CGFloat

    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool

    /// BCP-47 language identifier (e.g. "zh-Hant", "zh-Hans", "ja"), driving
    /// `locl`. Core Text's language attribute does its own mapping to OpenType
    /// language systems — handing it the OT tag directly ("ZHT") is silently
    /// ignored, which is what used to make this control a no-op on every font.
    public var languageTag: String?

    /// Documents written before the BCP-47 switch stored OT tags. Translate on
    /// the way out rather than migrating files, so an old document opened in an
    /// old build still round-trips.
    public static func normalizedLanguageTag(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        switch tag {
        case "ZHT": return "zh-Hant"
        case "ZHS": return "zh-Hans"
        case "JAN": return "ja"
        case "KOR": return "ko"
        default: return tag
        }
    }

    public init(
        fontName: String = RunStyle.defaultFontName,
        fontSize: CGFloat = 26,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        languageTag: String? = nil
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.languageTag = RunStyle.normalizedLanguageTag(languageTag)
    }

    public static let defaultFontName = "PingFangTC-Regular"

    public static let `default` = RunStyle()
}

public enum TextAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case left, center, right, justified

    public var ctAlignment: CTTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }
}

public struct ParagraphStyle: Codable, Hashable, Sendable {
    public var alignment: TextAlignment
    /// Multiple of the natural line height. 1.0 = untouched.
    public var lineHeightMultiple: CGFloat
    /// Extra space before / after the paragraph, in dots.
    public var spacingBefore: CGFloat
    public var spacingAfter: CGFloat

    public init(
        alignment: TextAlignment = .left,
        lineHeightMultiple: CGFloat = 1.0,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0
    ) {
        self.alignment = alignment
        self.lineHeightMultiple = lineHeightMultiple
        self.spacingBefore = spacingBefore
        self.spacingAfter = spacingAfter
    }

    public static let `default` = ParagraphStyle()
}

// MARK: - Content

public struct TextRun: Codable, Hashable, Sendable {
    public var text: String
    public var style: RunStyle

    public init(text: String, style: RunStyle = .default) {
        self.text = text
        self.style = style
    }
}

public struct TextParagraph: Codable, Hashable, Sendable {
    public var runs: [TextRun]
    public var style: ParagraphStyle

    public init(runs: [TextRun], style: ParagraphStyle = .default) {
        self.runs = runs
        self.style = style
    }

    public init(text: String, runStyle: RunStyle = .default, style: ParagraphStyle = .default) {
        self.init(runs: [TextRun(text: text, style: runStyle)], style: style)
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }
}

public struct RichText: Codable, Hashable, Sendable {
    public var paragraphs: [TextParagraph]

    public init(paragraphs: [TextParagraph]) {
        self.paragraphs = paragraphs.isEmpty ? [TextParagraph(text: "")] : paragraphs
    }

    public init(text: String, runStyle: RunStyle = .default, paragraphStyle: ParagraphStyle = .default) {
        let lines = text.components(separatedBy: "\n")
        self.paragraphs = lines.map { TextParagraph(text: $0, runStyle: runStyle, style: paragraphStyle) }
    }

    public var plainText: String {
        paragraphs.map(\.plainText).joined(separator: "\n")
    }

    public var isEmpty: Bool {
        plainText.isEmpty
    }

    /// The style a newly typed character would inherit — used to seed the format
    /// panel when nothing is selected.
    public var leadingRunStyle: RunStyle {
        paragraphs.first?.runs.first?.style ?? .default
    }

    public var leadingParagraphStyle: ParagraphStyle {
        paragraphs.first?.style ?? .default
    }
}

// MARK: - Font resolution

public enum FontResolver {

    /// Resolve a run style to a concrete `CTFont`, applying synthetic-free
    /// bold / italic by asking Core Text for the matching symbolic trait first
    /// and only falling back to the base face when the family has no such cut.
    public static func font(for style: RunStyle) -> CTFont {
        let base = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)

        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }

        if let derived = CTFontCreateCopyWithSymbolicTraits(base, style.fontSize, nil, traits, traits) {
            return derived
        }
        return base
    }
}

// MARK: - NSAttributedString bridge

public extension RichText {

    /// Foreground colour attributes that both text stacks understand.
    ///
    /// UIKit/AppKit send `-CGColor` to whatever sits under `.foregroundColor`,
    /// so handing them a raw `CGColor` crashes the live editor the moment a
    /// text view lays the string out. Core Text reads its own key, which keeps
    /// taking the `CGColor` unchanged.
    static func foregroundAttributes(_ color: CGColor) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        #if canImport(UIKit)
        attributes[.foregroundColor] = UIColor(cgColor: color)
        #elseif canImport(AppKit)
        if let nsColor = NSColor(cgColor: color) {
            attributes[.foregroundColor] = nsColor
        }
        #endif
        return attributes
    }

    /// Convert to an attributed string ready for Core Text framesetting.
    ///
    /// `foreground` is a `CGColor` rather than a UIKit colour so the whole core
    /// stays platform-neutral. The canvas is 1-bit in the end, but keeping the
    /// colour parameterised lets the on-screen editor draw selection states and
    /// the print rasteriser drive everything to black.
    func attributedString(foreground: CGColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let colorAttributes = Self.foregroundAttributes(foreground)

        for (index, paragraph) in paragraphs.enumerated() {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = paragraph.style.alignment.nsAlignment
            if paragraph.style.lineHeightMultiple != 1 {
                paragraphStyle.lineHeightMultiple = paragraph.style.lineHeightMultiple
            }
            paragraphStyle.paragraphSpacingBefore = paragraph.style.spacingBefore
            paragraphStyle.paragraphSpacing = paragraph.style.spacingAfter
            // Core Text clips the last line of a justified frame if the paragraph
            // has no explicit break behaviour; word wrapping is what we want
            // everywhere since the box never has a bottom to overflow past.
            paragraphStyle.lineBreakMode = .byWordWrapping

            let runs = paragraph.runs.isEmpty ? [TextRun(text: "")] : paragraph.runs

            for run in runs {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: FontResolver.font(for: run.style),
                    .paragraphStyle: paragraphStyle,
                ]
                attributes.merge(colorAttributes) { _, new in new }
                if run.style.underline {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if run.style.strikethrough {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let tag = RunStyle.normalizedLanguageTag(run.style.languageTag) {
                    attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = tag
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }

            if index != paragraphs.indices.last {
                // The newline must carry the *preceding* paragraph's style,
                // otherwise Core Text attributes the break to the next block and
                // paragraph spacing lands one paragraph off.
                var breakAttributes: [NSAttributedString.Key: Any] = [
                    .font: FontResolver.font(for: runs.last?.style ?? .default),
                    .paragraphStyle: paragraphStyle,
                ]
                breakAttributes.merge(colorAttributes) { _, new in new }
                result.append(NSAttributedString(string: "\n", attributes: breakAttributes))
            }
        }

        return result
    }

    /// Attributes a newly typed character should carry.
    ///
    /// An empty text box has no attributed run to copy from, so a live text view
    /// left to its own devices types in the system default — which on a canvas
    /// measured in dots is a font size nobody asked for, and which then gets
    /// written back into the model as if the user had chosen it. Building the
    /// answer through `attributedString` rather than by hand is what keeps the
    /// live editor and the renderer from disagreeing about "the current style".
    func typingAttributes(foreground: CGColor) -> [NSAttributedString.Key: Any] {
        let probe = RichText(paragraphs: [
            TextParagraph(runs: [TextRun(text: " ", style: leadingRunStyle)], style: leadingParagraphStyle),
        ])
        return probe.attributedString(foreground: foreground).attributes(at: 0, effectiveRange: nil)
    }

    /// Rebuild the model from an attributed string produced by a text view.
    ///
    /// Attribute runs that the model cannot express are dropped rather than
    /// approximated — the model is the contract, and silently keeping an
    /// attribute we never render would make the saved file lie.
    static func from(attributedString: NSAttributedString) -> RichText {
        let full = attributedString.string as NSString
        guard full.length > 0 else { return RichText(paragraphs: []) }

        var paragraphs: [TextParagraph] = []
        var paragraphStart = 0

        while paragraphStart <= full.length {
            let searchRange = NSRange(location: paragraphStart, length: full.length - paragraphStart)
            let newlineRange = full.range(of: "\n", options: [], range: searchRange)
            let contentEnd = newlineRange.location == NSNotFound ? full.length : newlineRange.location
            let contentRange = NSRange(location: paragraphStart, length: contentEnd - paragraphStart)

            var runs: [TextRun] = []
            var paragraphStyle = ParagraphStyle.default

            if contentRange.length > 0 {
                attributedString.enumerateAttributes(in: contentRange, options: []) { attributes, range, _ in
                    let substring = full.substring(with: range)
                    runs.append(TextRun(text: substring, style: runStyle(from: attributes)))
                    if let ns = attributes[.paragraphStyle] as? NSParagraphStyle {
                        paragraphStyle = ParagraphStyle(
                            alignment: TextAlignment(ns.alignment),
                            lineHeightMultiple: ns.lineHeightMultiple == 0 ? 1 : ns.lineHeightMultiple,
                            spacingBefore: ns.paragraphSpacingBefore,
                            spacingAfter: ns.paragraphSpacing
                        )
                    }
                }
            } else if contentRange.location < full.length,
                      let ns = attributedString.attribute(.paragraphStyle, at: contentRange.location, effectiveRange: nil) as? NSParagraphStyle {
                paragraphStyle = ParagraphStyle(
                    alignment: TextAlignment(ns.alignment),
                    lineHeightMultiple: ns.lineHeightMultiple == 0 ? 1 : ns.lineHeightMultiple,
                    spacingBefore: ns.paragraphSpacingBefore,
                    spacingAfter: ns.paragraphSpacing
                )
            }

            paragraphs.append(TextParagraph(runs: runs.isEmpty ? [TextRun(text: "")] : runs, style: paragraphStyle))

            if newlineRange.location == NSNotFound { break }
            paragraphStart = newlineRange.location + newlineRange.length
            if paragraphStart == full.length {
                // Trailing newline — the document really does end on an empty
                // paragraph, and dropping it would eat the user's blank line.
                paragraphs.append(TextParagraph(text: "", style: paragraphStyle))
                break
            }
        }

        return RichText(paragraphs: paragraphs)
    }

    private static func runStyle(from attributes: [NSAttributedString.Key: Any]) -> RunStyle {
        var style = RunStyle.default

        if let value = attributes[.font],
           CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
            // The value is a CTFont on the Core Text side and a UIFont on the
            // UIKit side; the two are toll-free bridged, so the type-ID check
            // above makes the cast safe whichever one produced the string.
            let font = value as! CTFont
            style.fontSize = CTFontGetSize(font)
            let traits = CTFontGetSymbolicTraits(font)
            style.bold = traits.contains(.traitBold)
            style.italic = traits.contains(.traitItalic)
            // The face the text view hands back is the *resolved* one — ask
            // PingFang TC for bold and it comes back as PingFangTC-Semibold. Store
            // that verbatim and bold stops being a toggle: switching it off would
            // leave the semibold cut behind with nothing left to undo it. Strip
            // the traits back out so `bold` / `italic` stay the only truth, and
            // `FontResolver` re-derives the same cut on the way to the paper.
            let base = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, [], [.traitBold, .traitItalic]) ?? font
            style.fontName = CTFontCopyPostScriptName(base) as String
        }
        if let raw = attributes[.underlineStyle] as? Int {
            style.underline = raw != 0
        }
        if let raw = attributes[.strikethroughStyle] as? Int {
            style.strikethrough = raw != 0
        }
        if let tag = attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] as? String {
            style.languageTag = tag
        }
        return style
    }
}

// MARK: - Alignment bridging

public extension TextAlignment {
    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }

    init(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center: self = .center
        case .right: self = .right
        case .justified: self = .justified
        default: self = .left
        }
    }
}

// MARK: - Range-scoped styling

public extension RichText {

    /// The UTF-16 length of `plainText`, i.e. the length of the string a
    /// `UITextView` holding this rich text would report. Paragraphs are joined
    /// by exactly one newline, so the two agree offset for offset.
    var utf16Length: Int {
        var total = 0
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { total += 1 }
            total += paragraph.runs.reduce(0) { $0 + $1.text.utf16.count }
        }
        return total
    }

    /// Restyle only the characters in `range`, splitting runs at the boundaries.
    ///
    /// Offsets are UTF-16 over `plainText`, which is what an `NSRange` coming
    /// out of the live text view speaks. An empty range does nothing: "no
    /// selection" is not "the whole box", and silently restyling everything is
    /// the destructive reading of an ambiguous gesture.
    mutating func applyRunStyle(in range: Range<Int>, _ transform: (inout RunStyle) -> Void) {
        guard !range.isEmpty else { return }

        var cursor = 0
        for paragraphIndex in paragraphs.indices {
            if paragraphIndex > 0 { cursor += 1 }  // the newline between paragraphs

            var rebuilt: [TextRun] = []
            for run in paragraphs[paragraphIndex].runs {
                let units = Array(run.text.utf16)
                let start = cursor
                cursor += units.count

                // A zero-length run carries the style of an empty paragraph, so
                // it is restyled when the selection passes through that line.
                if units.isEmpty {
                    var run = run
                    if range.lowerBound <= start && start <= range.upperBound {
                        transform(&run.style)
                    }
                    rebuilt.append(run)
                    continue
                }

                let overlap = max(start, range.lowerBound)..<min(start + units.count, range.upperBound)
                guard overlap.lowerBound < overlap.upperBound else {
                    rebuilt.append(run)
                    continue
                }

                func piece(_ lower: Int, _ upper: Int, restyled: Bool) {
                    guard lower < upper else { return }
                    var style = run.style
                    if restyled { transform(&style) }
                    let text = String(decoding: units[(lower - start)..<(upper - start)], as: UTF16.self)
                    rebuilt.append(TextRun(text: text, style: style))
                }

                piece(start, overlap.lowerBound, restyled: false)
                piece(overlap.lowerBound, overlap.upperBound, restyled: true)
                piece(overlap.upperBound, start + units.count, restyled: false)
            }

            paragraphs[paragraphIndex].runs = RichText.coalesced(rebuilt)
        }
    }

    /// Restyle the paragraphs the range touches. A paragraph style has no
    /// sub-paragraph meaning — half a line cannot be centred — so touching one
    /// character in a line is taken as meaning the line.
    mutating func applyParagraphStyle(in range: Range<Int>, _ transform: (inout ParagraphStyle) -> Void) {
        var cursor = 0
        for paragraphIndex in paragraphs.indices {
            if paragraphIndex > 0 { cursor += 1 }
            let length = paragraphs[paragraphIndex].runs.reduce(0) { $0 + $1.text.utf16.count }
            let span = cursor...(cursor + length)
            cursor += length
            // Inclusive on both ends: a caret sitting at the very end of a line
            // is still in that line.
            if span.lowerBound <= range.upperBound && range.lowerBound <= span.upperBound {
                transform(&paragraphs[paragraphIndex].style)
            }
        }
    }

    /// The style shared by every character in `range`, or the style at the
    /// caret when the range is empty — what a format panel should show as the
    /// current state of the selection.
    func runStyle(in range: Range<Int>) -> RunStyle {
        var cursor = 0
        var found: RunStyle?
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            if paragraphIndex > 0 { cursor += 1 }
            for run in paragraph.runs {
                let start = cursor
                let length = run.text.utf16.count
                cursor += length
                let touched = range.isEmpty
                    ? (start < range.lowerBound && range.lowerBound <= start + length)
                    : (start < range.upperBound && range.lowerBound < start + length)
                guard touched else { continue }
                if let existing = found, existing != run.style { return existing }
                found = found ?? run.style
            }
        }
        return found ?? leadingRunStyle
    }

    /// Merge neighbouring runs that ended up with identical styles, so repeated
    /// selections do not shred one paragraph into dozens of runs.
    private static func coalesced(_ runs: [TextRun]) -> [TextRun] {
        var result: [TextRun] = []
        for run in runs {
            if var last = result.last, last.style == run.style {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result.isEmpty ? runs : result
    }
}
