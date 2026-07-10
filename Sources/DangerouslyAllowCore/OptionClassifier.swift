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
        "decline", "close", "dismiss",
    ]
    static let denyPhrases: [String] = [
        "suggest changes", "what to do differently", "do not allow", "don't allow",
    ]
    /// Checked before `alwaysPhrases`, so "don't ask again this session" stays session-scoped.
    /// "this conversation" is the ChatGPT desktop app's session-scoped grant —
    /// it expires with the conversation, not with the machine.
    static let sessionPhrases: [String] = [
        "this session", "the session", "this conversation", "the conversation", "this chat",
    ]
    static let alwaysPhrases: [String] = [
        "all future session", "don't ask again", "dont ask again", "do not ask again",
        "always", "bypass permissions", "all future",
    ]
    static let allowFirstWords: Set<String> = [
        "yes", "y", "allow", "proceed", "ok", "okay", "continue", "approve", "accept",
    ]
    /// Folder/workspace trust behind an affirmative — "Yes, I trust this folder" —
    /// outlives the process, so it is caught before the grant-tier phrases can
    /// mistake it for a one-time allow. Only ever consulted for a row that has
    /// already opened with an affirmative verb: these are substrings, and
    /// "Do not trust this folder" contains one while refusing.
    static let trustPhrases: [String] = [
        "trust this folder", "trust the folder", "trust folder", "trust parent folder",
        "trust this directory", "trust the files", "trust the workspace",
    ]

    /// macOS spells its refusal button "Don’t Allow", and TUIs vary. Fold the
    /// typographic apostrophe onto the ASCII one so a single spelling of
    /// "don't" drives `denyFirstWords` and `alwaysPhrases` alike — otherwise
    /// "Yes, and don’t ask again" misses `alwaysPhrases`, falls through to
    /// `.allowOnce`, and the default `session` policy clicks a permanent grant.
    static func foldApostrophes(_ label: String) -> String {
        label.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
    }

    /// First token, lowercased, stripped of trailing punctuation.
    static func firstWord(_ label: String) -> String {
        word(label, at: 0)
    }

    static func secondWord(_ label: String) -> String {
        word(label, at: 1)
    }

    private static func word(_ label: String, at index: Int) -> String {
        let lowered = foldApostrophes(label).lowercased().trimmingCharacters(in: .whitespaces)
        let tokens = lowered.split(whereSeparator: { " ,.:;!".contains($0) })
        return index < tokens.count ? String(tokens[index]) : ""
    }

    public static func classify(_ label: String) -> OptionKind {
        let lowered = foldApostrophes(label).lowercased()
        let first = firstWord(label)

        // Refusals win: a label may mention "allow" while refusing
        // ("do not allow"), so deny is checked before anything else.
        if denyFirstWords.contains(first) { return .deny }
        if denyPhrases.contains(where: { lowered.contains($0) }) { return .deny }

        // Gemini CLI's startup gate leads with the verb: "Trust folder". It is
        // written to the trusted-folders settings and lets that folder's config
        // execute code in every future session, so it outlives the process and
        // stays out of the default `session` policy.
        if first == "trust" { return .allowAlways }

        // "Always allow" (the ChatGPT desktop app) leads with the persistence
        // word rather than the verb. The verb decides: "Always deny" refuses,
        // "Always on top" is just a setting.
        if first == "always" {
            let second = secondWord(label)
            if denyFirstWords.contains(second) { return .deny }
            if allowFirstWords.contains(second) { return .allowAlways }
            return .neutral
        }

        // Everything past here must open with an affirmative verb, otherwise
        // it is a neutral item such as "Modify with external editor" — or a
        // refusal the deny guards did not name, like "Do not trust this folder".
        guard allowFirstWords.contains(first) else { return .neutral }

        // Claude Code's "Yes, I trust this folder" is folder trust behind an
        // affirmative. Checked before the grant tiers, so it cannot be read as a
        // one-time allow, nor as a session grant by a trailing "this session".
        if trustPhrases.contains(where: { lowered.contains($0) }) { return .allowAlways }

        if sessionPhrases.contains(where: { lowered.contains($0) }) { return .allowSession }
        if alwaysPhrases.contains(where: { lowered.contains($0) }) { return .allowAlways }
        return .allowOnce
    }
}
