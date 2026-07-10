import XCTest
@testable import DangerouslyAllowCore

final class OptionClassifierTests: XCTestCase {
    func testGeminiLabels() {
        XCTAssertEqual(OptionClassifier.classify("Allow once"), .allowOnce)
        XCTAssertEqual(OptionClassifier.classify("Allow for this session"), .allowSession)
        XCTAssertEqual(OptionClassifier.classify("Allow tool for this session"), .allowSession)
        XCTAssertEqual(OptionClassifier.classify("Allow all server tools for this session"), .allowSession)
        XCTAssertEqual(OptionClassifier.classify("Allow for all future sessions"), .allowAlways)
        XCTAssertEqual(OptionClassifier.classify("Allow tool for all future sessions"), .allowAlways)
        XCTAssertEqual(OptionClassifier.classify("Modify with external editor"), .neutral)
        XCTAssertEqual(OptionClassifier.classify("No, suggest changes (esc)"), .deny)
    }

    func testClaudeCodeLabels() {
        XCTAssertEqual(OptionClassifier.classify("Yes"), .allowOnce)
        XCTAssertEqual(OptionClassifier.classify("Allow for this session (0 apps)"), .allowSession)
        XCTAssertEqual(OptionClassifier.classify("Yes, allow all edits during this session"), .allowSession)
        XCTAssertEqual(
            OptionClassifier.classify("Yes, and allow Claude to edit its own settings for this session"),
            .allowSession
        )
        XCTAssertEqual(
            OptionClassifier.classify("Yes, and don't ask again for npm commands in /Users/oldcai"),
            .allowAlways
        )
        XCTAssertEqual(OptionClassifier.classify("Yes, and bypass permissions"), .allowAlways)
        XCTAssertEqual(OptionClassifier.classify("No, and tell Claude what to do differently"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Deny, and tell Claude what to do differently"), .deny)
    }

    /// The ChatGPT desktop app's (com.openai.codex) approval card. Labels come
    /// from the app bundle's string table (`approvalRequestCard.*`,
    /// `avatarOverlay.waitingRequest.*` in app.asar).
    func testChatGPTDesktopLabels() {
        XCTAssertEqual(OptionClassifier.classify("Allow once"), .allowOnce)
        XCTAssertEqual(OptionClassifier.classify("Always allow"), .allowAlways)
        XCTAssertEqual(OptionClassifier.classify("Allow this conversation"), .allowSession)
        XCTAssertEqual(OptionClassifier.classify("Deny"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Decline"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Cancel"), .deny)
        // Leading persistence word must not hide a refusal or invent a grant.
        XCTAssertEqual(OptionClassifier.classify("Never allow"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Always deny"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Always on top"), .neutral)
    }

    /// Folder trust is a permanent grant however it is worded — including Claude
    /// Code's affirmative "Yes, I trust this folder", which must not fall through
    /// to a one-time allow just because it starts with "Yes".
    func testFolderTrustIsAlwaysPermanent() {
        XCTAssertEqual(OptionClassifier.classify("Yes, I trust this folder"), .allowAlways)
        XCTAssertEqual(OptionClassifier.classify("Trust folder (dangerously_allow)"), .allowAlways)
        XCTAssertEqual(OptionClassifier.classify("Trust parent folder (projects)"), .allowAlways)
        // ...but a refusal that merely mentions trust stays a refusal.
        XCTAssertEqual(OptionClassifier.classify("No, don't trust this folder"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Don't trust"), .deny)
    }

    /// A refusal that names a trust phrase must never become a grant. The trust
    /// phrases are substrings, so they match inside "Do not trust this folder"
    /// too — only an affirmative row may be read as folder trust.
    func testNegatedTrustIsNeverAGrant() {
        for label in ["Do not trust this folder", "Exit (do not trust this folder)"] {
            XCTAssertNotEqual(
                OptionClassifier.classify(label), .allowAlways,
                "\"\(label)\" refuses; it must not be classified as a permanent grant"
            )
            XCTAssertFalse(
                OptionClassifier.classify(label).grantsAccess,
                "\"\(label)\" refuses; it must not grant access"
            )
        }
    }

    /// macOS and many TUIs render the apostrophe as U+2019. Folding it to ASCII
    /// keeps "don’t ask again" a permanent grant — otherwise it falls through to
    /// `.allowOnce` and the default `session` policy clicks it, which is exactly
    /// the grant this tool promises never to make.
    func testTypographicApostropheIsReadLikeAnASCIIOne() {
        XCTAssertEqual(OptionClassifier.classify("Yes, and don\u{2019}t ask again"), .allowAlways)
        XCTAssertEqual(
            OptionClassifier.classify("Yes, and don\u{2019}t ask again for npm commands"),
            .allowAlways
        )
        // Apple spells its refusal button with a typographic apostrophe.
        XCTAssertEqual(OptionClassifier.classify("Don\u{2019}t Allow"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Don\u{2019}t trust this folder"), .deny)
    }

    /// "this session" must win over "don't ask again" — the grant expires with
    /// the process, so it is a session grant, not a permanent one.
    func testSessionBeatsAlwaysWhenBothPhrasesPresent() {
        XCTAssertEqual(
            OptionClassifier.classify("Yes, and don't ask again this session"),
            .allowSession
        )
    }

    /// A label starting with "No..." must not be read as an allow just because
    /// it happens to contain the word "allow".
    func testDenyWinsOverAllowWording() {
        XCTAssertEqual(OptionClassifier.classify("No, do not allow this"), .deny)
        XCTAssertEqual(OptionClassifier.classify("Don't allow"), .deny)
    }

    /// "Normal mode" starts with the letters "no" but is not a refusal.
    func testFirstWordIsTokenNotPrefix() {
        XCTAssertEqual(OptionClassifier.classify("Normal mode"), .neutral)
        XCTAssertEqual(OptionClassifier.classify("Nothing to change"), .neutral)
    }

    func testPolicyNeverEscalates() {
        XCTAssertEqual(AllowPolicy.once.preference, [.allowOnce])
        XCTAssertEqual(AllowPolicy.session.preference, [.allowSession, .allowOnce])
        XCTAssertEqual(AllowPolicy.always.preference, [.allowAlways, .allowSession, .allowOnce])
        for policy in AllowPolicy.allCases {
            XCTAssertFalse(policy.preference.contains(.deny))
            XCTAssertFalse(policy.preference.contains(.neutral))
        }
    }
}
