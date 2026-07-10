import XCTest
@testable import DangerouslyAllowCore

/// The AX-tree analogue of PromptDetectorTests: an approval card is a small
/// subtree holding at least one grant button and at least one refusal button.
/// The trees below mimic the ChatGPT desktop app's (com.openai.codex) approval
/// card and the noise around it — sidebars full of buttons, wrapper groups the
/// web renderer inserts, notification banners exposing actions instead of
/// buttons.
final class ButtonPromptDetectorTests: XCTestCase {
    private var nextID = 0

    private func node(
        _ role: String, label: String = "", text: String = "", _ children: [UINode] = []
    ) -> UINode {
        nextID += 1
        return UINode(id: nextID, role: role, label: label, text: text, children: children)
    }

    private func btn(_ label: String) -> UINode { node("AXButton", label: label) }
    private func grp(_ children: [UINode], text: String = "") -> UINode {
        node("AXGroup", text: text, children)
    }

    /// The real card: header ("Review command" + the command), then a form with
    /// "Always allow" apart from the "Deny" / "Allow once" pair.
    private func chatGPTCard(subtitle: String = "make test") -> UINode {
        grp([
            grp([node("AXStaticText", text: "Review command"),
                 node("AXStaticText", text: subtitle)]),
            grp([
                btn("Always allow"),
                grp([btn("Deny"), grp([btn("Allow once")])]),
            ]),
        ])
    }

    private func detect(
        _ root: UINode, policy: AllowPolicy = .session, requireTrigger: Bool = true
    ) -> DetectedButtonPrompt? {
        ButtonPromptDetector.detect(root: root, policy: policy, requireTrigger: requireTrigger)
    }

    // MARK: - the ChatGPT approval card

    func testSessionPolicyFallsBackToAllowOnce() {
        let prompt = detect(chatGPTCard())
        XCTAssertNotNil(prompt)
        XCTAssertEqual(prompt?.target?.label, "Allow once")
        XCTAssertEqual(prompt?.target?.kind, .allowOnce)
    }

    func testAlwaysPolicyPicksAlwaysAllow() {
        let prompt = detect(chatGPTCard(), policy: .always)
        XCTAssertEqual(prompt?.target?.label, "Always allow")
        XCTAssertEqual(prompt?.target?.kind, .allowAlways)
    }

    func testOncePolicyPicksAllowOnce() {
        let prompt = detect(chatGPTCard(), policy: .once)
        XCTAssertEqual(prompt?.target?.label, "Allow once")
    }

    /// `--policy once` with no once-grant on the card must not escalate to
    /// "Always allow" — the card is reported, but with no target.
    func testPolicyNeverEscalatesOnCards() {
        let card = grp([
            grp([node("AXStaticText", text: "Review command")]),
            grp([btn("Always allow"), btn("Deny")]),
        ])
        let prompt = detect(card, policy: .once)
        XCTAssertNotNil(prompt)
        XCTAssertNil(prompt?.target)
    }

    /// All classified rows surface, so callers can log the full card.
    func testAllCardButtonsAreReported() {
        let prompt = detect(chatGPTCard())
        XCTAssertEqual(prompt?.options.count, 3)
        XCTAssertEqual(
            Set(prompt?.options.map(\.kind) ?? []), [.allowOnce, .allowAlways, .deny]
        )
    }

    // MARK: - refusing to fire

    func testGrantWithoutRefusalIsNotAPrompt() {
        let card = grp([
            grp([node("AXStaticText", text: "Review command")]),
            grp([btn("Allow once")]),
        ])
        XCTAssertNil(detect(card))
    }

    func testRefusalWithoutGrantIsNotAPrompt() {
        let card = grp([
            grp([node("AXStaticText", text: "Review command")]),
            grp([btn("Deny"), btn("Cancel")]),
        ])
        XCTAssertNil(detect(card))
    }

    /// A grant in one corner of the window and a Cancel in another do not make
    /// the window an approval card — they only qualify a *small* subtree.
    func testFarApartButtonsDoNotQualify() {
        func chain(_ depth: Int, _ leaf: UINode) -> UINode {
            depth == 0 ? leaf : grp([chain(depth - 1, leaf)])
        }
        let root = grp([
            chain(10, btn("Allow once")),
            chain(10, btn("Cancel")),
        ])
        XCTAssertNil(detect(root, requireTrigger: false))
    }

    /// A subtree stuffed with buttons (a sidebar, a toolbar) is not a card even
    /// if a grant and a refusal happen to sit in it.
    func testButtonHeavySubtreeIsNotACard() {
        var buttons = (1...12).map { btn("Task \($0)") }
        buttons.append(btn("Allow once"))
        buttons.append(btn("Cancel"))
        XCTAssertNil(detect(grp(buttons, text: "Review command")))
    }

    /// The card must carry request-like text ("Review command", "File access"…)
    /// unless the caller opts out.
    func testRequireTriggerRejectsWordlessCards() {
        let card = grp([
            grp([node("AXStaticText", text: "zzz")]),
            grp([btn("Allow once"), btn("Deny")]),
        ])
        XCTAssertNil(detect(card, requireTrigger: true))
        XCTAssertNotNil(detect(card, requireTrigger: false))
    }

    /// Button labels alone must not satisfy the trigger — the wording has to
    /// come from the card's own text, like the question line on a TUI menu.
    func testButtonLabelsDoNotSatisfyTheTrigger() {
        let card = grp([btn("Allow once"), btn("Deny")])
        XCTAssertNil(detect(card, requireTrigger: true))
    }

    // MARK: - the card inside a real window

    func testCardIsFoundInsideANoisyWindow() {
        let sidebar = grp((1...15).map { btn("Project \($0)") })
        let window = node("AXWindow", label: "ChatGPT", [
            grp([sidebar, grp([grp([chatGPTCard()])])]),
        ])
        let prompt = detect(window)
        XCTAssertEqual(prompt?.options.count, 3)
        XCTAssertEqual(prompt?.target?.label, "Allow once")
    }

    /// Web renderers wrap everything in anonymous groups; a card buried under
    /// several wrapper layers must still be one card.
    func testDeepWrapperChainsInsideTheCardAreTolerated() {
        func wrap(_ n: UINode, _ times: Int) -> UINode {
            times == 0 ? n : wrap(grp([n]), times - 1)
        }
        let card = grp([
            grp([node("AXStaticText", text: "Network access")]),
            grp([wrap(btn("Allow once"), 5), wrap(btn("Deny"), 5)]),
        ])
        let prompt = detect(card)
        XCTAssertEqual(prompt?.target?.label, "Allow once")
    }

    // MARK: - notification banners (actions, not buttons)

    /// Notification Center exposes a banner's buttons as AX *actions* on the
    /// banner element. The watcher surfaces them as action-role children.
    func testNotificationBannerActionsQualify() {
        let banner = grp([
            node("AXStaticText", text: "ChatGPT wants to run a command"),
            node("AXAction", label: "Allow"),
            node("AXAction", label: "Close"),
        ])
        let prompt = detect(banner)
        XCTAssertEqual(prompt?.target?.label, "Allow")
        XCTAssertEqual(prompt?.target?.kind, .allowOnce)
    }

    func testBannerWithNoGrantActionIsLeftAlone() {
        let banner = grp([
            node("AXStaticText", text: "Meeting in 5 minutes"),
            node("AXAction", label: "Snooze"),
            node("AXAction", label: "Close"),
        ])
        XCTAssertNil(detect(banner, requireTrigger: false))
    }

    // MARK: - fingerprints

    func testFingerprintIsStableAcrossRescans() {
        nextID = 0
        let a = detect(chatGPTCard())
        nextID = 1000 // fresh AX ids on the second scan, same card on screen
        let b = detect(chatGPTCard())
        XCTAssertEqual(a?.fingerprint, b?.fingerprint)
    }

    func testDifferentCommandsHaveDifferentFingerprints() {
        let a = detect(chatGPTCard(subtitle: "make test"))
        let b = detect(chatGPTCard(subtitle: "rm -rf /"))
        XCTAssertNotEqual(a?.fingerprint, b?.fingerprint)
    }

    /// The card's full text is exposed so `--never-approve` can veto on the
    /// command shown in it.
    func testCardTextCarriesTheCommandForVeto() {
        let prompt = detect(chatGPTCard(subtitle: "rm -rf /"))
        XCTAssertTrue(prompt?.fullText.contains("rm -rf /") ?? false)
    }
}
