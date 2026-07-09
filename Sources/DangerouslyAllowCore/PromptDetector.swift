import Foundation

public struct PromptOption: Equatable {
    public let number: Int
    public let label: String
    public let kind: OptionKind
    public let isCursor: Bool
    public let line: Int
}

public struct DetectedPrompt: Equatable {
    public let options: [PromptOption]
    /// Index into `options` of the highlighted row, or nil when no glyph was found.
    public let cursorIndex: Int?
    /// Index into `options` of the row we intend to confirm.
    public let targetIndex: Int
    /// Stable identity of this prompt, used to avoid double-confirming.
    public let fingerprint: String

    public var target: PromptOption { options[targetIndex] }
}

/// The single key to press next, recomputed from a fresh capture each step.
public enum NavStep: Equatable {
    case up
    case down
    case confirm

    /// tmux `send-keys` key name.
    public var tmuxKey: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .confirm: return "Enter"
        }
    }
}

public enum PromptDetector {
    /// Phrases that mark the text above a menu as a permission question.
    public static let defaultTriggers: [String] = [
        "do you want to", "allow execution of", "wants to", "would like to",
        "permission", "approve", "proceed?", "allow ", "requires approval",
    ]

    /// How far above the first option we look for the question line.
    public static let triggerWindow = 15

    /// Close the loop: given a freshly captured cursor position, what to press.
    public static func nextStep(cursor: Int, target: Int) -> NavStep {
        if cursor == target { return .confirm }
        return cursor < target ? .down : .up
    }

    /// Returns the first `neverApprove` pattern that matches the screen, if any.
    /// Patterns are case-insensitive regexes matched against the whole pane.
    public static func blockingPattern(screen: String, neverApprove: [String]) -> String? {
        let flat = ScreenParser.stripANSI(screen)
        for pattern in neverApprove {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(location: 0, length: (flat as NSString).length)
            if re.firstMatch(in: flat, range: range) != nil { return pattern }
        }
        return nil
    }

    static func hasTrigger(lines: [String], beforeLine: Int, phrases: [String]) -> Bool {
        let start = max(0, beforeLine - triggerWindow)
        guard start < beforeLine else { return false }
        for line in lines[start..<beforeLine] {
            let lowered = line.lowercased()
            if phrases.contains(where: { lowered.contains($0) }) { return true }
            // Generic fallback: the harness asked a question right above the menu.
            if lowered.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return true }
        }
        return false
    }

    public static func detect(
        screen: String,
        policy: AllowPolicy,
        requireTrigger: Bool = true,
        triggers: [String] = defaultTriggers
    ) -> DetectedPrompt? {
        let lines = screen.components(separatedBy: .newlines).map(ScreenParser.normalize)
        let block = ScreenParser.lastBlock(ScreenParser.rawOptions(in: lines))
        guard block.count >= 2 else { return nil }

        var options: [PromptOption] = []
        for (i, raw) in block.enumerated() {
            let next = i + 1 < block.count ? block[i + 1].line : nil
            let label = ScreenParser.fullLabel(for: raw, nextOptionLine: next, lines: lines)
            options.append(PromptOption(
                number: raw.number,
                label: label,
                kind: OptionClassifier.classify(label),
                isCursor: raw.cursor,
                line: raw.line
            ))
        }

        // A permission prompt always offers a way out. Requiring both an allow
        // and a deny keeps us off ordinary numbered lists the agent printed.
        guard options.contains(where: { $0.kind == .deny }),
              options.contains(where: { $0.kind.grantsAccess })
        else { return nil }

        if requireTrigger,
           !hasTrigger(lines: lines, beforeLine: block[0].line, phrases: triggers) {
            return nil
        }

        // First match wins inside a tier, so the narrower grant is preferred
        // ("Allow tool for this session" before "Allow all server tools …").
        var targetIndex: Int?
        for kind in policy.preference {
            if let i = options.firstIndex(where: { $0.kind == kind }) {
                targetIndex = i
                break
            }
        }
        guard let target = targetIndex else { return nil }

        return DetectedPrompt(
            options: options,
            cursorIndex: options.firstIndex(where: { $0.isCursor }),
            targetIndex: target,
            fingerprint: options.map { "\($0.number).\($0.label)" }.joined(separator: "|")
        )
    }
}
