import CoreGraphics
import CoreText
import Foundation

/// Draws recognized lines as invisible text into a PDF context, for building a new searchable PDF
/// page by page (draw the page image first, then this over it).
public enum InvisibleText {
    /// Each line is stretched to the width of its box, so a selection lines up with the printed text.
    public static func draw(_ lines: [RecognizedLine], in box: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(
                x: box.minX + line.box.minX * box.width,
                y: box.minY + line.box.minY * box.height,
                width: line.box.width * box.width,
                height: line.box.height * box.height
            )
            guard rect.width > 0, rect.height > 0 else { continue }

            let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, rect.height * 0.85, nil)
            let attributed = NSAttributedString(
                string: line.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, &descent, nil))
            guard width > 0 else { continue }

            context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }
}
