import XCTest
@testable import DangerouslyAllowCore

/// The one-process desktop mode has to decide, per window, *which* detector
/// owns it — and the two detectors disagree about what a plain "Allow" means.
/// `SystemDialogDetector` calls it `.allowAlways`, because a TCC answer is
/// written to disk and outlives the process. `ButtonPromptDetector` calls it
/// `.allowOnce`, because an in-app card's "Allow once" really is one-shot.
///
/// A TCC dialog belonging to an app we also watch for cards — "ChatGPT wants
/// access to control FastMD" is a window of ChatGPT — is therefore reachable by
/// both, and routing it to the card path would silently press a permanent grant
/// under the cautious policy. The order below is a safety rule, not a
/// preference: system dialog first, card only if the window is not one.
final class DesktopRouterTests: XCTestCase {
    private var nextID = 0

    private func node(
        _ role: String, label: String = "", text: String = "", _ children: [UINode] = []
    ) -> UINode {
        nextID += 1
        return UINode(id: nextID, role: role, label: label, text: text, children: children)
    }

    private func btn(_ label: String) -> UINode { node("AXButton", label: label) }
    private func act(_ label: String) -> UINode { node("AXAction", label: label) }
    private func txt(_ text: String) -> UINode { node("AXStaticText", text: text) }
    private func grp(_ children: [UINode]) -> UINode { node("AXGroup", children) }
    private func win(_ children: [UINode]) -> UINode { node("AXWindow", children) }

    /// The Apple Events dialog, verbatim — a window of ChatGPT, which is also
    /// an app we press cards in.
    private func automationDialog() -> UINode {
        win([
            txt("\u{201C}ChatGPT\u{201D} wants access to control \u{201C}FastMD\u{201D}. Allowing "
                + "control will provide access to documents and data in \u{201C}FastMD\u{201D}."),
            btn("Don\u{2019}t Allow"),
            btn("Allow"),
        ])
    }

    /// The ChatGPT desktop app's browser-use card, transcribed from a live
    /// `--dump` of the running app.
    private func browserUseCard() -> UINode {
        win([grp([
            txt("Browser use"),
            txt("Allow upload to https://developer.apple.com/account/resources/certificates/add?"),
            grp([btn("Always allow"), btn("Deny"), btn("Allow once")]),
        ])])
    }

    // MARK: - the safety rule

    func testTccDialogInAWatchedAppRoutesToTheDialogPath() {
        guard case let .systemDialog(d) = DesktopRouter.route(
            window: automationDialog(), cardsAllowed: true, policies: DesktopPolicies()
        ) else { return XCTFail("a TCC dialog must never be routed as a card") }
        XCTAssertEqual(d.target?.label, "Allow")
        XCTAssertEqual(d.target?.kind, .allowAlways, "a TCC grant is permanent")
    }

    /// Proves the ordering is load-bearing rather than incidental: the card
    /// detector *does* match this dialog, and would press it under the cautious
    /// card policy having mistaken a permanent grant for a one-shot.
    func testWithoutTheOrderingTheCardPathWouldPressAPermanentGrant() {
        let asCard = ButtonPromptDetector.detect(root: automationDialog(), policy: .session)
        XCTAssertEqual(asCard?.target?.label, "Allow")
        XCTAssertEqual(asCard?.target?.kind, .allowOnce, "this is the misreading being guarded")
    }

    /// A real dialog the policy will not touch still belongs to the dialog
    /// path — it must be reported and left, never retried as a card.
    func testUnacceptableDialogDoesNotFallThroughToTheCardPath() {
        let policies = DesktopPolicies(dialog: .session, card: .session)
        guard case let .systemDialog(d) = DesktopRouter.route(
            window: automationDialog(), cardsAllowed: true, policies: policies
        ) else { return XCTFail("still a dialog, just not an acceptable one") }
        XCTAssertNil(d.target, "--policy session must leave a permanent grant to a human")
    }

    // MARK: - cards

    func testCardInAWatchedAppIsRouted() {
        guard case let .card(c) = DesktopRouter.route(
            window: browserUseCard(), cardsAllowed: true, policies: DesktopPolicies()
        ) else { return XCTFail("the browser-use card must be recognised") }
        XCTAssertEqual(c.target?.label, "Allow once", "cards default to the cautious grant")
    }

    /// The app allowlist is the safety boundary for cards: a web page with
    /// Allow/Deny buttons in some unrelated browser is not ours to answer.
    func testCardInAnUnwatchedAppIsIgnored() {
        guard case .ignored = DesktopRouter.route(
            window: browserUseCard(), cardsAllowed: false, policies: DesktopPolicies()
        ) else { return XCTFail("cards outside the watched apps must be left alone") }
    }

    /// Notification banners expose their buttons as AX *actions*, which the
    /// dialog detector cannot see — so they fall through to the card path.
    func testNotificationBannerRoutesToTheCardPath() {
        let banner = win([grp([
            txt("Claude"), txt("Allow access to your calendar?"),
            act("Allow"), act("Dismiss"),
        ])])
        guard case let .card(c) = DesktopRouter.route(
            window: banner, cardsAllowed: true, policies: DesktopPolicies()
        ) else { return XCTFail("banner actions must be reachable") }
        XCTAssertEqual(c.target?.label, "Allow")
    }

    func testOrdinaryWindowIsIgnored() {
        let window = win([txt("Inbox"), btn("Reply"), btn("Archive")])
        guard case .ignored = DesktopRouter.route(
            window: window, cardsAllowed: true, policies: DesktopPolicies()
        ) else { return XCTFail("an ordinary window must be left alone") }
    }

    // MARK: - which apps are watched

    func testWatchedAppMatchingAcceptsNamesAndBundleIDs() {
        let needles = AgentApps.defaults
        XCTAssertTrue(AgentApps.isWatched(name: "ChatGPT", bundleID: "com.openai.codex", in: needles))
        XCTAssertTrue(AgentApps.isWatched(
            name: "Claude", bundleID: "com.anthropic.claudefordesktop", in: needles
        ))
        XCTAssertTrue(AgentApps.isWatched(
            name: "Notification Center", bundleID: "com.apple.notificationcenterui", in: needles
        ))
        XCTAssertFalse(AgentApps.isWatched(name: "Safari", bundleID: "com.apple.Safari", in: needles))
        XCTAssertFalse(AgentApps.isWatched(name: "Notion", bundleID: "notion.id", in: needles))
    }

    func testExtraAppsCanBeNamedByLocalizedName() {
        let needles = AgentApps.defaults + ["Cursor"]
        XCTAssertTrue(AgentApps.isWatched(name: "Cursor", bundleID: "com.todesktop.x", in: needles))
    }
}
