import Foundation

/// Maps a rendered menu label onto an `OptionKind`.
///
/// Label wording comes from the real harnesses:
///   Gemini CLI  ToolConfirmationMessage.js  — "Allow once", "Allow for this
///               session", "Allow for all future sessions",
///               "Allow tool for this session", "Modify with external editor",
///               "No, suggest changes (esc)"
///   Claude Code — "Yes", "Yes, and don't ask again for <x>",
///               "Yes, allow all edits during this session",
///               "Yes, and bypass permissions",
///               "Allow for this session (0 apps)",
///               "No, and tell Claude what to do differently",
///               "Deny, and tell Claude what to do differently"
public enum OptionClassifier {
    static let denyFirstWords: Set<String> = [
        "no", "n", "deny", "don't", "dont", "cancel", "reject", "abort", "never", "stop",
    ]
    static let denyPhrases: [String] = [
        "suggest changes", "what to do differently", "do not allow", "don't allow",
    ]
    /// Checked before `alwaysPhrases`, so "don't ask again this session" stays session-scoped.
    static let sessionPhrases: [String] = [
        "this session", "the session",
    ]
    static let alwaysPhrases: [String] = [
        "all future session", "don't ask again", "dont ask again", "do not ask again",
        "always", "bypass permissions", "all future",
    ]
    static let allowFirstWords: Set<String> = [
        "yes", "y", "allow", "proceed", "ok", "okay", "continue", "approve", "accept",
    ]

    /// First token, lowercased, stripped of trailing punctuation.
    static func firstWord(_ label: String) -> String {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespaces)
        let token = lowered.split(whereSeparator: { " ,.:;!".contains($0) }).first ?? ""
        return String(token)
    }

    public static func classify(_ label: String) -> OptionKind {
        let lowered = label.lowercased()
        let first = firstWord(label)

        // Refusals win: a label may mention "allow" while refusing
        // ("do not allow"), so deny is checked before anything else.
        if denyFirstWords.contains(first) { return .deny }
        if denyPhrases.contains(where: { lowered.contains($0) }) { return .deny }

        // "Trust folder" (Gemini CLI's startup gate) is written to the trusted-
        // folders settings and lets that folder's config execute code later. It
        // outlives the process, so it is a permanent grant no matter how the
        // label is worded — which keeps it out of the default `session` policy.
        if first == "trust" { return .allowAlways }

        // Everything past here must open with an affirmative verb, otherwise
        // it is a neutral item such as "Modify with external editor".
        guard allowFirstWords.contains(first) else { return .neutral }

        if sessionPhrases.contains(where: { lowered.contains($0) }) { return .allowSession }
        if alwaysPhrases.contains(where: { lowered.contains($0) }) { return .allowAlways }
        return .allowOnce
    }
}
