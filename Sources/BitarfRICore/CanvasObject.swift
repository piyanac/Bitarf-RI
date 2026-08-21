//
//  CanvasObject.swift
//  Bitarf RI
//
//  Free canvas, absolute positioning. Objects never affect each other: no text
//  wrap, no reflow, no stacking. Draw order == array order == layer order.
//
//  A text box has a fixed width and a height that is *derived* from its content
//  — it is never stored as an independent truth, because there is no page bottom
//  to overflow past and therefore no such thing as a clipped text box.
//

import CoreGraphics
import Foundation

// MARK: - Shapes

public enum ShapeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case rectangle
    case ellipse
    case line
}

public struct ShapeContent: Codable, Hashable, Sendable {
    public var kind: ShapeKind
    /// Stroke width in dots. 0 means no stroke.
    public var strokeWidth: CGFloat
    /// Filled shapes print solid black; unfilled ones are outlines.
    public var filled: Bool
    /// Corner radius in dots, rectangles only.
    public var cornerRadius: CGFloat
    /// Dash pattern in dots; empty means a solid stroke.
    public var dashPattern: [CGFloat]

    public init(
        kind: ShapeKind = .rectangle,
        strokeWidth: CGFloat = 2,
        filled: Bool = false,
        cornerRadius: CGFloat = 0,
        dashPattern: [CGFloat] = []
    ) {
        self.kind = kind
        self.strokeWidth = strokeWidth
        self.filled = filled
        self.cornerRadius = cornerRadius
        self.dashPattern = dashPattern
    }
}

// MARK: - Images

public struct ImageContent: Codable, Hashable, Sendable {
    /// PNG bytes. Stored in the document so a `.bitarf` file is self-contained
    /// — no photo-library dependency, no cloud, nothing to go missing later.
    public var pngData: Data
    /// Pixel size of `pngData`, cached so layout does not need to decode.
    public var pixelSize: DotSize
    /// Invert before printing (white-on-black artwork).
    public var inverted: Bool
    /// Per-image dithering override; `nil` follows the document setting.
    public var ditherOverride: DitherAlgorithm?
    /// Exposure shift applied before dithering, -1...1, 0 = untouched.
    ///
    /// Thermal paper has no dynamic range to spare, so a photo that looks fine
    /// on a screen routinely dithers into mud. Adjusting here rather than asking
    /// the user to re-edit the source keeps the original bytes intact and the
    /// correction re-editable.
    public var brightness: Double
    /// Contrast stretch about mid-gray applied before dithering, -1...1.
    public var contrast: Double

    public init(
        pngData: Data,
        pixelSize: DotSize,
        inverted: Bool = false,
        ditherOverride: DitherAlgorithm? = nil,
        brightness: Double = 0,
        contrast: Double = 0
    ) {
        self.pngData = pngData
        self.pixelSize = pixelSize
        self.inverted = inverted
        self.ditherOverride = ditherOverride
        self.brightness = brightness
        self.contrast = contrast
    }

    // Adjustments arrived after the first images were saved, so a document
    // written without them must still open — and open unadjusted.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pngData = try container.decode(Data.self, forKey: .pngData)
        pixelSize = try container.decode(DotSize.self, forKey: .pixelSize)
        inverted = try container.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        ditherOverride = try container.decodeIfPresent(DitherAlgorithm.self, forKey: .ditherOverride)
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
    }

    /// Whether the tone controls are doing anything, so the render path can skip
    /// building a corrected copy of the image when they are not.
    public var hasToneAdjustment: Bool {
        brightness != 0 || contrast != 0
    }
}

// MARK: - Vector artwork

/// Which file the artwork was imported from. Both are stored as PDF; this is
/// kept only so the object list can say where a drawing came from.
public enum VectorSourceKind: String, Codable, Hashable, Sendable {
    case pdf
    case svg

    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .svg: return "SVG"
        }
    }
}

public struct VectorContent: Codable, Hashable, Sendable {
    /// A single-page PDF. SVG is converted to PDF on the way in so there is one
    /// drawing path — and, more importantly, so the artwork stays vector all the
    /// way into the print rasteriser instead of being frozen into pixels at
    /// import time.
    /// 此處應插入經典機型輸出解析度下的取樣說明。
    public var pdfData: Data
    /// Media-box size of that page in PDF points, cached so layout never has to
    /// open the document.
    public var intrinsicSize: DotSize
    public var sourceKind: VectorSourceKind
    /// Original file name, shown in the object list.
    public var sourceName: String?

    public init(
        pdfData: Data,
        intrinsicSize: DotSize,
        sourceKind: VectorSourceKind,
        sourceName: String? = nil
    ) {
        self.pdfData = pdfData
        self.intrinsicSize = intrinsicSize
        self.sourceKind = sourceKind
        self.sourceName = sourceName
    }
}

// MARK: - Object

public enum ObjectContent: Hashable, Sendable {
    case text(RichText)
    case shape(ShapeContent)
    case image(ImageContent)
    case vector(VectorContent)
    case table(TableContent)
}

extension ObjectContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, shape, image, vector, table
    }

    private enum Kind: String, Codable {
        case text, shape, image, vector, table
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(RichText.self, forKey: .text))
        case .shape:
            self = .shape(try container.decode(ShapeContent.self, forKey: .shape))
        case .image:
            self = .image(try container.decode(ImageContent.self, forKey: .image))
        case .vector:
            self = .vector(try container.decode(VectorContent.self, forKey: .vector))
        case .table:
            self = .table(try container.decode(TableContent.self, forKey: .table))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .text)
        case .shape(let value):
            try container.encode(Kind.shape, forKey: .kind)
            try container.encode(value, forKey: .shape)
        case .image(let value):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(value, forKey: .image)
        case .vector(let value):
            try container.encode(Kind.vector, forKey: .kind)
            try container.encode(value, forKey: .vector)
        case .table(let value):
            try container.encode(Kind.table, forKey: .kind)
            try container.encode(value, forKey: .table)
        }
    }
}

public struct CanvasObject: Codable, Hashable, Identifiable, Sendable {

    public var id: UUID

    /// Top-left corner in canvas dots, before rotation.
    public var origin: DotPoint

    /// Width is authoritative for every object type.
    /// Height is authoritative for shapes and images; for text it is a cache of
    /// the measured height and is refreshed by `BitarfDocument.reflow`.
    public var size: DotSize

    /// Clockwise rotation about the object's centre, in radians.
    public var rotation: CGFloat

    public var content: ObjectContent

    /// Hidden objects stay in the document but render nowhere — neither on
    /// screen nor on paper.
    public var isHidden: Bool

    /// Locked objects are not hit-testable on the canvas; the object list is the
    /// only way to reach them.
    public var isLocked: Bool

    public var name: String?

    public init(
        id: UUID = UUID(),
        origin: DotPoint,
        size: DotSize,
        rotation: CGFloat = 0,
        content: ObjectContent,
        isHidden: Bool = false,
        isLocked: Bool = false,
        name: String? = nil
    ) {
        self.id = id
        self.origin = origin
        self.size = size
        self.rotation = rotation
        self.content = content
        self.isHidden = isHidden
        self.isLocked = isLocked
        self.name = name
    }

    // MARK: Derived geometry

    public var frame: CGRect {
        CGRect(origin: origin.cgPoint, size: size.cgSize)
    }

    public var center: CGPoint {
        CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    public mutating func setCenter(_ point: CGPoint) {
        origin = DotPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
    }

    /// Axis-aligned bounding box after rotation. This is what the canvas length
    /// and the selection outline are computed from.
    public var boundingBox: CGRect {
        guard rotation != 0 else { return frame }
        let c = center
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let extentX = abs(halfWidth * cosine) + abs(halfHeight * sine)
        let extentY = abs(halfWidth * sine) + abs(halfHeight * cosine)
        return CGRect(
            x: c.x - extentX,
            y: c.y - extentY,
            width: extentX * 2,
            height: extentY * 2
        )
    }

    /// The four corners in canvas space, clockwise from top-left.
    public var corners: [CGPoint] {
        let c = center
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let local = [
            CGPoint(x: -halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: halfHeight),
            CGPoint(x: -halfWidth, y: halfHeight),
        ]
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return local.map {
            CGPoint(
                x: c.x + $0.x * cosine - $0.y * sine,
                y: c.y + $0.x * sine + $0.y * cosine
            )
        }
    }

    /// Hit test in canvas space, honouring rotation.
    /// `slop` widens the target by a few dots so a fingertip can still land on a
    /// hairline rule.
    public func contains(_ point: CGPoint, slop: CGFloat = 0) -> Bool {
        let c = center
        let dx = point.x - c.x
        let dy = point.y - c.y
        let cosine = cos(-rotation)
        let sine = sin(-rotation)
        let localX = dx * cosine - dy * sine
        let localY = dx * sine + dy * cosine
        return abs(localX) <= size.width / 2 + slop
            && abs(localY) <= size.height / 2 + slop
    }

    // MARK: Convenience

    public var isText: Bool {
        if case .text = content { return true }
        return false
    }

    public var isShape: Bool {
        if case .shape = content { return true }
        return false
    }

    /// Vector artwork has no formatting of its own — the 格式 panel has nothing
    /// to offer it, and the toolbar asks about this before enabling that button.
    public var isVector: Bool {
        if case .vector = content { return true }
        return false
    }

    /// A table is a grid of text, not one run of it: the format panel offers it
    /// a different set of controls, and the toolbar asks about this before
    /// enabling that button.
    public var isTable: Bool {
        if case .table = content { return true }
        return false
    }

    public var table: TableContent? {
        if case .table(let value) = content { return value }
        return nil
    }

    public var vector: VectorContent? {
        if case .vector(let value) = content { return value }
        return nil
    }

    public var richText: RichText? {
        if case .text(let value) = content { return value }
        return nil
    }

    /// SF Symbol standing in for this object in lists and toolbars.
    ///
    /// These name the thing, not what can be done to it — `textformat` is the
    /// act of formatting and belongs to the 格式 panel, while a row in the layer
    /// list is a text *box*. It is also the glyph the 文字方塊 button already
    /// wears, so the two now agree about what they are pointing at.
    public var symbolName: String {
        switch content {
        case .text:
            return "character.textbox"
        case .image:
            return "photo"
        case .vector:
            return "beziercurve"
        case .table:
            return "tablecells"
        case .shape(let shape):
            switch shape.kind {
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            }
        }
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        switch content {
        case .text(let value):
            let trimmed = value.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "空白文字框" }
            return String(trimmed.prefix(20))
        case .shape(let value):
            switch value.kind {
            case .rectangle: return "矩形"
            case .ellipse: return "圓形"
            case .line: return "線條"
            }
        case .image:
            return "圖片"
        case .vector(let value):
            if let name = value.sourceName, !name.isEmpty { return name }
            return "\(value.sourceKind.displayName) 向量"
        case .table(let value):
            let trimmed = (value.rows.first?.first?.plainText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "表格" }
            return String(trimmed.prefix(20))
        }
    }
}
