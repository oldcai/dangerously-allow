import Foundation

/// One menu row as it appears on screen.
public struct RawOption: Equatable {
    public let line: Int
    /// Leading spaces after box borders are removed. Wrapped continuation
    /// lines are indented further than their option, which is how we find them.
    public let indent: Int
    public let number: Int
    public let label: String
    /// True when the row carries the highlight glyph (`❯`, `●`, …).
    public let cursor: Bool
}

public enum ScreenParser {
    /// Glyphs a TUI uses to mark the *highlighted* row.
    /// Claude Code renders `❯`; Gemini CLI renders `●` (BaseSelectionList.js).
    public static let cursorGlyphs = "❯●▶➜▸›>*"

    /// Glyphs marking an *unselected* radio row. Must never count as a cursor —
    /// `◯` next to a row means that row is NOT the one that Enter will pick.
    public static let unselectedGlyphs = "◯○"

    /// Vertical box-drawing characters that frame Claude Code's prompt.
    static let borderChars = Set("│┃┆┇┊┋╏|")

    private static let ansiRegex = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*(\u{07}|\u{1B}\\\\)"
    )

    // ^indent  (cursor glyph)?  (unselected glyph)?  N. or N)   label
    private static let optionRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:([❯●▶➜▸›>\\*])[ \\t]*)?(?:([◯○])[ \\t]*)?(\\d{1,2})[.)][ \\t]+(\\S.*?)[ \\t]*$"
    )

    public static func stripANSI(_ s: String) -> String {
        let ns = s as NSString
        return ansiRegex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
    }

    /// Strip ANSI, trailing padding/borders, and *leading* box borders — while
    /// preserving the indentation that wrapped continuation lines rely on.
    ///
    ///     "│ ❯ 1. Yes            │"  ->  " ❯ 1. Yes"
    ///     "│      commands in /x │"  ->  "      commands in /x"
    public static func normalize(_ line: String) -> String {
        var chars = Array(stripANSI(line))
        while let last = chars.last, last.isWhitespace || borderChars.contains(last) {
            chars.removeLast()
        }
        var lastBorder: Int?
        var i = 0
        while i < chars.count, chars[i].isWhitespace || borderChars.contains(chars[i]) {
            if borderChars.contains(chars[i]) { lastBorder = i }
            i += 1
        }
        if let b = lastBorder { chars.removeFirst(b + 1) }
        return String(chars)
    }

    static func leadingIndent(_ s: String) -> Int {
        s.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    /// Every line that looks like a numbered menu row.
    public static func rawOptions(in lines: [String]) -> [RawOption] {
        var out: [RawOption] = []
        for (idx, line) in lines.enumerated() where !line.isEmpty {
            let ns = line as NSString
            guard let m = optionRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length)
            ) else { continue }
            guard let number = Int(ns.substring(with: m.range(at: 3))) else { continue }
            out.append(RawOption(
                line: idx,
                indent: leadingIndent(line),
                number: number,
                label: ns.substring(with: m.range(at: 4)),
                cursor: m.range(at: 1).location != NSNotFound
            ))
        }
        return out
    }

    /// Walk up from the bottom-most row collecting N, N-1, … 1.
    /// Tolerates wrapped labels between rows; rejects a stale list further up.
    static func lastBlock(_ opts: [RawOption], maxGap: Int = 6) -> [RawOption] {
        guard let last = opts.last else { return [] }
        var block = [last]
        var needed = last.number - 1
        var lowestLine = last.line
        var i = opts.count - 2
        while i >= 0, needed >= 1 {
            let o = opts[i]
            if o.number == needed, lowestLine - o.line <= maxGap {
                block.append(o)
                needed -= 1
                lowestLine = o.line
            }
            i -= 1
        }
        block.reverse()
        guard block.count >= 2, block.first?.number == 1 else { return [] }
        return block
    }

    /// Re-join a label that the TUI wrapped across lines. Continuation lines sit
    /// below the option and are indented past it.
    static func fullLabel(
        for option: RawOption, nextOptionLine: Int?, lines: [String], maxLines: Int = 3
    ) -> String {
        var parts = [option.label]
        let end = nextOptionLine ?? min(option.line + 1 + maxLines, lines.count)
        var j = option.line + 1
        var added = 0
        while j < end, j < lines.count, added < maxLines {
            let line = lines[j]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if leadingIndent(line) <= option.indent { break }
            parts.append(line.trimmingCharacters(in: .whitespaces))
            added += 1
            j += 1
        }
        return parts.joined(separator: " ")
    }
}
