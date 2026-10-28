import CoreGraphics
import Foundation

/// Vision's text detector sometimes skips part of a page: the start or end of a line, or a whole
/// line, and which parts changes with the size of the image. Printed marks that no recognized line
/// covers are read again from a crop around them, which finds that text reliably.
enum MissedText {
    /// Most crops read again per image, so a page full of drawings stays quick
    static let maxCrops = 12

    /// lines: what reading the whole image found, in reading order if the reader gives one.
    /// read: reads a crop the same way. Lines read again replace the ones they cover in place.
    static func fill(
        _ lines: [RecognizedLine], in image: CGImage, read: (CGImage) throws -> [RecognizedLine]
    ) -> [RecognizedLine] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard !lines.isEmpty, width > 0, height > 0 else { return lines }

        // Pixels with the origin at the bottom-left
        func rect(of line: RecognizedLine) -> CGRect {
            let box = line.box
            return CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
        }
        func isVertical(_ line: RecognizedLine) -> Bool {
            LineDirection(CGVector(
                dx: (line.bottomRight.x - line.bottomLeft.x) * width,
                dy: (line.bottomRight.y - line.bottomLeft.y) * height
            )).isVertical
        }
        let thicknesses = lines.map { isVertical($0) ? rect(of: $0).width : rect(of: $0).height }.sorted()
        let thickness = thicknesses[thicknesses.count / 2]
        guard thickness >= 4,
              let ink = InkGrid(image, cell: max(1, Int(thickness / 4)))
        else { return lines }

        let lineRects = lines.map(rect(of:))
        for rect in lineRects { ink.cover(rect.insetBy(dx: -thickness * 0.25, dy: -thickness * 0.25)) }

        // Marks touching the start or end of a line are the likeliest misses; marks elsewhere count
        // only if they are the size of a line of text (not a rule, a speck or small ruby)
        var crops: [(rect: CGRect, nextToLine: Bool, area: CGFloat)] = []
        for mark in ink.uncoveredMarks(joining: thickness * 0.4) {
            guard min(mark.width, mark.height) > CGFloat(ink.cell) else { continue }
            let nextToLine = lines.indices.contains { index in
                touchesEnd(of: lineRects[index], vertical: isVertical(lines[index]), mark: mark, thickness: thickness)
            }
            guard nextToLine || min(mark.width, mark.height) >= thickness * 0.6 else { continue }
            crops.append((mark, nextToLine, mark.width * mark.height))
        }
        crops.sort { ($0.nextToLine ? 1 : 0, $0.area) > ($1.nextToLine ? 1 : 0, $1.area) }

        var result = lines
        var done: [CGRect] = []
        for crop in crops.prefix(maxCrops) {
            let mark = crop.rect
            guard !done.contains(where: { $0.contains(CGPoint(x: mark.midX, y: mark.midY)) }) else { continue }

            // Take in the whole of every line the mark runs into, so the crop reads them complete
            var area = mark.insetBy(dx: -thickness * 0.15, dy: -thickness * 0.15)
            for _ in 0..<3 {
                let probe = area.insetBy(dx: -thickness * 0.1, dy: -thickness * 0.1)
                let grown = result.map(rect(of:)).filter { $0.intersects(probe) }.reduce(area) { $0.union($1) }
                if grown == area { break }
                area = grown
            }
            area = area.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            done.append(area)
            guard area.width >= 1, area.height >= 1,
                  var found = try? readCrop(area, of: image, padding: thickness, read: read)
            else { continue }

            let replaced = result.indices.filter { index in
                let rect = rect(of: result[index])
                return area.contains(CGPoint(x: rect.midX, y: rect.midY))
            }
            // On its own, a mark read with little confidence is a drawing or a smudge
            if replaced.isEmpty { found = found.filter { $0.confidence >= 0.3 } }
            guard !found.isEmpty else { continue }
            let before = replaced.reduce(0) { $0 + letterCount(result[$1].text) }
            guard found.reduce(0, { $0 + letterCount($1.text) }) > before else { continue }

            let position = replaced.first ?? insertionIndex(for: rect(of: found[0]), vertical: isVertical(found[0]), in: result.map(rect(of:)))
            for index in replaced.reversed() { result.remove(at: index) }
            result.insert(contentsOf: found, at: position - replaced.filter { $0 < position }.count)
        }
        return result
    }

    /// Whether mark lies in the line's band, just before its start or after its end
    private static func touchesEnd(of line: CGRect, vertical: Bool, mark: CGRect, thickness: CGFloat) -> Bool {
        let (lineAcross, markAcross) = vertical
            ? ((line.minX, line.maxX), (mark.minX, mark.maxX))
            : ((line.minY, line.maxY), (mark.minY, mark.maxY))
        let overlap = min(lineAcross.1, markAcross.1) - max(lineAcross.0, markAcross.0)
        guard overlap >= 0.5 * min(lineAcross.1 - lineAcross.0, markAcross.1 - markAcross.0) else { return false }
        let (lineAlong, markAlong) = vertical
            ? ((line.minY, line.maxY), (mark.minY, mark.maxY))
            : ((line.minX, line.maxX), (mark.minX, mark.maxX))
        let gap = max(markAlong.0 - lineAlong.1, lineAlong.0 - markAlong.1)
        return gap <= thickness * 1.5
    }

    /// Reads area (pixels, origin bottom-left) on a white margin, returning lines normalized to the whole image
    private static func readCrop(
        _ area: CGRect, of image: CGImage, padding: CGFloat, read: (CGImage) throws -> [RecognizedLine]
    ) throws -> [RecognizedLine]? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pad = padding.rounded()
        let flipped = CGRect(x: area.minX, y: height - area.maxY, width: area.width, height: area.height)
        guard let piece = image.cropping(to: flipped),
              let context = CGContext(
                  data: nil, width: Int(area.width + 2 * pad), height: Int(area.height + 2 * pad),
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(canvas)
        context.draw(piece, in: CGRect(x: pad, y: pad, width: area.width, height: area.height))
        guard let cropImage = context.makeImage() else { return nil }

        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (area.minX - pad + point.x * canvas.width) / width,
                y: (area.minY - pad + point.y * canvas.height) / height
            )
        }
        let found = try read(cropImage).map { line in
            var placed = RecognizedLine(
                text: line.text,
                topLeft: place(line.topLeft), topRight: place(line.topRight),
                bottomLeft: place(line.bottomLeft), bottomRight: place(line.bottomRight)
            )
            placed.confidence = line.confidence
            return placed
        }
        return found.isEmpty ? nil : found
    }

    /// Where a line no other line was replaced by goes in reading order: after the nearest line
    /// before it in the same column (above, or to the right for vertical Japanese)
    private static func insertionIndex(for line: CGRect, vertical: Bool, in rects: [CGRect]) -> Int {
        func sameColumn(_ other: CGRect) -> Bool {
            vertical
                ? min(other.maxY, line.maxY) > max(other.minY, line.minY)
                : min(other.maxX, line.maxX) > max(other.minX, line.minX)
        }
        func distanceBefore(_ other: CGRect) -> CGFloat {
            vertical ? other.midX - line.midX : other.midY - line.midY
        }
        let column = rects.indices.filter { sameColumn(rects[$0]) }
        if let previous = column.filter({ distanceBefore(rects[$0]) > 0 }).min(by: { distanceBefore(rects[$0]) < distanceBefore(rects[$1]) }) {
            return previous + 1
        }
        if let next = column.filter({ distanceBefore(rects[$0]) <= 0 }).max(by: { distanceBefore(rects[$0]) < distanceBefore(rects[$1]) }) {
            return next
        }
        return rects.count
    }

    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    }
}

/// Which cells of an image hold ink (anything clearly unlike the page's background), and which of
/// those recognized lines cover
private final class InkGrid {
    let cell: Int
    private let columns: Int, rows: Int
    private var ink: [Bool]
    private var covered: [Bool]

    init?(_ image: CGImage, cell: Int) {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        let stride = context.bytesPerRow

        var histogram = [Int](repeating: 0, count: 256)
        for y in 0..<height {
            let row = pixels + y * stride
            for x in 0..<width { histogram[Int(row[x])] += 1 }
        }
        let background = histogram.indices.max { histogram[$0] < histogram[$1] }!

        self.cell = cell
        columns = (width + cell - 1) / cell
        rows = (height + cell - 1) / cell
        var counts = [Int](repeating: 0, count: columns * rows)
        for y in 0..<height {
            // Memory rows run from the top; grid rows from the bottom
            let row = pixels + y * stride
            let gridRow = (height - 1 - y) / cell
            for x in 0..<width where abs(Int(row[x]) - background) > 80 {
                counts[gridRow * columns + x / cell] += 1
            }
        }
        let enough = max(1, cell * cell / 20)
        ink = counts.map { $0 >= enough }
        covered = [Bool](repeating: false, count: columns * rows)
    }

    /// rect: pixels with the origin at the bottom-left
    func cover(_ rect: CGRect) {
        let fromColumn = max(0, Int((rect.minX / CGFloat(cell)).rounded()))
        let toColumn = min(columns, Int((rect.maxX / CGFloat(cell)).rounded()))
        let fromRow = max(0, Int((rect.minY / CGFloat(cell)).rounded()))
        let toRow = min(rows, Int((rect.maxY / CGFloat(cell)).rounded()))
        guard fromColumn < toColumn, fromRow < toRow else { return }
        for row in fromRow..<toRow {
            for column in fromColumn..<toColumn { covered[row * columns + column] = true }
        }
    }

    /// Bounding rectangles (pixels, origin bottom-left) of uncovered ink, joining marks closer
    /// than joining to each other so letters make words and lines
    func uncoveredMarks(joining: CGFloat) -> [CGRect] {
        let reach = max(1, Int((joining / CGFloat(cell)).rounded(.up)))
        var seen = [Bool](repeating: false, count: columns * rows)
        var marks: [CGRect] = []
        for start in ink.indices where ink[start] && !covered[start] && !seen[start] {
            seen[start] = true
            var stack = [start]
            var minColumn = Int.max, maxColumn = Int.min, minRow = Int.max, maxRow = Int.min
            while let index = stack.popLast() {
                let column = index % columns, row = index / columns
                minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                for r in max(0, row - reach)...min(rows - 1, row + reach) {
                    for c in max(0, column - reach)...min(columns - 1, column + reach) {
                        let next = r * columns + c
                        if ink[next], !covered[next], !seen[next] {
                            seen[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            marks.append(CGRect(
                x: minColumn * cell, y: minRow * cell,
                width: (maxColumn - minColumn + 1) * cell, height: (maxRow - minRow + 1) * cell
            ))
        }
        return marks
    }
}
