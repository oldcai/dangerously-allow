import XCTest
@testable import DangerouslyAllowCore

/// Fixtures reproduce what `tmux capture-pane -p` actually yields for each
/// harness. Gemini's markers come from BaseSelectionList.js (`●` selected,
/// two spaces otherwise); Claude Code frames its menu in a rounded box and
/// marks the highlighted row with `❯`.
enum Fixture {
    static let gemini = """
     ╭────────────────────────────────────────╮
     │  Shell  rm -rf ./build                 │
     ╰────────────────────────────────────────╯

    Allow execution of: 'rm'?

    ● 1. Allow once
      2. Allow for this session
      3. Allow for all future sessions
      4. Modify with external editor
      5. No, suggest changes (esc)
    """

    static let claudeCode = """
    ╭──────────────────────────────────────────────╮
    │ Bash command                                 │
    │                                              │
    │   npm install                                │
    │   Install dependencies                       │
    │                                              │
    │ Do you want to proceed?                      │
    │ ❯ 1. Yes                                     │
    │   2. Yes, and don't ask again for npm        │
    │      commands in /Users/oldcai               │
    │   3. No, and tell Claude what to do          │
    │      differently (esc)                       │
    ╰──────────────────────────────────────────────╯
    """

    /// The exact prompt shape from the user's report.
    static let claudeApps = """
    ╭──────────────────────────────────────────────╮
    │ Do you want to proceed?                      │
    │   1. Allow once                              │
    │ ❯ 2. Allow for this session (0 apps)         │
    │   3. No, and tell Claude what to do          │
    │      differently (esc)                       │
    ╰──────────────────────────────────────────────╯
    """
}

final class PromptDetectorTests: XCTestCase {
    // MARK: - Gemini CLI

    func testGeminiSessionPolicyTargetsSecondOption() throws {
        let p = try XCTUnwrap(PromptDetector.detect(screen: Fixture.gemini, policy: .session))
        XCTAssertEqual(p.options.count, 5)
        XCTAssertEqual(p.cursorIndex, 0, "● marks option 1")
        XCTAssertEqual(p.target.number, 2)
        XCTAssertEqual(p.target.label, "Allow for this session")
        XCTAssertEqual(p.target.kind, .allowSession)
    }

    func testGeminiOncePolicyTargetsFirstOption() throws {
        let p = try XCTUnwrap(PromptDetector.detect(screen: Fixture.gemini, policy: .once))
        XCTAssertEqual(p.target.number, 1)
        XCTAssertEqual(p.target.kind, .allowOnce)
    }

    func testGeminiAlwaysPolicyTargetsThirdOption() throws {
        let p = try XCTUnwrap(PromptDetector.detect(screen: Fixture.gemini, policy: .always))
        XCTAssertEqual(p.target.number, 3)
        XCTAssertEqual(p.target.kind, .allowAlways)
    }

    func testGeminiNeutralOptionIsNeverTargeted() {
        for policy in AllowPolicy.allCases {
            let p = PromptDetector.detect(screen: Fixture.gemini, policy: policy)
            XCTAssertNotEqual(p?.target.label, "Modify with external editor")
            XCTAssertNotEqual(p?.target.kind, .deny)
        }
    }

    // MARK: - Claude Code

    func testClaudeCodeStripsBoxBordersAndFindsCursor() throws {
        let p = try XCTUnwrap(PromptDetector.detect(screen: Fixture.claudeCode, policy: .session))
        XCTAssertEqual(p.options.count, 3)
        XCTAssertEqual(p.cursorIndex, 0, "❯ marks option 1")
    }

    /// A wrapped label must be rejoined, or "…don't ask again for npm" would be
    /// classified without the directory it applies to.
    func testClaudeCodeRejoinsWrappedLabel() throws {
        let p = try XCTUnwrap(PromptDetector.detect(screen: Fixture.claudeCode, policy: .session))
        XCTAssertEqual(
            p.options[1].label,
            "Yes, and don't ask again for npm commands in /Users/oldcai"
        )
        XCTAssertEqual(p.options[1].kind, .allowAlways)
        XCTAssertEqual(p.options[2].label, "No, and tell Claude what to do differently (esc)")
        XCTAssertEqual(p.options[2].kind, .deny)
    }

    /// No session option exists here, so `session` falls back to the one-time
    /// "Yes" — and must not reach for "don't ask again".
    func testClaudeCodeSessionPolicyFallsBackToOnceNotAlways() throws {
        let p = try XCTUnwrap(PromptDetector.detect(screen: Fixture.claudeCode, policy: .session))
        XCTAssertEqual(p.target.number, 1)
        XCTAssertEqual(p.target.label, "Yes")
    }

    func testClaudeAppsPromptFromUserReport() throws {
        let p = try XCTUnwrap(PromptDetector.detect(screen: Fixture.claudeApps, policy: .session))
        XCTAssertEqual(p.target.number, 2)
        XCTAssertEqual(p.target.label, "Allow for this session (0 apps)")
        XCTAssertEqual(p.cursorIndex, 1, "cursor already sits on the target")
        XCTAssertEqual(PromptDetector.nextStep(cursor: 1, target: p.targetIndex), .confirm)
    }

    // MARK: - Non-escalation

    func testSessionPolicyRefusesWhenOnlyPermanentGrantOffered() {
        let screen = """
        Do you want to proceed?
        ❯ 1. Allow for all future sessions
          2. No, suggest changes (esc)
        """
        XCTAssertNil(
            PromptDetector.detect(screen: screen, policy: .session),
            "session policy must not click a permanent grant"
        )
        XCTAssertNotNil(PromptDetector.detect(screen: screen, policy: .always))
    }

    // MARK: - False positives

    func testIgnoresNumberedListWithoutDenyOption() {
        let screen = """
        Here is what I will do?
        ❯ 1. Yes
          2. Allow for this session
        """
        XCTAssertNil(PromptDetector.detect(screen: screen, policy: .session))
    }

    func testIgnoresNumberedListWithoutTriggerLine() {
        let screen = """
        Steps I took while refactoring the parser module.
        ❯ 1. Yes
          2. No, suggest changes
        """
        XCTAssertNil(PromptDetector.detect(screen: screen, policy: .session))
        XCTAssertNotNil(
            PromptDetector.detect(screen: screen, policy: .session, requireTrigger: false)
        )
    }

    func testPicksBottomMostMenuWhenAnOldOneScrolledAbove() throws {
        let screen = """
        Allow execution of: 'ls'?
        ● 1. Allow once
          2. Allow for this session
          3. No, suggest changes (esc)

        ... command finished ...

        Allow execution of: 'rm'?
          1. Allow once
        ● 2. Allow for this session
          3. No, suggest changes (esc)
        """
        let p = try XCTUnwrap(PromptDetector.detect(screen: screen, policy: .session))
        XCTAssertEqual(p.cursorIndex, 1, "must read the live menu at the bottom, not the stale one")
        XCTAssertEqual(p.options.count, 3)
    }

    // MARK: - never-approve

    func testBlockingPatternMatchesDangerousCommand() {
        XCTAssertEqual(
            PromptDetector.blockingPattern(screen: Fixture.gemini, neverApprove: ["rm -rf"]),
            "rm -rf"
        )
        XCTAssertNil(
            PromptDetector.blockingPattern(screen: Fixture.gemini, neverApprove: ["git push"])
        )
    }

    // MARK: - Navigation

    func testNextStep() {
        XCTAssertEqual(PromptDetector.nextStep(cursor: 0, target: 2), .down)
        XCTAssertEqual(PromptDetector.nextStep(cursor: 3, target: 1), .up)
        XCTAssertEqual(PromptDetector.nextStep(cursor: 1, target: 1), .confirm)
        XCTAssertEqual(NavStep.down.tmuxKey, "Down")
        XCTAssertEqual(NavStep.up.tmuxKey, "Up")
        XCTAssertEqual(NavStep.confirm.tmuxKey, "Enter")
    }

    func testFingerprintIsStableAcrossCursorMovement() throws {
        let before = try XCTUnwrap(PromptDetector.detect(screen: Fixture.gemini, policy: .session))
        let moved = Fixture.gemini
            .replacingOccurrences(of: "● 1. Allow once", with: "  1. Allow once")
            .replacingOccurrences(of: "  2. Allow for this session", with: "● 2. Allow for this session")
        let after = try XCTUnwrap(PromptDetector.detect(screen: moved, policy: .session))
        XCTAssertEqual(before.fingerprint, after.fingerprint)
        XCTAssertEqual(after.cursorIndex, 1)
        XCTAssertEqual(PromptDetector.nextStep(cursor: 1, target: after.targetIndex), .confirm)
    }
}
