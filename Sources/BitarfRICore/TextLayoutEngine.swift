//
//  TextLayoutEngine.swift
//  Bitarf RI
//
//  Fixed width, measured height. This is the one primitive the whole editor is
//  built on, and it comes straight from LOCL's ExportService:
//
//      CTFramesetterSuggestFrameSizeWithConstraints(
//          framesetter, .init(0, 0), nil,
//          CGSize(width: w, height: .greatestFiniteMagnitude), nil)
//
//  Everything else — the auto-growing text box, the canvas length, the print
//  raster height — is a consequence of that call.
//

import CoreGraphics
import CoreText
import Foundation

public enum TextLayoutEngine {

    /// Measured height, in dots, of `text` laid out at `width`.
    public static func measureHeight(_ text: RichText, width: CGFloat) -> CGFloat {
        measureHeight(text.attributedString(foreground: blackColor), width: width)
    }

    public static func measureHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }

        // An empty string frames to zero height, which would collapse the box to
        // an untappable sliver. Measure a single space instead so an empty text
        // box is exactly one line tall.
        let measured: NSAttributedString
        if attributed.length == 0 {
            measured = NSAttributedString(
                string: " ",
                attributes: [.font: FontResolver.font(for: .default)]
            )
        } else {
            measured = attributed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(measured)
        let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )

        // Core Text rounds line heights down internally; ceiling the result
        // avoids the last line losing a dot of its descender on paper.
        return ceil(fitSize.height)
    }

    /// Natural width of the text if it were allowed to run on one line. Used by
    /// "shrink box to fit" in the inspector.
    public static func measureNaturalWidth(_ text: RichText, maximum: CGFloat) -> CGFloat {
        let attributed = text.attributedString(foreground: blackColor)
        guard attributed.length > 0 else { return maximum }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maximum, height: .greatestFiniteMagnitude),
            nil
        )
        return min(maximum, ceil(fitSize.width))
    }

    /// Draw `attributed` into `context` filling `rect`, in a top-left origin
    /// coordinate space.
    ///
    /// The caller is responsible for the flip; `CanvasRenderer` does it once for
    /// the whole canvas rather than per object, so that rotation and layer order
    /// stay in one coordinate system.
    public static func draw(
        _ attributed: NSAttributedString,
        in rect: CGRect,
        context: CGContext
    ) {
        guard attributed.length > 0, rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        context.textMatrix = .identity

        // Core Text draws bottom-up. Flip just this rect so the first line lands
        // at the top of the box regardless of how tall the box turned out.
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)

        let drawRect = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: drawRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)

        context.restoreGState()
    }

    static let blackColor: CGColor = {
        CGColor(colorSpace: CGColorSpaceCreateDeviceGray(), components: [0, 1])
            ?? CGColor(gray: 0, alpha: 1)
    }()
}
