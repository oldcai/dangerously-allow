import Foundation

/// Reads a pane into the two views the adjudication path needs: the bare
/// `MenuRow`s handed to a model, and the rule engine's own `PromptOption`s
/// (with its kind guesses) that get reconciled against the model's labels.
public enum MenuScan {
    public struct Result {
        /// Non-empty visible lines, oldest first — the command under review.
        public let context: [String]
        public let rows: [MenuRow]
        public let ruleOptions: [PromptOption]
    }

    public static func scan(_ screen: String) -> Result {
        let lines = screen.components(separatedBy: .newlines).map(ScreenParser.normalize)
        let block = ScreenParser.lastBlock(ScreenParser.rawOptions(in: lines))
        var rows: [MenuRow] = []
        var ruleOptions: [PromptOption] = []
        for (i, raw) in block.enumerated() {
            let next = i + 1 < block.count ? block[i + 1].line : nil
            let label = ScreenParser.fullLabel(for: raw, nextOptionLine: next, lines: lines)
            rows.append(MenuRow(number: raw.number, label: label))
            ruleOptions.append(PromptOption(
                number: raw.number,
                label: label,
                kind: OptionClassifier.classify(label),
                isCursor: raw.cursor,
                line: raw.line
            ))
        }
        let context = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Result(context: context, rows: rows, ruleOptions: ruleOptions)
    }

    /// Stable identity of a menu, so it is adjudicated exactly once while it lingers.
    public static func fingerprint(_ rows: [MenuRow]) -> String {
        rows.map { "\($0.number).\($0.label)" }.joined(separator: "|")
    }

    /// Cursor and target positions for the current frame — the closed-loop input
    /// to arrow-key navigation, keyed off the chosen option number.
    public static func navigationState(
        for screen: String, targetNumber: Int
    ) -> (fingerprint: String, cursorIndex: Int?, targetIndex: Int?)? {
        let result = scan(screen)
        guard result.rows.count >= 2 else { return nil }
        // The raw block and `result.rows` share order, so a cursor index found in
        // one lines up with the other; the fingerprint uses `scan`'s rejoined
        // labels so it matches the gate the caller computed from `scan`.
        let lines = screen.components(separatedBy: .newlines).map(ScreenParser.normalize)
        let block = ScreenParser.lastBlock(ScreenParser.rawOptions(in: lines))
        return (
            fingerprint(result.rows),
            block.firstIndex(where: { $0.cursor }),
            result.rows.firstIndex(where: { $0.number == targetNumber })
        )
    }
}
