import Foundation

/// Which grant tier each channel is willing to press. They differ by default
/// because the same word means different things in the two places: "Allow" on
/// a TCC dialog is written to disk and outlives the process, while "Allow once"
/// on an in-app card really is one-shot. So the dialog channel needs `always`
/// to do anything at all, and the card channel can afford to stay cautious.
public struct DesktopPolicies {
    public var dialog: AllowPolicy
    public var card: AllowPolicy

    public init(dialog: AllowPolicy = .always, card: AllowPolicy = .session) {
        self.dialog = dialog
        self.card = card
    }
}

public enum DesktopRoute {
    /// A native macOS permission dialog — TCC. Answered permanently.
    case systemDialog(DetectedSystemDialog)
    /// An approval card or notification banner inside an app we watch.
    case card(DetectedButtonPrompt)
    /// Nothing here to answer.
    case ignored
}

/// Decides which detector owns a window, for the single-process desktop mode.
///
/// The order is a safety rule, not a preference. A TCC dialog belonging to a
/// watched app — "“ChatGPT” wants access to control “FastMD”" is a window of
/// ChatGPT — satisfies `ButtonPromptDetector`'s grant-and-refusal invariant
/// just as well as an approval card does, and that detector reads a plain
/// "Allow" as `.allowOnce`. Routed there, the cautious card policy would press
/// a permanent system grant believing it was a one-shot. So the system-dialog
/// detector is asked first and its answer is final: a window it claims is never
/// re-examined as a card, not even when its policy declines to press anything.
public enum DesktopRouter {
    public static func route(
        window: UINode,
        cardsAllowed: Bool,
        policies: DesktopPolicies,
        requireTrigger: Bool = true
    ) -> DesktopRoute {
        switch SystemDialogDetector.detect(
            root: window, policy: policies.dialog, requireTrigger: requireTrigger
        ) {
        case let .dialog(dialog):
            return .systemDialog(dialog)
        case .skipped:
            guard cardsAllowed,
                  let card = ButtonPromptDetector.detect(
                      root: window, policy: policies.card, requireTrigger: requireTrigger
                  )
            else { return .ignored }
            return .card(card)
        }
    }
}

/// The apps whose in-app approval cards are answered. This list is the safety
/// boundary for the card channel: system dialogs are recognised by wording
/// wherever they appear, but a card is just buttons, and "Allow"/"Deny" on some
/// unrelated web page is not ours to answer. Bundle ids, because localized
/// names are not stable.
public enum AgentApps {
    public static let defaults: [String] = [
        "com.openai.codex",              // the ChatGPT desktop app
        "com.anthropic.claudefordesktop", // the Claude desktop app
        "com.apple.notificationcenterui", // banners, whoever posted them
    ]

    /// Matches a localized name or a bundle id, either way round, so
    /// `--app Cursor` and `--app com.todesktop.…` both work.
    public static func isWatched(name: String?, bundleID: String?, in needles: [String]) -> Bool {
        let name = (name ?? "").lowercased()
        let bundleID = (bundleID ?? "").lowercased()
        return needles.contains { needle in
            let needle = needle.lowercased()
            guard !needle.isEmpty else { return false }
            return name == needle || bundleID == needle
                || (!name.isEmpty && name.contains(needle))
                || bundleID.contains(needle)
        }
    }
}
