import CoreGraphics

public enum LineBoxes {
    /// Shrinks line boxes about their centres until no two lines that share horizontal space
    /// overlap vertically. Viewers such as PDFKit group characters into lines by their vertical
    /// extent rather than by the order they were written in, so recognized boxes that reach into
    /// the next line (common on tightly set scans) make neighbouring lines merge and their
    /// characters interleave when selected or copied.
    /// boxes: origin at the bottom-left.
    public static func separated(_ boxes: [CGRect]) -> [CGRect] {
        var halfHeights = boxes.map { $0.height / 2 }
        for i in boxes.indices {
            for j in boxes.indices where j != i {
                let a = boxes[i], b = boxes[j]
                guard min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0 else { continue }
                let distance = abs(a.midY - b.midY)
                // Pieces of the same row are not neighbours
                guard distance > min(a.height, b.height) * 0.3 else { continue }
                if distance < a.height / 2 + b.height / 2 {
                    halfHeights[i] = min(halfHeights[i], distance * 0.45)
                }
            }
        }
        return boxes.indices.map { i in
            let box = boxes[i]
            return CGRect(x: box.minX, y: box.midY - halfHeights[i], width: box.width, height: halfHeights[i] * 2)
        }
    }
}
