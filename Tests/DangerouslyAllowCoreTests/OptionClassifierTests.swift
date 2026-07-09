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
