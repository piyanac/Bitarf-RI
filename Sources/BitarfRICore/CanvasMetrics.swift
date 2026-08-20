//
//  CanvasMetrics.swift
//  Bitarf RI
//
//  Units.
//
//  The document's native unit is the dot. Hardware-specific scale and paper
//  limits are intentionally absent from this reconstruction repository.
//

import CoreGraphics
import Foundation

public enum CanvasMetrics {

    // 此處應插入經典機型的解析度、紙張寬度、預設固定軸與支援範圍。

    public static func mm(fromDots dots: CGFloat) -> CGFloat {
        dots * mmPerDot
    }

    public static func dots(fromMM mm: CGFloat) -> CGFloat {
        mm / mmPerDot
    }

    /// Human-readable physical length of a run of dots, e.g. "128.4 mm".
    public static func lengthDescription(dots: CGFloat) -> String {
        let millimetres = mm(fromDots: dots)
        if millimetres >= 1000 {
            return String(format: "%.2f m", millimetres / 1000)
        }
        if millimetres >= 100 {
            return String(format: "%.1f cm", millimetres / 10)
        }
        return String(format: "%.1f mm", millimetres)
    }

    /// A raster row is packed MSB-first, 8 dots per byte.
    public static func bytesPerRow(fixedAxisDots: Int) -> Int {
        (fixedAxisDots + 7) / 8
    }

    /// Round a dot count up to a whole byte so every raster row is byte aligned.
    public static func byteAligned(_ dots: Int) -> Int {
        ((dots + 7) / 8) * 8
    }
}

// MARK: - Codable geometry

/// `CGPoint` / `CGSize` / `CGRect` are `Codable` on Apple platforms but encode as
/// unkeyed arrays, which makes the saved document unreadable by a human. These
/// wrappers keep the JSON self-describing.

public struct DotPoint: Codable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    public static let zero = DotPoint(x: 0, y: 0)
}

public struct DotSize: Codable, Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }

    public static let zero = DotSize(width: 0, height: 0)
}
