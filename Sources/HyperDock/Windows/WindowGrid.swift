import AppKit

/// Lays a set of windows out as a grid filling one screen.
///
/// Halves and quarters stop being useful past about three windows, and a large external
/// display is exactly where people keep six or eight terminals open at once. This is the
/// arrangement for that case.
enum WindowGrid {

    /// The grid to use for `count` windows.
    ///
    /// The shape comes from the screen's own proportions, not from a square root. A square
    /// root answers 3×3 for eight windows; on a display half again as wide as it is tall,
    /// what people actually want is 4×2 — and the wider the display, the more the answer
    /// should lean to columns. Deriving rows from the aspect ratio gives 2×1 for two
    /// windows, 2×2 for four, 3×2 for six and 4×2 for eight on a 16:10 screen, which is
    /// the progression a person would draw by hand.
    ///
    /// `fixedColumns` and `fixedRows` override it when the user has said what they want;
    /// zero means "decide for me".
    static func shape(for count: Int,
                      in area: CGRect,
                      fixedColumns: Int = 0,
                      fixedRows: Int = 0) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (1, 1) }

        if fixedColumns > 0 && fixedRows > 0 { return (fixedColumns, fixedRows) }
        if fixedColumns > 0 {
            return (fixedColumns, max(1, Int((Double(count) / Double(fixedColumns)).rounded(.up))))
        }
        if fixedRows > 0 {
            return (max(1, Int((Double(count) / Double(fixedRows)).rounded(.up))), fixedRows)
        }

        let ratio = area.width > 0 ? Double(area.height / area.width) : 1
        let rows = max(1, Int((Double(count) * ratio).squareRoot().rounded()))
        let columns = max(1, Int((Double(count) / Double(rows)).rounded(.up)))
        return (columns, rows)
    }

    /// One frame per window, in the order they should be filled: left to right, top row
    /// first.
    ///
    /// A final row that is not full spreads its windows across the whole width instead of
    /// leaving a hole. Five windows in a 3×2 grid therefore read as three over two, which
    /// is what a person tiling five windows draws — not three over two-and-a-gap.
    static func frames(count: Int,
                       in area: CGRect,
                       fixedColumns: Int = 0,
                       fixedRows: Int = 0,
                       gap: CGFloat = 0) -> [CGRect] {
        guard count > 0 else { return [] }
        let (columns, rows) = shape(for: count, in: area,
                                    fixedColumns: fixedColumns, fixedRows: fixedRows)

        let rowHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var frames: [CGRect] = []
        frames.reserveCapacity(count)

        for row in 0..<rows {
            let remaining = count - row * columns
            guard remaining > 0 else { break }
            let inThisRow = min(columns, remaining)
            let cellWidth = (area.width - gap * CGFloat(inThisRow - 1)) / CGFloat(inThisRow)

            for column in 0..<inThisRow {
                // AppKit's y grows upward, so the first row is the top one.
                let y = area.maxY - CGFloat(row + 1) * rowHeight - CGFloat(row) * gap
                let x = area.minX + CGFloat(column) * (cellWidth + gap)
                frames.append(CGRect(x: x, y: y, width: cellWidth, height: rowHeight))
            }
        }
        return frames
    }
}
