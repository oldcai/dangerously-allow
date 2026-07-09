import XCTest
@testable import DangerouslyAllowCore

/// These fixtures are verbatim `tmux capture-pane -p` output from the real
/// harnesses, not hand-written approximations. They pin down the details that
/// are easy to get wrong: a leading space before the box border, the `●`
/// highlight glyph, and blank framed lines between rows.
final class RealCaptureTests: XCTestCase {
    /// Captured from `gemini` 0.31.0 on first run in an untrusted directory.
    static let geminiTrustFolder = """
     ╭──────────────────────────────────────────────────────────────────────────╮
     │                                                                          │
     │ Do you trust the files in this folder?                                   │
     │                                                                          │
     │ Trusting a folder allows Gemini CLI to load its local configurations,    │
     │ including custom commands, hooks, MCP servers, agent skills, and         │
     │ settings. These configurations could execute code on your behalf or      │
     │ change the behavior of the CLI.                                          │
     │                                                                          │
     │                                                                          │
     │ ● 1. Trust folder (dangerously_allow_permissions)                        │
     │   2. Trust parent folder (projects)                                      │
     │   3. Don't trust                                                         │
     │                                                                          │
    """

    func testParsesRealGeminiCaptureIncludingCursorAndBorders() {
        let lines = Self.geminiTrustFolder
            .components(separatedBy: .newlines)
            .map(ScreenParser.normalize)
        let opts = ScreenParser.rawOptions(in: lines)
        XCTAssertEqual(opts.count, 3)
        XCTAssertTrue(opts[0].cursor, "● survives capture-pane and marks row 1")
        XCTAssertEqual(opts[0].label, "Trust folder (dangerously_allow_permissions)")
        XCTAssertEqual(opts[2].label, "Don't trust")
    }

    func testFolderTrustClassifiedAsPermanentGrant() {
        XCTAssertEqual(
            OptionClassifier.classify("Trust folder (dangerously_allow_permissions)"),
            .allowAlways
        )
        XCTAssertEqual(OptionClassifier.classify("Trust parent folder (projects)"), .allowAlways)
        XCTAssertEqual(OptionClassifier.classify("Don't trust"), .deny)
    }

    /// The default policy must leave folder trust to a human: accepting it lets
    /// that directory's config execute code in every future session.
    func testDefaultSessionPolicyRefusesToTrustAFolder() {
        XCTAssertNil(
            PromptDetector.detect(screen: Self.geminiTrustFolder, policy: .session),
            "session policy must not auto-trust a folder"
        )
        XCTAssertNil(PromptDetector.detect(screen: Self.geminiTrustFolder, policy: .once))
    }

    /// Opting in explicitly picks the narrower grant: this folder, not its parent.
    func testAlwaysPolicyTrustsThisFolderNotTheParent() throws {
        let p = try XCTUnwrap(
            PromptDetector.detect(screen: Self.geminiTrustFolder, policy: .always)
        )
        XCTAssertEqual(p.target.number, 1)
        XCTAssertEqual(p.target.label, "Trust folder (dangerously_allow_permissions)")
        XCTAssertEqual(p.cursorIndex, 0)
    }

    /// Gemini's startup theme/auth pickers are numbered lists with no refusal
    /// row, so they must never be driven.
    func testIgnoresStartupPickersThatOfferNoRefusal() {
        let themePicker = """
        Select a theme?
        ● 1. Default Dark
          2. Default Light
          3. GitHub
        """
        for policy in AllowPolicy.allCases {
            XCTAssertNil(PromptDetector.detect(screen: themePicker, policy: policy))
        }
    }
}
