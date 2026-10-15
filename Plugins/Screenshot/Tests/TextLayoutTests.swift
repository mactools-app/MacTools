import CoreGraphics
import XCTest
@testable import ScreenshotPlugin

final class TextLayoutTests: XCTestCase {
    func testRestoresTableColumnsParagraphGapsAndIndentation() {
        let lines = TextLayout.lines(from: [
            fragment("indented", x: 0.14, width: 0.16, y: 0.58),
            fragment("Age", x: 0.30, width: 0.06, y: 0.90),
            fragment("30", x: 0.30, width: 0.04, y: 0.82),
            fragment("Name", x: 0.10, width: 0.08, y: 0.90),
            fragment("Bob", x: 0.10, width: 0.06, y: 0.82),
            fragment("Amy", x: 0.10, width: 0.06, y: 0.74),
            fragment("28", x: 0.30, width: 0.04, y: 0.74),
        ])
        XCTAssertEqual(lines, ["Name      Age", "Bob       30", "Amy       28", "", "  indented"])
        XCTAssertEqual(TextLayout.lines(from: [fragment("solo", x: 0.6, width: 0.08, y: 0.3)]), ["solo"])
    }

    func testKeepsAlignedTableRowsTogetherButSplitsOffsetSideBySidePanels() {
        let rows = [0.90, 0.82, 0.74, 0.66, 0.58]
        let table = rows.enumerated().flatMap { i, y in
            [fragment("row\(i)", x: 0.05, width: 0.20, y: y), fragment("val\(i)", x: 0.60, width: 0.20, y: y)]
        }
        let asTable = TextLayout.lines(from: table)
        XCTAssertEqual(asTable.count, 5, "A table must not be read column by column")
        XCTAssertTrue(asTable[0].hasPrefix("row0") && asTable[0].hasSuffix("val0"))

        let panels = rows.enumerated().flatMap { i, y in
            [fragment("Left row \(i)", x: 0.05, width: 0.30, y: y),
             fragment("Right col \(i)", x: 0.55, width: 0.30, y: y - 0.04)]
        }
        XCTAssertEqual(TextLayout.lines(from: panels),
                       (0...4).map { "Left row \($0)" } + [""] + (0...4).map { "Right col \($0)" })
    }

    private func fragment(_ text: String, x: CGFloat, width: CGFloat, y: CGFloat) -> TextLayout.Fragment {
        TextLayout.Fragment(text: text, box: CGRect(x: x, y: y, width: width, height: 0.06))
    }
}
