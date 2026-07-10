import Foundation

/// One menu row as handed to an adjudicator. Deliberately not `PromptOption`:
/// an adjudicator sees the number and the label, never the cursor, never the
/// rule engine's guess, and never the rest of the pane.
public struct MenuRow: Equatable {
    public let number: Int
    public let label: String

    public init(number: Int, label: String) {
        self.number = number
        self.label = label
    }
}

public struct OptionJudgment: Equatable {
    public let number: Int
    public let kind: OptionKind

    public init(number: Int, kind: OptionKind) {
        self.number = number
        self.kind = kind
    }
}

public struct PromptJudgment: Equatable {
    /// False for an ordinary numbered list, a theme picker, a model picker.
    public let isPermissionPrompt: Bool
    public let options: [OptionJudgment]
    public let reason: String

    public init(isPermissionPrompt: Bool, options: [OptionJudgment], reason: String) {
        self.isPermissionPrompt = isPermissionPrompt
        self.options = options
        self.reason = reason
    }
}

public enum AdjudicatorError: Error, CustomStringConvertible {
    case noCredentials
    case transport(String)
    case http(Int, String)
    case malformedResponse(String)
    /// The model answered about a different set of options than we asked about.
    case optionMismatch(expected: [Int], got: [Int])

    public var description: String {
        switch self {
        case .noCredentials:
            return "no API credentials: export ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN)"
        case let .transport(m): return "transport error: \(m)"
        case let .http(code, body): return "HTTP \(code): \(body.prefix(300))"
        case let .malformedResponse(m): return "malformed response: \(m)"
        case let .optionMismatch(expected, got):
            return "model answered about options \(got), asked about \(expected)"
        }
    }
}

/// Labels a menu. **It never chooses which row to press.**
///
/// The target is always picked afterwards by `AllowPolicy.preference`, which
/// contains grant kinds and nothing else. That keeps a model — and anything
/// that can write text onto the terminal it is reading — out of the
/// "should this be approved" decision, and confines it to "what does this
/// label mean". A mislabel can only make the watcher refuse or pick a less
/// persistent grant; it cannot make it press a row the policy forbids.
public protocol LLMAdjudicator {
    func judge(context: [String], options: [MenuRow]) throws -> PromptJudgment
}

public enum Adjudication {
    /// How reluctant we are to press a row, ascending. A deny is the most
    /// reluctant; a one-time allow the least.
    ///
    /// `allowAlways` outranks `allowSession` outranks `allowOnce` because the
    /// policy refuses the more persistent grants — so ranking a grant *higher*
    /// than it deserves loses an approval, while ranking it lower gives one
    /// away. Only one of those is recoverable.
    static func reluctance(_ kind: OptionKind) -> Int {
        switch kind {
        case .allowOnce: return 0
        case .allowSession: return 1
        case .allowAlways: return 2
        case .neutral: return 3
        case .deny: return 4
        }
    }

    /// Disagreement resolves to whichever source is more reluctant.
    ///
    /// Rule says `allowOnce`, model says `allowAlways` -> `allowAlways`, and
    /// the default `session` policy then leaves the prompt for a human. Rule
    /// says `allowOnce`, model says `deny` -> `deny`, and it is never pressed.
    /// There is no combination that produces a grant neither source claimed.
    public static func reconcile(rule: OptionKind, model: OptionKind) -> OptionKind {
        reluctance(model) > reluctance(rule) ? model : rule
    }

    /// Rejects a judgment that does not answer about exactly the rows we asked
    /// about, in any order. A model that invents, drops, or renumbers a row has
    /// not understood the menu, and we will not act on the rest of its answer.
    public static func validate(_ judgment: PromptJudgment, against rows: [MenuRow]) throws {
        let asked = rows.map(\.number).sorted()
        let answered = judgment.options.map(\.number).sorted()
        guard asked == answered else {
            throw AdjudicatorError.optionMismatch(expected: asked, got: answered)
        }
    }

    /// Merge rule kinds with model kinds, row by row, most-reluctant-wins.
    /// `rules` and `judgment` must already agree on the row numbers.
    public static func merge(rules: [PromptOption], judgment: PromptJudgment) -> [OptionKind] {
        let byNumber = Dictionary(
            judgment.options.map { ($0.number, $0.kind) }, uniquingKeysWith: { a, b in
                reluctance(a) > reluctance(b) ? a : b
            }
        )
        return rules.map { option in
            // A row the model did not label keeps the rule engine's verdict.
            guard let model = byNumber[option.number] else { return option.kind }
            return reconcile(rule: option.kind, model: model)
        }
    }
}