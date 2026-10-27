import CoreGraphics

/// Puts recognized lines in reading order, for recognizers that return lines top to bottom across
/// the whole page. That order interleaves the columns of a two-column page, and a viewer then
/// selects from both columns while the pointer moves down one.
public enum ReadingOrder {
    /// Narrowest empty strip that separates columns, as a share of the page width
    static let columnGap: CGFloat = 0.01

    /// boxes: line boxes with the origin at the bottom-left. Returns their indices in reading
    /// order, found by cutting the page along empty strips (recursive XY-cut): columns are split
    /// left to right wherever an empty vertical strip runs through a block; where none does, the
    /// block is split top to bottom at its widest empty horizontal strip, so a heading or page
    /// number that straddles the columns does not hold them together.
    public static func order(_ boxes: [CGRect], pageWidth: CGFloat) -> [Int] {
        cut(Array(boxes.indices), boxes: boxes, minimumGap: pageWidth * columnGap)
    }

    private static func cut(_ indices: [Int], boxes: [CGRect], minimumGap: CGFloat) -> [Int] {
        guard indices.count > 1 else { return indices }

        let columns = groups(indices, boxes: boxes, start: { boxes[$0].minX }, end: { boxes[$0].maxX }, minimumGap: minimumGap)
        if columns.count > 1 {
            return columns.flatMap { cut($0, boxes: boxes, minimumGap: minimumGap) }
        }

        // Rows from the top: y grows upwards, so sort by the negated extent
        let rows = groups(indices, boxes: boxes, start: { -boxes[$0].maxY }, end: { -boxes[$0].minY }, minimumGap: 0)
        guard rows.count > 1 else {
            return indices.sorted { boxes[$0].maxY != boxes[$1].maxY ? boxes[$0].maxY > boxes[$1].maxY : boxes[$0].minX < boxes[$1].minX }
        }
        // Split once at the widest gap and look again at each side, where columns may now separate
        var widest = 0
        var widestGap = -CGFloat.infinity
        for i in 0..<(rows.count - 1) {
            let above = rows[i].map { boxes[$0].minY }.min()!
            let below = rows[i + 1].map { boxes[$0].maxY }.max()!
            if above - below > widestGap {
                widestGap = above - below
                widest = i
            }
        }
        let upper = rows[...widest].flatMap { $0 }
        let lower = rows[(widest + 1)...].flatMap { $0 }
        return cut(upper, boxes: boxes, minimumGap: minimumGap) + cut(lower, boxes: boxes, minimumGap: minimumGap)
    }

    /// Splits lines into runs along one axis wherever an empty strip wider than minimumGap separates them
    private static func groups(
        _ indices: [Int],
        boxes: [CGRect],
        start: (Int) -> CGFloat,
        end: (Int) -> CGFloat,
        minimumGap: CGFloat
    ) -> [[Int]] {
        var groups: [(end: CGFloat, members: [Int])] = []
        for index in indices.sorted(by: { start($0) < start($1) }) {
            if let last = groups.indices.last, start(index) <= groups[last].end + minimumGap {
                groups[last].end = max(groups[last].end, end(index))
                groups[last].members.append(index)
            } else {
                groups.append((end(index), [index]))
            }
        }
        return groups.map(\.members)
    }
}
