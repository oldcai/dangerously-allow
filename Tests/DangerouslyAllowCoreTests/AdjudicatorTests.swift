import Foundation
import XCTest
@testable import DangerouslyAllowCore

/// A canned adjudicator, so the whole fallback path — scan, judge, validate,
/// merge, policy pick — is exercised without a network call.
struct StubAdjudicator: LLMAdjudicator {
    var judgment: PromptJudgment?
    var error: AdjudicatorError?
    func judge(context _: [String], options: [MenuRow]) throws -> PromptJudgment {
        if let error { throw error }
        // Default: echo the rows back labelled by the rule classifier, so a test
        // that only cares about one row can override just that.
        return judgment ?? PromptJudgment(
            isPermissionPrompt: true,
            options: options.map { OptionJudgment(number: $0.number, kind: OptionClassifier.classify($0.label)) },
            reason: "stub"
        )
    }
}

final class AdjudicatorTests: XCTestCase {
    // MARK: - reconcile: most-reluctant wins

    func testReconcileTakesTheMoreReluctantKind() {
        XCTAssertEqual(Adjudication.reconcile(rule: .allowOnce, model: .allowAlways), .allowAlways)
        XCTAssertEqual(Adjudication.reconcile(rule: .allowAlways, model: .allowOnce), .allowAlways)
        XCTAssertEqual(Adjudication.reconcile(rule: .allowOnce, model: .deny), .deny)
        XCTAssertEqual(Adjudication.reconcile(rule: .deny, model: .allowSession), .deny)
        XCTAssertEqual(Adjudication.reconcile(rule: .allowSession, model: .allowSession), .allowSession)
    }

    // MARK: - validate: the model must answer about the rows we asked about

    func testValidateRejectsAMismatchedOptionSet() {
        let rows = [MenuRow(number: 1, label: "a"), MenuRow(number: 2, label: "b")]
        let good = PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 2, kind: .deny), OptionJudgment(number: 1, kind: .allowOnce),
        ], reason: "")
        XCTAssertNoThrow(try Adjudication.validate(good, against: rows))

        let dropped = PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 1, kind: .allowOnce),
        ], reason: "")
        XCTAssertThrowsError(try Adjudication.validate(dropped, against: rows))

        let invented = PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 1, kind: .allowOnce), OptionJudgment(number: 2, kind: .deny),
            OptionJudgment(number: 3, kind: .allowAlways),
        ], reason: "")
        XCTAssertThrowsError(try Adjudication.validate(invented, against: rows))
    }

    // MARK: - merge

    func testMergeIsRowWiseMostReluctant() {
        let rules = [
            PromptOption(number: 1, label: "Yes, I trust this folder", kind: .allowOnce, isCursor: true, line: 0),
            PromptOption(number: 2, label: "No", kind: .deny, isCursor: false, line: 1),
        ]
        // Model correctly sees the trust row as a permanent grant.
        let judgment = PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 1, kind: .allowAlways),
            OptionJudgment(number: 2, kind: .deny),
        ], reason: "")
        XCTAssertEqual(Adjudication.merge(rules: rules, judgment: judgment), [.allowAlways, .deny])
    }

    func testMergeKeepsRuleKindForARowTheModelDidNotLabel() {
        let rules = [
            PromptOption(number: 1, label: "Allow once", kind: .allowOnce, isCursor: true, line: 0),
            PromptOption(number: 2, label: "No", kind: .deny, isCursor: false, line: 1),
        ]
        let judgment = PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 2, kind: .deny),
        ], reason: "")
        XCTAssertEqual(Adjudication.merge(rules: rules, judgment: judgment), [.allowOnce, .deny])
    }

    // MARK: - Wire format

    func testRequestForcesTheToolAndListsEveryRow() throws {
        let rows = [MenuRow(number: 1, label: "Allow once"), MenuRow(number: 2, label: "Nope")]
        let data = try AdjudicatorAPI.encodedRequest(context: ["rm -rf ./build"], options: rows, model: "claude-haiku-4-5")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual((obj["tool_choice"] as? [String: Any])?["name"] as? String, AdjudicatorAPI.toolName)
        let content = try XCTUnwrap(((obj["messages"] as? [[String: Any]])?.first)?["content"] as? String)
        XCTAssertTrue(content.contains("1. Allow once"))
        XCTAssertTrue(content.contains("2. Nope"))
        XCTAssertTrue(content.contains("rm -rf ./build"))
    }

    func testParsesLabelledResponse() throws {
        let data = """
        {"content":[{"type":"text","text":"ok"},
         {"type":"tool_use","id":"t","name":"judge_prompt",
          "input":{"is_permission_prompt":true,
                   "options":[{"number":1,"kind":"allowAlways"},{"number":2,"kind":"deny"}],
                   "reason":"trust folder"}}],"stop_reason":"tool_use"}
        """.data(using: .utf8)!
        let j = try XCTUnwrap(AdjudicatorAPI.parse(responseData: data))
        XCTAssertTrue(j.isPermissionPrompt)
        XCTAssertEqual(j.options, [
            OptionJudgment(number: 1, kind: .allowAlways),
            OptionJudgment(number: 2, kind: .deny),
        ])
    }

    func testParseMapsAnUnknownKindToDeny() throws {
        let data = """
        {"content":[{"type":"tool_use","id":"t","name":"judge_prompt",
         "input":{"is_permission_prompt":true,"options":[{"number":1,"kind":"banana"}],"reason":""}}]}
        """.data(using: .utf8)!
        let j = try XCTUnwrap(AdjudicatorAPI.parse(responseData: data))
        XCTAssertEqual(j.options.first?.kind, .deny, "a garbled label can only withhold a grant")
    }

    func testParseReturnsNilWithoutAToolCall() {
        let refusal = """
        {"content":[{"type":"text","text":"no"}],"stop_reason":"end_turn"}
        """.data(using: .utf8)!
        XCTAssertNil(AdjudicatorAPI.parse(responseData: refusal))
    }

    // MARK: - End to end, no network

    /// Reached through the adjudicated path, folder trust defers under the
    /// default policy: the classifier now labels "Yes, I trust this folder"
    /// permanent, the model agrees, merge keeps `allowAlways`, and session/once
    /// policies leave it for a human. (In the real flow the rule path handles a
    /// trigger-bearing screen like this directly — post-fix, it defers there too;
    /// the adjudicated path is the safety net for screens the rules reject.)
    func testFolderTrustIsDeferredUnderSessionPolicy() {
        let screen = """
        Quick safety check: is this a project you trust?
        ❯ 1. Yes, I trust this folder
          2. No, exit
        """
        XCTAssertEqual(OptionClassifier.classify("Yes, I trust this folder"), .allowAlways)
        let stub = StubAdjudicator(judgment: PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 1, kind: .allowAlways),
            OptionJudgment(number: 2, kind: .deny),
        ], reason: "trusting a folder runs its config in every session"))

        assertDefers(.detect(screen: screen, policy: .session, adjudicator: stub))
        assertDefers(.detect(screen: screen, policy: .once, adjudicator: stub))
        // Only an explicit `always` opts into it.
        XCTAssertEqual(
            AdjudicatedDetector.detect(screen: screen, policy: .always, adjudicator: stub),
            .act(number: 1, label: "Yes, I trust this folder", kind: .allowAlways)
        )
    }

    /// The fallback's sweet spot: standard-worded rows the rule path rejects only
    /// because there is no question line above. The classifier already reads the
    /// rows correctly, the model agrees, and the policy picks the session grant.
    func testActsOnAGrantTheRulesRejectedForLackOfATriggerLine() {
        let screen = """
        ● 1. Allow once
          2. Allow for this session
          3. No, cancel
        """
        XCTAssertNil(
            PromptDetector.detect(screen: screen, policy: .session),
            "no question line above → rules reject it"
        )
        let stub = StubAdjudicator() // echoes the rule classifier's labels
        XCTAssertEqual(
            AdjudicatedDetector.detect(screen: screen, policy: .session, adjudicator: stub),
            .act(number: 2, label: "Allow for this session", kind: .allowSession)
        )
    }

    /// A grant the rule classifier neutralises by its wording is vetoed by the
    /// merge even when the model calls it a session grant — the safe direction.
    func testRuleNeutralVetoesTheModelsGrant() {
        let screen = """
        ● 1. Keep it enabled for this session
          2. No, cancel
        """
        XCTAssertEqual(OptionClassifier.classify("Keep it enabled for this session"), .neutral)
        let stub = StubAdjudicator(judgment: PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 1, kind: .allowSession),
            OptionJudgment(number: 2, kind: .deny),
        ], reason: ""))
        assertDefers(.detect(screen: screen, policy: .session, adjudicator: stub))
    }

    func testDefersWhenModelSaysNotAPermissionPrompt() {
        let screen = """
        ● 1. Default Dark
          2. Default Light
          3. GitHub
        """
        let stub = StubAdjudicator(judgment: PromptJudgment(
            isPermissionPrompt: false, options: [], reason: "theme picker"
        ))
        assertDefers(.detect(screen: screen, policy: .always, adjudicator: stub))
    }

    func testDefersWhenThereIsNoRefusalRow() {
        // Two grants, no way out — not a real permission prompt.
        let screen = """
        ● 1. Allow once
          2. Allow for this session
        """
        let stub = StubAdjudicator(judgment: PromptJudgment(isPermissionPrompt: true, options: [
            OptionJudgment(number: 1, kind: .allowOnce),
            OptionJudgment(number: 2, kind: .allowSession),
        ], reason: ""))
        assertDefers(.detect(screen: screen, policy: .session, adjudicator: stub))
    }

    func testDefersWhenTheAdjudicatorErrors() {
        let screen = """
        Proceed?
        ● 1. Yes
          2. No
        """
        let stub = StubAdjudicator(error: .transport("network down"))
        assertDefers(.detect(screen: screen, policy: .session, adjudicator: stub))
    }

    func testNotAMenuWhenNothingParses() {
        let stub = StubAdjudicator()
        XCTAssertEqual(
            AdjudicatedDetector.detect(screen: "just some prose, no menu here", policy: .session, adjudicator: stub),
            .notAMenu
        )
    }

    // MARK: -

    private func assertDefers(
        _ outcome: AdjudicatedOutcome, file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .deferToHuman = outcome { return }
        XCTFail("expected defer, got \(outcome)", file: file, line: line)
    }
}

private extension AdjudicatedOutcome {
    static func detect(screen: String, policy: AllowPolicy, adjudicator: LLMAdjudicator) -> AdjudicatedOutcome {
        AdjudicatedDetector.detect(screen: screen, policy: policy, adjudicator: adjudicator)
    }
}
