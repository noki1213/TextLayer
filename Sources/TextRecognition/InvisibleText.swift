import CoreGraphics
import CoreText
import Foundation

/// Draws recognized lines as invisible text into a PDF context, for building a new searchable PDF
/// page by page (draw the page image first, then this over it).
public enum InvisibleText {
    /// Each line is laid in the direction it reads (vertical Japanese runs down its column) and
    /// stretched to the length of its box, so a selection lines up with the printed text and no
    /// glyph runs off the page. Boxes
    /// are kept clear of their neighbours across the reading direction, and lines are written in
    /// reading order, so viewers that group characters by position select one line at a time.
    public static func draw(_ lines: [RecognizedLine], in box: CGRect, context: CGContext) {
        let rects = lines.map { line in
            CGRect(
                x: box.minX + line.box.minX * box.width,
                y: box.minY + line.box.minY * box.height,
                width: line.box.width * box.width,
                height: line.box.height * box.height
            )
        }
        let directions = lines.map { line in
            LineDirection(CGVector(
                dx: (line.bottomRight.x - line.bottomLeft.x) * box.width,
                dy: (line.bottomRight.y - line.bottomLeft.y) * box.height
            ))
        }
        let separated = LineDirection.separated(rects, directions: directions)
        let order = TextRecognizer.linesAreInReadingOrder
            ? Array(lines.indices)
            : ReadingOrder.order(rects, pageWidth: box.width)

        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for index in order {
            let (origin, end, top) = directions[index].corners(of: separated[index])
            let length = hypot(end.x - origin.x, end.y - origin.y)
            let height = hypot(top.x - origin.x, top.y - origin.y)
            guard length > 0, height > 0 else { continue }

            // Japanese falls back to a Japanese font. Hiragino's own Latin letters are not used:
            // PDFKit reads a doubled one ("ll" in "all") as a single letter
            let font = CTFontCreateWithName("Helvetica" as CFString, height * 0.85, nil)
            let attributed = NSAttributedString(
                string: lines[index].text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, &descent, nil))
            guard width > 0 else { continue }

            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            context.rotate(by: atan2(end.y - origin.y, end.x - origin.x))
            // Scaling the text matrix instead would narrow the glyphs but keep their advances
            context.scaleBy(x: length / width, y: 1)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}

/// Which way a line reads, in a space with the origin at the bottom-left.
public enum LineDirection: Sendable {
    case right, down, up, left

    /// run: from the start of the line's baseline to its end
    public init(_ run: CGVector) {
        if abs(run.dx) >= abs(run.dy) {
            self = run.dx >= 0 ? .right : .left
        } else {
            self = run.dy <= 0 ? .down : .up
        }
    }

    public var isVertical: Bool { self == .down || self == .up }

    /// Where the text starts, where it ends, and the top of its first glyph
    public func corners(of rect: CGRect) -> (CGPoint, CGPoint, CGPoint) {
        switch self {
        case .right:
            return (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
        case .left:
            return (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY))
        case .down:
            return (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
        case .up:
            return (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY))
        }
    }

    /// Line boxes kept clear of their neighbours across the reading direction: horizontal lines
    /// apart vertically, vertical lines apart horizontally
    public static func separated(_ rects: [CGRect], directions: [LineDirection]) -> [CGRect] {
        var result = rects
        let horizontal = rects.indices.filter { !directions[$0].isVertical }
        let vertical = rects.indices.filter { directions[$0].isVertical }
        for (index, rect) in zip(horizontal, LineBoxes.separated(horizontal.map { rects[$0] })) {
            result[index] = rect
        }
        let transposed = LineBoxes.separated(vertical.map { rects[$0].transposed }).map(\.transposed)
        for (index, rect) in zip(vertical, transposed) { result[index] = rect }
        return result
    }
}

private extension CGRect {
    var transposed: CGRect { CGRect(x: minY, y: minX, width: height, height: width) }
}
