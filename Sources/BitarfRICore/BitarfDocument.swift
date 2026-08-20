//
//  BitarfDocument.swift
//  Bitarf RI
//
//  One strip of paper: fixed on one axis, unbounded on the other.
//
//  `length` is never stored. It is always the extent of the content, because a
//  continuous roll has no page size for the user to pick — asking them to set
//  one would be inventing a constraint the medium does not have.
//

import CoreGraphics
import Foundation

public enum CanvasOrientation: String, Codable, CaseIterable, Hashable, Sendable {
    /// Fixed axis is the width; the paper grows downwards.
    case portrait
    /// Fixed axis is the height; the paper grows to the right.
    case landscape

    public var isPortrait: Bool { self == .portrait }
}

public struct BitarfDocument: Codable, Hashable, Sendable {

    // MARK: Stored

    public var formatVersion: Int
    public var orientation: CanvasOrientation
    /// Printable extent of the fixed axis, in dots.
    public var fixedAxisDots: Int
    public var objects: [CanvasObject]

    /// Print settings travel with the document — the dithering choice is a
    /// property of *this* artwork, not a global preference.
    public var dither: DitherAlgorithm
    /// Cut point for the modes that have one — `.threshold` and `.none`. Ignored
    /// by the diffusion and ordered modes, which derive their own.
    ///
    /// Stored because it is the *entire* control surface of those two modes: a
    /// line drawing that comes out too heavy has nowhere else to go.
    public var threshold: UInt8
    // 此處應插入經典機型的文件濃度與尾端走紙欄位。
    /// Empty margin kept clear on all four sides, in dots.
    public var margin: CGFloat

    public var title: String

    // MARK: Init

    public init(
        formatVersion: Int = BitarfDocument.currentFormatVersion,
        orientation: CanvasOrientation = .portrait,
        fixedAxisDots: Int,
        objects: [CanvasObject] = [],
        dither: DitherAlgorithm = .floydSteinberg,
        threshold: UInt8 = 128,
        // 此處應插入經典機型的濃度與尾端走紙初始化參數。
        margin: CGFloat = 8,
        title: String = "未命名"
    ) {
        self.formatVersion = formatVersion
        self.orientation = orientation
        self.fixedAxisDots = fixedAxisDots
        self.objects = objects
        self.dither = dither
        self.threshold = threshold
        // 此處應插入經典機型的濃度與尾端走紙指派。
        self.margin = margin
        self.title = title
    }

    public static let currentFormatVersion = 1

    public static let fileExtension = "bitarf"

    // MARK: Decoding tolerance

    // Documents written by an older build must keep opening, so every field
    // added after v1 decodes with a default rather than failing the whole file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        orientation = try container.decodeIfPresent(CanvasOrientation.self, forKey: .orientation) ?? .portrait
        // 此處應插入經典機型固定軸的向下相容解碼預設值。
        fixedAxisDots = try container.decode(Int.self, forKey: .fixedAxisDots)
        objects = try container.decodeIfPresent([CanvasObject].self, forKey: .objects) ?? []
        dither = try container.decodeIfPresent(DitherAlgorithm.self, forKey: .dither) ?? .floydSteinberg
        threshold = try container.decodeIfPresent(UInt8.self, forKey: .threshold) ?? 128
        // 此處應插入經典機型濃度與尾端走紙的向下相容解碼。
        margin = try container.decodeIfPresent(CGFloat.self, forKey: .margin) ?? 8
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未命名"
    }

    // MARK: Geometry

    /// Width of the canvas in dots. In landscape this is the growing axis.
    public var canvasWidth: CGFloat {
        orientation.isPortrait ? CGFloat(fixedAxisDots) : contentLength
    }

    /// Height of the canvas in dots. In portrait this is the growing axis.
    public var canvasHeight: CGFloat {
        orientation.isPortrait ? contentLength : CGFloat(fixedAxisDots)
    }

    public var canvasSize: CGSize {
        CGSize(width: canvasWidth, height: canvasHeight)
    }

    /// How far the content reaches along the growing axis, plus the trailing
    /// margin. Never shorter than `minimumLength` so an empty document is still
    /// something you can point at and drop an object onto.
    public var contentLength: CGFloat {
        var extent: CGFloat = 0
        for object in objects where !object.isHidden {
            let box = object.boundingBox
            extent = max(extent, orientation.isPortrait ? box.maxY : box.maxX)
        }
        return max(BitarfDocument.minimumLength, ceil(extent + margin))
    }

    public static let minimumLength: CGFloat = 240

    /// The rectangle inside the margins, in canvas dots.
    public var contentRect: CGRect {
        CGRect(
            x: margin,
            y: margin,
            width: max(0, canvasWidth - margin * 2),
            height: max(0, canvasHeight - margin * 2)
        )
    }

    /// Physical length of the strip that would come out of the printer.
    public var physicalLengthDescription: String {
        CanvasMetrics.lengthDescription(dots: contentLength)
    }

    // MARK: Object access

    public func index(of id: UUID) -> Int? {
        objects.firstIndex { $0.id == id }
    }

    public subscript(id: UUID) -> CanvasObject? {
        get {
            guard let index = index(of: id) else { return nil }
            return objects[index]
        }
        set {
            guard let index = index(of: id) else { return }
            if let newValue {
                objects[index] = newValue
            } else {
                objects.remove(at: index)
            }
        }
    }

    /// Topmost unlocked, visible object under `point`.
    public func hitTest(_ point: CGPoint, slop: CGFloat = 4) -> CanvasObject? {
        objects.reversed().first {
            !$0.isHidden && !$0.isLocked && $0.contains(point, slop: slop)
        }
    }

    /// Every unlocked, visible object under `point`, topmost first. Feeds the
    /// "which one did you mean" picker for overlapping objects.
    public func hitTestAll(_ point: CGPoint, slop: CGFloat = 4) -> [CanvasObject] {
        objects.reversed().filter {
            !$0.isHidden && !$0.isLocked && $0.contains(point, slop: slop)
        }
    }

    // MARK: Layer order

    // Every one of these takes a set, because a multi-selection has to be able
    // to change layer as one. The single-id versions are one-element wrappers.
    //
    // The shared promise: whatever else moves, the *relative* order of the
    // members never changes. A caption that sits above its rule has to still sit
    // above it after both are sent to the back together.

    public mutating func bringToFront(_ id: UUID) { bringToFront([id]) }
    public mutating func sendToBack(_ id: UUID) { sendToBack([id]) }
    public mutating func bringForward(_ id: UUID) { bringForward([id]) }
    public mutating func sendBackward(_ id: UUID) { sendBackward([id]) }

    public mutating func bringToFront(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let members = objects.filter { ids.contains($0.id) }
        objects.removeAll { ids.contains($0.id) }
        objects.append(contentsOf: members)
    }

    public mutating func sendToBack(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let members = objects.filter { ids.contains($0.id) }
        objects.removeAll { ids.contains($0.id) }
        objects.insert(contentsOf: members, at: 0)
    }

    /// Each member steps up one slot unless the slot above is also a member, so
    /// a contiguous run travels as a block and stops cleanly against the top
    /// rather than folding in on itself.
    public mutating func bringForward(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in objects.indices.dropLast().reversed() {
            guard ids.contains(objects[index].id),
                  !ids.contains(objects[index + 1].id) else { continue }
            objects.swapAt(index, index + 1)
        }
    }

    public mutating func sendBackward(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in objects.indices.dropFirst() {
            guard ids.contains(objects[index].id),
                  !ids.contains(objects[index - 1].id) else { continue }
            objects.swapAt(index, index - 1)
        }
    }

    // MARK: Reflow

    /// Re-measure every text box so its stored height matches its content.
    ///
    /// Text boxes grow, never clip — there is no page bottom, so overflow simply
    /// does not exist as a state the document can be in.
    public mutating func reflow() {
        for index in objects.indices {
            guard case .text(let rich) = objects[index].content else { continue }
            let width = max(1, objects[index].size.width)
            let height = TextLayoutEngine.measureHeight(rich, width: width)
            objects[index].size.height = height
        }
    }

    /// A copy with text heights up to date. Every render path goes through this
    /// so the screen and the paper can never disagree about how tall a box is.
    public var reflowed: BitarfDocument {
        var copy = self
        copy.reflow()
        return copy
    }

    /// Is there anything here that would put ink on paper?
    ///
    /// A text box holding nothing but whitespace does not count, which is what
    /// separates "the user opened the app and looked at it" from "the user made
    /// something" — and therefore what the app is allowed to throw away.
    public var hasPrintableContent: Bool {
        objects.contains { object in
            if let rich = object.richText {
                return !rich.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    // MARK: Serialisation

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> BitarfDocument {
        try JSONDecoder().decode(BitarfDocument.self, from: data)
    }

    /// On-disk form for documents that stay inside the app.
    ///
    /// The same fields as `encoded()`, in a binary property list. JSON has to
    /// base64 the inlined PNGs, which costs a third of the file for bytes that
    /// are already compressed — and the library rewrites these files often
    /// enough for that to be worth avoiding. Exports keep using `encoded()`,
    /// because a file that leaves the app should stay readable by hand.
    public func encodedCompact() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Decode either on-disk form. Which one a file uses is an implementation
    /// detail that changed once already, so every read path sniffs instead of
    /// assuming.
    public static func decodedAny(from data: Data) throws -> BitarfDocument {
        if data.starts(with: Array("bplist".utf8)) {
            return try PropertyListDecoder().decode(BitarfDocument.self, from: data)
        }
        return try decoded(from: data)
    }
}

// MARK: - Starter content

public extension BitarfDocument {

    /// A blank document ready for the user to place the first object.
    static func starter() -> BitarfDocument {
        BitarfDocument(title: "未命名")
    }
}
