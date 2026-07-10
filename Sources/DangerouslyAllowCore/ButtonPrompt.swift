import Foundation

/// A pruned accessibility node — just enough of an AX tree to find an approval
/// card in it. `id` is the caller's handle back to the live element (or
/// notification action) so the chosen option can be pressed.
public struct UINode {
    public let id: Int
    public let role: String
    /// Accessible name: AXTitle, falling back to AXDescription.
    public let label: String
    /// Rendered text: the AXValue of static text and the like.
    public let text: String
    public let children: [UINode]

    public init(id: Int, role: String, label: String = "", text: String = "", children: [UINode] = []) {
        self.id = id
        self.role = role
        self.label = label
        self.text = text
        self.children = children
    }
}

public struct ButtonPromptOption: Equatable {
    public let id: Int
    public let label: String
    public let kind: OptionKind
}

public struct DetectedButtonPrompt {
    /// Every labelled, pressable thing on the card, in tree order.
    public let options: [ButtonPromptOption]
    /// The option the policy allows pressing. nil = the card is real, but
    /// nothing on it is acceptable under the policy — leave it for a human.
    public let target: ButtonPromptOption?
    /// The card's own wording — title, subtitle, the command it shows —
    /// excluding option labels.
    public let cardText: String
    /// Everything including option labels; what `--never-approve` vetoes on.
    public let fullText: String
    /// Stable across rescans of the same card; ids are deliberately excluded.
    public let fingerprint: String
}

/// Finds an approval card in a UI element tree: the GUI analogue of
/// `PromptDetector`. A card is a *small* subtree holding at least one option
/// that grants access and at least one that refuses — the same invariant the
/// TUI path relies on, because every real permission prompt offers a way out.
/// A lone "Allow" button, a toolbar, or a sidebar never qualifies.
public enum ButtonPromptDetector {
    /// Roles that can be pressed. "AXAction" is synthesised by the watcher for
    /// notification-banner actions, which AX exposes as actions *on* the
    /// banner element rather than as child buttons.
    static let pressableRoles: Set<String> = ["AXButton", "AXAction"]
    /// Options sit within this many levels of the card root — web renderers
    /// pad the way down with anonymous wrapper groups.
    static let maxHops = 8
    /// More pressable things than this is a toolbar, not a card.
    static let maxOptions = 8
    /// Wording every shipped approval card or permission banner carries.
    /// Sources: the ChatGPT desktop app's string table (approvalRequestCard.*,
    /// avatarOverlay.waitingRequest.* in app.asar) and macOS permission
    /// notification text.
    static let triggerKeywords: [String] = [
        "command", "file", "network", "access", "apply", "change", "connect",
        "install", "enable", "plan", "link", "review", "permission", "request",
        "wants to", "would like", "needs", "reason", "tool", "server", "allow",
        "approve", "run",
    ]

    public static func detect(
        root: UINode, policy: AllowPolicy, requireTrigger: Bool = true
    ) -> DetectedButtonPrompt? {
        var memo: [Int: Analysis] = [:]
        analyze(root, into: &memo)
        guard let card = firstQualifying(root, memo: memo, requireTrigger: requireTrigger),
              let analysis = memo[card.id]
        else { return nil }

        let options = analysis.options
            .filter { $0.depth <= maxHops && !$0.node.label.isEmpty }
            .map {
                ButtonPromptOption(
                    id: $0.node.id,
                    label: $0.node.label,
                    kind: OptionClassifier.classify($0.node.label)
                )
            }

        let cardText = analysis.texts.joined(separator: " ")
        let fullText = cardText + " " + options.map(\.label).joined(separator: " ")
        let fingerprint = options.map(\.label).joined(separator: "|") + "§" + cardText

        // The policy walks its preference chain — most persistent grant it
        // accepts first — and never escalates past it. Deny and neutral are
        // structurally unreachable: they are not in any preference list.
        let target = policy.preference.lazy
            .compactMap { kind in options.first(where: { $0.kind == kind }) }
            .first

        return DetectedButtonPrompt(
            options: options,
            target: target,
            cardText: cardText,
            fullText: fullText,
            fingerprint: fingerprint
        )
    }

    // MARK: - internals

    struct Analysis {
        /// Every pressable in the subtree, with its depth below this node.
        var options: [(node: UINode, depth: Int)] = []
        /// Text from everything that is not a pressable — the card's wording.
        var texts: [String] = []
    }

    @discardableResult
    private static func analyze(_ node: UINode, into memo: inout [Int: Analysis]) -> Analysis {
        var analysis = Analysis()
        if pressableRoles.contains(node.role) {
            // A pressable is a leaf: nested renderer buttons collapse into it,
            // and its inner text belongs to the option, not to the card.
            analysis.options = [(node, 0)]
        } else {
            if !node.label.isEmpty { analysis.texts.append(node.label) }
            if !node.text.isEmpty { analysis.texts.append(node.text) }
            for child in node.children {
                let sub = analyze(child, into: &memo)
                analysis.options += sub.options.map { ($0.node, $0.depth + 1) }
                analysis.texts += sub.texts
            }
        }
        memo[node.id] = analysis
        return analysis
    }

    /// Pre-order, so the *outermost* qualifying node wins — the full card,
    /// including options that sit apart from the main pair, like the ChatGPT
    /// card's "Always allow".
    private static func firstQualifying(
        _ node: UINode, memo: [Int: Analysis], requireTrigger: Bool
    ) -> UINode? {
        if qualifies(node, memo: memo, requireTrigger: requireTrigger) { return node }
        for child in node.children {
            if let found = firstQualifying(child, memo: memo, requireTrigger: requireTrigger) {
                return found
            }
        }
        return nil
    }

    private static func qualifies(
        _ node: UINode, memo: [Int: Analysis], requireTrigger: Bool
    ) -> Bool {
        guard let analysis = memo[node.id] else { return false }
        // Count every pressable in the whole subtree: a sidebar does not become
        // a card just because two of its many buttons pair up.
        guard analysis.options.count <= maxOptions else { return false }

        let kinds = analysis.options
            .filter { $0.depth <= maxHops && !$0.node.label.isEmpty }
            .map { OptionClassifier.classify($0.node.label) }
        guard kinds.contains(where: \.grantsAccess), kinds.contains(.deny) else { return false }

        if requireTrigger {
            let text = analysis.texts.joined(separator: " ").lowercased()
            guard triggerKeywords.contains(where: { text.contains($0) }) else { return false }
        }
        return true
    }
}
