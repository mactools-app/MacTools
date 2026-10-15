import CoreGraphics

/// Rebuilds reading layout from Vision's scattered text fragments. Joining fragments by vertical order alone
/// loses indentation, side-by-side columns, and paragraph gaps. A clear vertical gutter splits columns first;
/// each column then groups fragments into visual rows and places them at absolute character columns.
enum TextLayout {
    struct Fragment {
        let text: String
        /// Vision's normalized rectangle with a bottom-left origin.
        let box: CGRect
    }

    static func lines(from fragments: [Fragment]) -> [String] {
        guard !fragments.isEmpty else { return [] }
        let (rows, bands) = group(fragments)
        // The median glyph width falls between half- and full-width characters in mixed CJK and Latin text.
        let charWidth = max(median(fragments.compactMap {
            $0.text.isEmpty ? nil : $0.box.width / CGFloat($0.text.count)
        }), 1e-6)
        // Each column recurses with its own glyph width and left edge, so the right column is not indented
        // by the left column's offset.
        if let (left, right) = columnSplit(fragments, bands: bands, charWidth: charWidth) {
            return lines(from: left) + [""] + lines(from: right)
        }

        // Calibrate blank lines against the median row pitch. Vision boxes hug glyphs, so box height would
        // misread normal line spacing as paragraph breaks.
        let pitch = max(median(zip(bands.dropLast(), bands.dropFirst()).map { $0.midY - $1.midY }), 1e-6)
        let left = bands.map(\.minX).min() ?? 0

        var out: [String] = []
        for (i, row) in rows.enumerated() {
            // A clearly larger step is a blank line or paragraph gap; cap large whitespace at two lines.
            if i > 0 {
                let step = bands[i - 1].midY - bands[i].midY
                if step > pitch * 1.6 {
                    out += Array(repeating: "", count: min(2, max(1, Int((step / pitch).rounded()) - 1)))
                }
            }
            // Place each fragment at its absolute column instead of accumulating gaps,
            // so table cells that share a left edge line up.
            var text = ""
            for fragment in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                let column = spaces(fragment.box.minX - left, charWidth)
                if text.count < column {
                    text += String(repeating: " ", count: column - text.count)
                } else if !text.isEmpty {
                    text += " "
                }
                text += fragment.text
            }
            out.append(text)
        }
        return out
    }

    /// Fragments overlapping vertically by at least half belong to one visual row.
    private static func group(_ fragments: [Fragment]) -> ([[Fragment]], [CGRect]) {
        var rows: [[Fragment]] = []
        var bands: [CGRect] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let band = bands.last, overlaps(band, fragment.box) {
                rows[rows.count - 1].append(fragment)
                bands[bands.count - 1] = band.union(fragment.box)
            } else {
                rows.append([fragment])
                bands.append(fragment.box)
            }
        }
        return (rows, bands)
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY)) >= 0.5 * min(a.height, b.height)
    }

    /// Finds a vertical gutter separating two columns. All three conditions must hold, preferring no split
    /// over reading a table column by column: the gutter is wider than word spacing, each side has enough
    /// rows, and the rows on both sides do not line up. Table cells share rows, so the last check rejects them.
    private static func columnSplit(_ fragments: [Fragment], bands: [CGRect],
                                    charWidth: CGFloat) -> ([Fragment], [Fragment])? {
        guard fragments.count >= 8 else { return nil }
        let bounds = bands.dropFirst().reduce(bands[0]) { $0.union($1) }
        let minWidth = max(3 * charWidth, 0.04 * bounds.width)

        var cursor = bounds.minX
        var candidates: [(CGFloat, CGFloat)] = []
        for box in fragments.map(\.box).sorted(by: { $0.minX < $1.minX }) {
            if box.minX - cursor >= minWidth { candidates.append((cursor, box.minX)) }
            cursor = max(cursor, box.maxX)
        }

        for (lo, hi) in candidates.sorted(by: { $1.1 - $1.0 < $0.1 - $0.0 }) {
            let left = fragments.filter { $0.box.maxX <= lo }
            let right = fragments.filter { $0.box.minX >= hi }
            guard left.count + right.count == fragments.count else { continue }
            let leftBands = group(left).1, rightBands = group(right).1
            guard leftBands.count >= 4, rightBands.count >= 4 else { continue }
            let paired = leftBands.filter { l in rightBands.contains { overlaps(l, $0) } }.count
            if Double(paired) / Double(leftBands.count) < 0.8 { return (left, right) }
        }
        return nil
    }

    private static func spaces(_ gap: CGFloat, _ charWidth: CGFloat) -> Int {
        // Cap malformed boxes so they cannot produce thousands of spaces.
        min(200, max(0, Int((gap / charWidth).rounded())))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}
