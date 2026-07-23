import XCTest
@testable import DangerouslyAllowCore

/// Native macOS permission dialogs — the `gui` path. Unlike a TUI menu or an
/// in-app approval card, these often offer no refusal button at all: the
/// screen-recording dialog below has "Allow" and "Open System Settings" and
/// nothing else, so the way out is Esc. That rules out
/// `ButtonPromptDetector`'s grant-and-refusal invariant, and the safety has to
/// come from somewhere else: the wording gate, the dialog shape, and above all
/// the fact that pressing Allow here writes the TCC database — a grant that
/// outlives the process, and so is `.allowAlways` however mildly it is worded.
///
/// Dialog text is transcribed from the real thing, not invented.
final class SystemDialogDetectorTests: XCTestCase {
    private var nextID = 0

    private func node(
        _ role: String, label: String = "", text: String = "", _ children: [UINode] = []
    ) -> UINode {
        nextID += 1
        return UINode(id: nextID, role: role, label: label, text: text, children: children)
    }

    private func btn(_ label: String) -> UINode { node("AXButton", label: label) }
    private func txt(_ text: String) -> UINode { node("AXStaticText", text: text) }
    private func win(_ children: [UINode]) -> UINode { node("AXWindow", children) }

    private func detect(
        _ root: UINode, policy: AllowPolicy = .session, requireTrigger: Bool = true
    ) -> DetectedSystemDialog? {
        guard case let .dialog(d) = SystemDialogDetector.detect(
            root: root, policy: policy, requireTrigger: requireTrigger
        ) else { return nil }
        return d
    }

    private func skip(
        _ root: UINode, policy: AllowPolicy = .session, requireTrigger: Bool = true
    ) -> SystemDialogSkip? {
        guard case let .skipped(s) = SystemDialogDetector.detect(
            root: root, policy: policy, requireTrigger: requireTrigger
        ) else { return nil }
        return s
    }

    /// macOS 15 (Sequoia), ScreenCaptureKit. Note the wording: it says neither
    /// "would like to access" nor "Screen Recording", which is exactly why the
    /// old keyword list walked past it.
    private func screenRecordingDialog() -> UINode {
        win([
            txt("\u{201C}VoiceHUD\u{201D} is requesting to bypass the system private window "
                + "picker and directly access your screen and audio."),
            txt("This will allow VoiceHUD to record your screen and system audio, including "
                + "personal or sensitive information that may be visible or audible."),
            btn("Allow"),
            btn("Open System Settings"),
        ])
    }

    // MARK: - the dialog that started this

    func testRecognisesTheScreenRecordingDialog() {
        let d = detect(screenRecordingDialog())
        XCTAssertNotNil(d, "macOS 15's screen-capture wording must be recognised")
        XCTAssertEqual(d?.options.map(\.label), ["Allow", "Open System Settings"])
    }

    /// The point of B: a TCC grant is permanent, so the default policy leaves
    /// it alone even though the button just says "Allow".
    func testPlainAllowIsPermanentAndSessionPolicyDeclines() {
        let d = detect(screenRecordingDialog())
        XCTAssertEqual(d?.options.first?.kind, .allowAlways)
        XCTAssertNil(d?.target, "--policy session must not grant screen recording forever")
    }

    func testAlwaysPolicyPressesAllow() {
        let d = detect(screenRecordingDialog(), policy: .always)
        XCTAssertEqual(d?.target?.label, "Allow")
    }

    /// The bug in the old AXScanner: "Open System Settings" sat in `allowTitles`
    /// beside "Allow" and "OK", so a dialog that listed it first got it pressed.
    func testOpenSystemSettingsIsNeverPressed() {
        XCTAssertEqual(SystemDialogDetector.classify("Open System Settings"), .neutral)

        let settingsFirst = win([
            txt("\u{201C}VoiceHUD\u{201D} is requesting to bypass the system private window picker."),
            btn("Open System Settings"),
            btn("Allow"),
        ])
        for policy in AllowPolicy.allCases {
            let target = detect(settingsFirst, policy: policy)?.target
            XCTAssertNotEqual(target?.label, "Open System Settings", "policy \(policy.rawValue)")
        }
        XCTAssertEqual(detect(settingsFirst, policy: .always)?.target?.label, "Allow")
    }

    // MARK: - classification

    func testEveryUnqualifiedGrantIsPermanent() {
        // A TCC answer is written to the database — "OK" here is not a one-off.
        for label in ["Allow", "OK", "Continue To Allow", "Always Allow"] {
            XCTAssertEqual(SystemDialogDetector.classify(label), .allowAlways, label)
        }
    }

    func testExplicitlyOneShotGrantsKeepTheirTier() {
        // Location Services really does mean once.
        XCTAssertEqual(SystemDialogDetector.classify("Allow Once"), .allowOnce)
        XCTAssertEqual(SystemDialogDetector.classify("Allow This Time"), .allowOnce)
    }

    /// "While Using the App" reads like a bounded grant and is not one: it is a
    /// permanent TCC entry with a usage condition, and survives a relaunch.
    func testWhileUsingTheAppIsPermanent() {
        XCTAssertEqual(SystemDialogDetector.classify("Allow While Using App"), .allowAlways)
    }

    func testRefusalsAndNeutralsAreUnchanged() {
        XCTAssertEqual(SystemDialogDetector.classify("Don\u{2019}t Allow"), .deny)
        XCTAssertEqual(SystemDialogDetector.classify("Cancel"), .deny)
        XCTAssertEqual(SystemDialogDetector.classify("Learn More\u{2026}"), .neutral)
    }

    func testSessionPolicyPressesAnExplicitAllowOnce() {
        let location = win([
            txt("\u{201C}Maps\u{201D} would like to use your current location."),
            btn("Allow Once"),
            btn("Allow While Using App"),
            btn("Don\u{2019}t Allow"),
        ])
        XCTAssertEqual(detect(location)?.target?.label, "Allow Once")
        // ... and never escalates to the permanent one when it is absent.
        let noOnce = win([
            txt("\u{201C}Maps\u{201D} would like to use your current location."),
            btn("Allow While Using App"),
            btn("Don\u{2019}t Allow"),
        ])
        XCTAssertNil(detect(noOnce)?.target)
        XCTAssertEqual(detect(noOnce, policy: .always)?.target?.label, "Allow While Using App")
    }

    // MARK: - not firing on the wrong thing

    func testOrdinaryWindowWithManyButtonsIsNotADialog() {
        var kids: [UINode] = [txt("Full Disk Access")]
        kids += (1...9).map { btn("Button \($0)") }
        kids.append(btn("OK"))
        XCTAssertEqual(skip(win(kids)), .notADialog(buttons: 10))
    }

    func testWindowWithoutPermissionWordingIsSkipped() {
        let save = win([txt("Do you want to save the changes?"), btn("OK"), btn("Cancel")])
        XCTAssertEqual(skip(save), .noPermissionWording)
        // --no-require-trigger relaxes the wording gate, not the grant one.
        XCTAssertNotNil(detect(save, requireTrigger: false))
    }

    func testDialogWithNothingToGrantIsSkipped() {
        let dead = win([
            txt("\u{201C}VoiceHUD\u{201D} is requesting to bypass the system private window picker."),
            btn("Open System Settings"),
            btn("Cancel"),
        ])
        XCTAssertEqual(skip(dead), .noGrant)
    }

    func testWindowWithNoButtonsIsSkipped() {
        XCTAssertEqual(skip(win([txt("would like to access the Microphone")])), .notADialog(buttons: 0))
    }

    // MARK: - text and fingerprint

    func testDialogTextExcludesButtonLabelsAndFullTextIncludesThem() {
        let d = detect(screenRecordingDialog())
        XCTAssertFalse(d!.dialogText.contains("Open System Settings"))
        XCTAssertTrue(d!.dialogText.contains("private window picker"))
        // --never-approve vetoes on fullText, so the buttons must be in it.
        XCTAssertTrue(d!.fullText.contains("Open System Settings"))
    }

    func testFingerprintIsStableAcrossRescansAndIgnoresIDs() {
        let first = detect(screenRecordingDialog())!.fingerprint
        let second = detect(screenRecordingDialog())!.fingerprint // fresh ids
        XCTAssertEqual(first, second)

        let other = detect(win([
            txt("\u{201C}Terminal\u{201D} would like to access the Microphone."),
            btn("Allow"), btn("Don\u{2019}t Allow"),
        ]))!.fingerprint
        XCTAssertNotEqual(first, other)
    }
}
