import Foundation

/// One button on a native macOS permission dialog.
public struct SystemDialogOption: Equatable {
    public let id: Int
    public let label: String
    public let kind: OptionKind

    public init(id: Int, label: String, kind: OptionKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public struct DetectedSystemDialog {
    /// Every labelled button on the dialog, in tree order.
    public let options: [SystemDialogOption]
    /// The button the policy allows pressing. nil = this is a real permission
    /// dialog, but nothing on it is acceptable — leave it for a human.
    public let target: SystemDialogOption?
    /// The dialog's own wording, excluding button labels.
    public let dialogText: String
    /// Wording plus button labels; what `--never-approve` vetoes on.
    public let fullText: String
    /// Stable across rescans of the same dialog; ids are deliberately excluded.
    public let fingerprint: String
}

/// Why a window was passed over. Surfaced by `--verbose` so an unrecognised
/// dialog can be diagnosed without guessing at the AX tree.
public enum SystemDialogSkip: Equatable {
    /// Nothing to press, or far too much — an app window, not a dialog.
    case notADialog(buttons: Int)
    /// No permission wording anywhere in it.
    case noPermissionWording
    /// Permission wording, but no button that grants anything.
    case noGrant
}

public enum SystemDialogScan {
    case dialog(DetectedSystemDialog)
    case skipped(SystemDialogSkip)
}

/// Finds a native macOS permission dialog — Microphone, Screen Recording,
/// Accessibility, Location — in a window's accessibility tree.
///
/// It is deliberately *not* `ButtonPromptDetector`. That one requires a card to
/// offer both a grant and a refusal, on the grounds that every real permission
/// prompt offers a way out. A system dialog often does not: macOS 15's
/// screen-capture prompt offers "Allow" and "Open System Settings", and the way
/// out is Esc. So the gate here is different — the wording (system-generated,
/// far more reliable than a TUI's), the dialog shape, and a grant tier that
/// tells the truth about how long the grant lasts.
public enum SystemDialogDetector {
    /// A permission dialog carries a handful of buttons. More than this is an
    /// ordinary window that happens to mention a service name.
    static let maxOptions = 5

    /// Wording taken from shipped dialogs, not guessed.
    static let permissionKeywords: [String] = [
        // The classic TCC sentence, unchanged for a decade.
        "would like to access", "would like to use",
        "would like to record", "would like to control",
        "wants to access", "wants to use", "wants to control",
        // Apple Events (Automation), which builds its sentence from a different
        // verb frame and names no service: "“ChatGPT” wants access to control
        // “FastMD”. Allowing control will provide access to documents and data
        // in “FastMD”, and to perform actions within that app."
        "wants access to", "allowing control will",
        // macOS 15 / ScreenCaptureKit, which names neither a verb from the list
        // above nor a service: "…is requesting to bypass the system private
        // window picker and directly access your screen and audio."
        "is requesting to", "is requesting access", "requests access to",
        "private window picker",
        "access your screen", "record your screen", "system audio",
        // Two more that lead with a verb the frames above do not cover.
        "devices on your local network", "send you notifications",
        // Dialogs that lead with the service name instead of a sentence.
        "microphone", "camera", "screen recording", "accessibility",
        "speech recognition", "input monitoring", "full disk access",
        "automation", "developer tools", "location",
    ]

    /// The only grants on a system dialog that really do expire. Everything
    /// else is written to the TCC database and survives a relaunch — including
    /// "While Using the App", which reads bounded and is not: it is a permanent
    /// entry carrying a usage condition.
    static let boundedGrantPhrases: [String] = ["once", "this time"]

    /// A grant here outlives the process, so it is `.allowAlways` however
    /// mildly its button is worded — a plain "Allow" on a TCC dialog is a
    /// permanent grant, and the default `session` policy declines it.
    public static func classify(_ label: String) -> OptionKind {
        let kind = OptionClassifier.classify(label)
        guard kind.grantsAccess else { return kind }
        let lowered = OptionClassifier.foldApostrophes(label).lowercased()
        if boundedGrantPhrases.contains(where: { lowered.contains($0) }) { return kind }
        return .allowAlways
    }

    public static func detect(
        root: UINode, policy: AllowPolicy, requireTrigger: Bool = true
    ) -> SystemDialogScan {
        var buttons: [UINode] = []
        var texts: [String] = []
        collect(root, buttons: &buttons, texts: &texts)

        let labelled = buttons.filter { !$0.label.isEmpty }
        guard !labelled.isEmpty, labelled.count <= maxOptions else {
            return .skipped(.notADialog(buttons: labelled.count))
        }

        let dialogText = texts.joined(separator: " ")
        if requireTrigger {
            let lowered = dialogText.lowercased()
            guard permissionKeywords.contains(where: { lowered.contains($0) }) else {
                return .skipped(.noPermissionWording)
            }
        }

        let options = labelled.map {
            SystemDialogOption(id: $0.id, label: $0.label, kind: classify($0.label))
        }
        guard options.contains(where: { $0.kind.grantsAccess }) else {
            return .skipped(.noGrant)
        }

        // The policy walks its preference chain — most persistent grant it
        // accepts first — and never escalates past it. Deny and neutral are
        // structurally unreachable: they are in no preference list, which is
        // what keeps "Open System Settings" and "Don't Allow" unpressable.
        let target = policy.preference.lazy
            .compactMap { kind in options.first(where: { $0.kind == kind }) }
            .first

        let labels = options.map(\.label)
        return .dialog(
            DetectedSystemDialog(
                options: options,
                target: target,
                dialogText: dialogText,
                fullText: dialogText + " " + labels.joined(separator: " "),
                fingerprint: labels.joined(separator: "|") + "\u{a7}" + dialogText
            )
        )
    }

    /// Buttons are leaves — their wording belongs to the option, not to the
    /// dialog, so `--never-approve` can tell the two apart.
    private static func collect(_ node: UINode, buttons: inout [UINode], texts: inout [String]) {
        if node.role == "AXButton" {
            buttons.append(node)
            return
        }
        if !node.label.isEmpty { texts.append(node.label) }
        if !node.text.isEmpty { texts.append(node.text) }
        for child in node.children { collect(child, buttons: &buttons, texts: &texts) }
    }
}
