import XCTest
@testable import DangerouslyAllowCore

final class ScreenParserTests: XCTestCase {
    func testStripANSIRemovesColourAndCursorSequences() {
        let colored = "\u{1B}[32m● 1. Allow once\u{1B}[0m"
        XCTAssertEqual(ScreenParser.stripANSI(colored), "● 1. Allow once")
        XCTAssertEqual(ScreenParser.stripANSI("\u{1B}[2K\u{1B}[1;31mhi\u{1B}[m"), "hi")
    }

    func testNormalizeStripsBoxBordersButKeepsIndent() {
        XCTAssertEqual(ScreenParser.normalize("│ ❯ 1. Yes                 │"), " ❯ 1. Yes")
        XCTAssertEqual(ScreenParser.normalize("│   2. Yes, and don't ask  │"), "   2. Yes, and don't ask")
        XCTAssertEqual(ScreenParser.normalize("│      commands in /x      │"), "      commands in /x")
        // No border: leading indent survives untouched.
        XCTAssertEqual(ScreenParser.normalize("  2. Allow for this session"), "  2. Allow for this session")
    }

    func testNormalizeLeavesHorizontalRulesUnmatched() {
        let line = ScreenParser.normalize("╭──────────╮")
        XCTAssertTrue(ScreenParser.rawOptions(in: [line]).isEmpty)
    }

    func testRawOptionsDetectsCursorGlyphs() {
        let lines = ["❯ 1. Yes", "  2. No, suggest changes"].map(ScreenParser.normalize)
        let opts = ScreenParser.rawOptions(in: lines)
        XCTAssertEqual(opts.count, 2)
        XCTAssertTrue(opts[0].cursor)
        XCTAssertFalse(opts[1].cursor)
    }

    /// `◯` is the *unselected* radio glyph. Treating it as a cursor would make
    /// the watcher press Enter on the wrong row.
    func testUnselectedGlyphIsNotACursor() {
        let lines = ["◯ 1. Allow once", "● 2. Allow for this session"].map(ScreenParser.normalize)
        let opts = ScreenParser.rawOptions(in: lines)
        XCTAssertEqual(opts.count, 2)
        XCTAssertFalse(opts[0].cursor, "◯ means this row is NOT selected")
        XCTAssertTrue(opts[1].cursor)
    }

    func testRawOptionsAcceptsParenStyleNumbering() {
        let opts = ScreenParser.rawOptions(in: [ScreenParser.normalize("  1) Allow once")])
        XCTAssertEqual(opts.first?.number, 1)
        XCTAssertEqual(opts.first?.label, "Allow once")
    }

    func testLastBlockRequiresStartAtOne() {
        let lines = ["  7. Seven", "  8. Eight"].map(ScreenParser.normalize)
        XCTAssertTrue(ScreenParser.lastBlock(ScreenParser.rawOptions(in: lines)).isEmpty)
    }

    func testLastBlockRejectsDistantStrayNumbers() {
        var lines = ["  1. One"]
        lines.append(contentsOf: Array(repeating: "filler", count: 8))
        lines.append("  2. Two")
        let normalized = lines.map(ScreenParser.normalize)
        XCTAssertTrue(
            ScreenParser.lastBlock(ScreenParser.rawOptions(in: normalized)).isEmpty,
            "an option 8 lines away is not part of this menu"
        )
    }

    func testFullLabelStopsAtLessIndentedLine() {
        let lines = [
            "  2. Yes, and don't ask again for npm",
            "     commands in /Users/oldcai",
            "  3. No",
        ].map(ScreenParser.normalize)
        let opts = ScreenParser.rawOptions(in: lines)
        let joined = ScreenParser.fullLabel(for: opts[0], nextOptionLine: opts[1].line, lines: lines)
        XCTAssertEqual(joined, "Yes, and don't ask again for npm commands in /Users/oldcai")
    }
}
