import Foundation

/// What the adjudicated path decided for one captured screen.
public enum AdjudicatedOutcome: Equatable {
    /// No menu to act on (fewer than two options).
    case notAMenu
    /// Press the row with this on-screen number.
    case act(number: Int, label: String, kind: OptionKind)
    /// Leave it for a human, with a reason to log.
    case deferToHuman(String)
}

/// The LLM fallback, end to end, minus the network call and minus tmux I/O.
///
/// Rules reject a screen; this asks an `LLMAdjudicator` to label the rows,
/// reconciles those labels with the rule engine's (most-reluctant wins), and
/// then lets `AllowPolicy` pick the target from the reconciled kinds — the same
/// selection the rule path uses. The model never names a row to press, so it
/// cannot pick a refusal, and reconciliation means it cannot *lower* a grant's
/// persistence to slip one past the policy ceiling. Every uncertain branch
/// defers, because deferring is the recoverable direction.
public enum AdjudicatedDetector {
    public static func detect(
        screen: String, policy: AllowPolicy, adjudicator: LLMAdjudicator
    ) -> AdjudicatedOutcome {
        let scan = MenuScan.scan(screen)
        guard scan.ruleOptions.count >= 2 else { return .notAMenu }

        let judgment: PromptJudgment
        do {
            judgment = try adjudicator.judge(context: scan.context, options: scan.rows)
        } catch {
            return .deferToHuman("adjudicator failed: \(error)")
        }

        guard judgment.isPermissionPrompt else {
            return .deferToHuman("not a permission prompt: \(judgment.reason)")
        }
        do {
            try Adjudication.validate(judgment, against: scan.rows)
        } catch {
            return .deferToHuman("\(error)")
        }

        let merged = Adjudication.merge(rules: scan.ruleOptions, judgment: judgment)

        // Every real permission prompt offers a way out. If neither the rules nor
        // the model saw a refusal, this is probably not a permission prompt.
        guard merged.contains(.deny) else {
            return .deferToHuman("no refusal row — likely not a permission prompt")
        }

        // Pick as the rule path does: the first kind the policy accepts, which is
        // the narrowest grant offered within the allowed tier.
        for kind in policy.preference {
            if let i = merged.firstIndex(of: kind) {
                return .act(number: scan.ruleOptions[i].number, label: scan.ruleOptions[i].label, kind: kind)
            }
        }
        return .deferToHuman("no grant acceptable under policy '\(policy.rawValue)'")
    }
}
