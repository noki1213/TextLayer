import CoreGraphics
import Foundation
import TextRecognition

/// Renders a page the way it is shown (crop box, page rotation) and reads its text, returning the
/// lines placed in the page's default user space.
enum PageOCR {
    /// Pixels along the shorter side of the rendered page
    static let shortSide: CGFloat = 2000
    /// Tiles along the longer side are at most this many times as long as they are wide, so a
    /// page made of stitched scrolling screenshots is still read at full size. Wide enough that a
    /// 16:9 slide is read whole
    static let maxTileAspect: CGFloat = 2.2
    static let tileOverlap: CGFloat = 0.12

    static func recognize(_ page: CGPDFPage, renderLock: NSLock) throws -> [PlacedLine] {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 1, box.height > 1 else { return [] }
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let turned = rotation == 90 || rotation == 270
        let displayWidth = turned ? box.height : box.width
        let displayHeight = turned ? box.width : box.height
        let scale = min(4, max(1, shortSide / min(displayWidth, displayHeight)))
        let pixelWidth = (displayWidth * scale).rounded(.up)
        let pixelHeight = (displayHeight * scale).rounded(.up)

        // Page user space to pixels of the whole rendered page (origin bottom-left)
        let w = box.width, h = box.height
        let turn: CGAffineTransform
        switch rotation {
        case 90: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: turn = .identity
        }
        let toPixels = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            .concatenating(turn)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let toPage = toPixels.inverted()

        let vertical = pixelHeight >= pixelWidth
        let along = vertical ? pixelHeight : pixelWidth
        let across = vertical ? pixelWidth : pixelHeight
        let tileLength = min(along, (across * maxTileAspect).rounded(.up))
        let overlap = (tileLength * tileOverlap).rounded()
        let step = tileLength - overlap
        var starts: [CGFloat] = [0]
        while starts.last! + tileLength < along { starts.append(min(starts.last! + step, along - tileLength)) }

        var found: [(text: String, rect: CGRect, direction: Direction)] = []
        for (index, start) in starts.enumerated() {
            let tile = vertical
                ? CGRect(x: 0, y: start, width: pixelWidth, height: tileLength)
                : CGRect(x: start, y: 0, width: tileLength, height: pixelHeight)
            // Neighbouring tiles share their overlap at its middle; a line belongs to the tile its centre falls in
            let keepFrom = index == 0 ? -CGFloat.infinity : (starts[index - 1] + tileLength + start) / 2
            let keepTo = index == starts.count - 1 ? CGFloat.infinity : (start + tileLength + starts[index + 1]) / 2

            guard let image = render(page, transform: toPixels, tile: tile, lock: renderLock) else { continue }
            for line in try TextRecognizer.recognizeLines(in: image) {
                let rect = CGRect(
                    x: tile.minX + line.box.minX * tile.width,
                    y: tile.minY + line.box.minY * tile.height,
                    width: line.box.width * tile.width,
                    height: line.box.height * tile.height
                )
                let centre = vertical ? rect.midY : rect.midX
                guard centre >= keepFrom, centre < keepTo else { continue }
                let run = CGVector(
                    dx: (line.bottomRight.x - line.bottomLeft.x) * tile.width,
                    dy: (line.bottomRight.y - line.bottomLeft.y) * tile.height
                )
                found.append((line.text, rect, Direction(run)))
            }
        }

        // Kept clear of the neighbouring lines across their reading direction
        var rects = found.map(\.rect)
        let horizontal = found.indices.filter { !found[$0].direction.isVertical }
        let down = found.indices.filter { found[$0].direction.isVertical }
        for (index, rect) in zip(horizontal, LineBoxes.separated(horizontal.map { rects[$0] })) { rects[index] = rect }
        let transposed = LineBoxes.separated(down.map { rects[$0].transposed }).map(\.transposed)
        for (index, rect) in zip(down, transposed) { rects[index] = rect }

        let order = TextRecognizer.linesAreInReadingOrder
            ? Array(found.indices)
            : ReadingOrder.order(found.map(\.rect), pageWidth: pixelWidth)
        return order.map { index in
            let (origin, end, top) = found[index].direction.corners(of: rects[index])
            let o = origin.applying(toPage), e = end.applying(toPage), t = top.applying(toPage)
            return PlacedLine(
                text: found[index].text,
                origin: o,
                run: CGVector(dx: e.x - o.x, dy: e.y - o.y),
                rise: CGVector(dx: t.x - o.x, dy: t.y - o.y)
            )
        }
    }

    /// Which way a line reads on the rendered page
    enum Direction {
        case right, down, up, left

        init(_ run: CGVector) {
            if abs(run.dx) >= abs(run.dy) {
                self = run.dx >= 0 ? .right : .left
            } else {
                self = run.dy <= 0 ? .down : .up
            }
        }

        var isVertical: Bool { self == .down || self == .up }

        /// Where the text starts, where it ends, and the top of its first glyph
        func corners(of rect: CGRect) -> (CGPoint, CGPoint, CGPoint) {
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
    }

    /// Greyscale is enough for text and a quarter of the memory of RGBA
    private static func render(_ page: CGPDFPage, transform: CGAffineTransform, tile: CGRect, lock: NSLock) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(tile.width),
            height: Int(tile.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        context.interpolationQuality = .high
        context.translateBy(x: -tile.minX, y: -tile.minY)
        context.concatenate(transform)
        lock.lock()
        context.drawPDFPage(page)
        lock.unlock()
        return context.makeImage()
    }
}

private extension CGRect {
    var transposed: CGRect { CGRect(x: minY, y: minX, width: height, height: width) }
}
