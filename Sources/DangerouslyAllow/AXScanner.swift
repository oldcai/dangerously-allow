import AppKit
import ApplicationServices
import DangerouslyAllowCore

struct GuiWatchOptions {
    /// `always` by default, unlike the other paths. A TCC dialog almost never
    /// offers a session- or once-scoped button, so a `session` default would
    /// make `gui` a no-op on the common dialogs. Neutral and deny stay
    /// unpressable regardless of policy, so this presses grants only.
    var policy: AllowPolicy = .always
    var dryRun = false
    var stopAfterFirst = false
    var pollInterval: TimeInterval = 0.5
    var neverApprove: [String] = []
    var requireTrigger = true
    /// Log every dialog-shaped window and why it was passed over — for
    /// diagnosing wording the keyword list does not know yet.
    var verbose = false
    /// Print every window carrying any text once, then exit.
    var dump = false
    var notify = false
}

/// Auto-clicks native macOS TCC dialogs (Microphone, Screen Recording,
/// Accessibility, …). These are real AppKit windows, so they are reachable
/// through the Accessibility API — unlike a permission menu drawn *inside* a
/// terminal, which is just text and needs `Watcher`.
///
/// Unlike the other two channels this one has no app to name: a TCC dialog is
/// presented by whichever process the system chose, so every running app is
/// scanned. `SystemDialogDetector` decides what is a dialog, and — because a
/// grant here is written to the TCC database and outlives the process — the
/// default `session` policy declines a plain "Allow" and leaves it to a human.
enum AXScanner {
    static func run(options: GuiWatchOptions) {
        Log.info("scanning for macOS permission dialogs\(options.dryRun ? "  (DRY RUN — nothing pressed)" : "")")
        Log.info("policy: \(options.policy.rawValue)  poll: \(options.pollInterval)s — Ctrl+C to stop")
        if options.policy == .always {
            Log.info("a TCC grant is permanent — this presses \"Allow\"; refusals and")
            Log.info("  \"Open System Settings\" are never pressed. --policy session to be cautious")
        } else {
            Log.info("a TCC grant is permanent, so --policy \(options.policy.rawValue) presses only")
            Log.info("  explicitly one-shot buttons (\"Allow Once\"); use --policy always for \"Allow\"")
        }
        if !options.neverApprove.isEmpty {
            Log.info("never-approve: \(options.neverApprove.joined(separator: ", "))")
        }

        if !AXIsProcessTrusted() {
            Log.warn("AXIsProcessTrusted() = false — re-run with sudo, or grant Accessibility")
        }

        let scanner = Scan(options: options)
        while true {
            if scanner.pass(), options.stopAfterFirst { return }
            if options.dump { return }
            Thread.sleep(forTimeInterval: options.pollInterval)
        }
    }

    /// Back-compat for the bare `dangerously-allow --dry-run` invocation.
    static func run(dryRun: Bool, pollInterval: TimeInterval) {
        run(options: GuiWatchOptions(dryRun: dryRun, pollInterval: pollInterval))
    }

    private final class Scan {
        private let opts: GuiWatchOptions
        /// Fingerprint of the dialog already acted on, cleared once it leaves
        /// the screen — the lingering-frame guard `AppWatcher` uses too.
        private var handled: String?
        /// Windows already reported under --verbose, so a 2 Hz poll does not
        /// reprint the same unrecognised dialog forever.
        private var reported: Set<String> = []
        private var buttons: [Int: AXUIElement] = [:]
        private var nextID = 0
        private var nodeBudget = 0

        private static let maxDepth = 40
        private static let maxNodes = 20_000

        init(options: GuiWatchOptions) {
            self.opts = options
        }

        /// One sweep of every window of every running app. Returns true when a
        /// dialog was confirmed.
        func pass() -> Bool {
            var sawHandled = false
            for app in NSWorkspace.shared.runningApplications {
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                guard let windows = axAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                let name = app.localizedName ?? "pid:\(app.processIdentifier)"
                for window in windows {
                    buttons.removeAll()
                    nextID = 0
                    nodeBudget = Self.maxNodes
                    guard let tree = buildNode(window, depth: 0) else { continue }

                    switch SystemDialogDetector.detect(
                        root: tree, policy: opts.policy, requireTrigger: opts.requireTrigger
                    ) {
                    case let .dialog(dialog):
                        if opts.dump {
                            report(tree, appName: name, note: "dialog", force: true)
                            continue
                        }
                        if dialog.fingerprint == handled {
                            sawHandled = true
                            continue
                        }
                        let confirmed = handle(dialog, appName: name)
                        sawHandled = true
                        if confirmed { return true }
                    case let .skipped(reason):
                        if opts.dump {
                            report(tree, appName: name, note: describe(reason), force: true)
                        } else if opts.verbose, !isNoise(reason) {
                            report(tree, appName: name, note: describe(reason), force: false)
                        }
                    }
                }
            }
            if !sawHandled { handled = nil }
            return false
        }

        /// Returns true when the dialog was confirmed.
        private func handle(_ dialog: DetectedSystemDialog, appName: String) -> Bool {
            handled = dialog.fingerprint

            if let blocked = PromptDetector.blockingPattern(
                screen: dialog.fullText, neverApprove: opts.neverApprove
            ) {
                Log.warn("REFUSING — dialog matches --never-approve /\(blocked)/")
                Log.warn("  leaving for a human: \(dialog.dialogText.prefix(140))")
                if opts.notify { Notify.post("Vetoed a permission dialog in \(appName)") }
                return false
            }

            Log.info("dialog in \(appName): \(dialog.dialogText.prefix(140))")
            if opts.verbose {
                for o in dialog.options {
                    let mark = o == dialog.target ? "\u{25cf}" : " "
                    Log.info("  \(mark) \(o.label)  [\(o.kind.rawValue)]")
                }
            }

            guard let target = dialog.target else {
                Log.warn("  nothing on it is acceptable under --policy \(opts.policy.rawValue) — leaving for a human")
                if opts.notify { Notify.post("Permission dialog in \(appName) needs a human") }
                return false
            }

            Log.info("  -> pressing \"\(target.label)\" [\(target.kind.rawValue)]")
            if opts.dryRun {
                Log.info("  [dry-run] pressed nothing")
                return false
            }
            guard let element = buttons[target.id] else {
                Log.error("  lost the button between scan and press — leaving it")
                return false
            }
            let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if err == .success {
                Log.info("  pressed \"\(target.label)\"")
                return true
            }
            Log.error("  press failed (AXError \(err.rawValue))")
            return false
        }

        // MARK: - diagnostics

        /// A window with nothing to press, or a whole app's worth of buttons,
        /// says nothing about wording — under --verbose it would drown out the
        /// dialogs that are actually worth looking at. Only --dump prints it.
        private func isNoise(_ reason: SystemDialogSkip) -> Bool {
            if case .notADialog = reason { return true }
            return false
        }

        private func describe(_ reason: SystemDialogSkip) -> String {
            switch reason {
            case let .notADialog(count): return "not a dialog (\(count) buttons)"
            case .noPermissionWording: return "no permission wording — add it to permissionKeywords?"
            case .noGrant: return "no button grants anything"
            }
        }

        /// Print what a window actually looks like through AX, so an
        /// unrecognised dialog can be pasted into an issue verbatim.
        private func report(_ tree: UINode, appName: String, note: String, force: Bool) {
            var texts: [String] = []
            var labels: [String] = []
            walk(tree, texts: &texts, labels: &labels)
            guard force || !texts.isEmpty || !labels.isEmpty else { return }

            let key = appName + "\u{a7}" + labels.joined(separator: "|") + "\u{a7}" + texts.joined(separator: " ")
            if !force, !reported.insert(key).inserted { return }

            Log.info("window of \(appName) — \(note)")
            for t in texts { Log.plain("    text: \(t.prefix(160))") }
            for l in labels {
                Log.plain("    button: \"\(l)\"  [\(SystemDialogDetector.classify(l).rawValue)]")
            }
        }

        private func walk(_ node: UINode, texts: inout [String], labels: inout [String]) {
            if node.role == "AXButton" {
                if !node.label.isEmpty { labels.append(node.label) }
                return
            }
            if !node.label.isEmpty { texts.append(node.label) }
            if !node.text.isEmpty { texts.append(node.text) }
            for child in node.children { walk(child, texts: &texts, labels: &labels) }
        }

        // MARK: - AX tree -> UINode

        /// A trimmed version of `AppWatcher`'s builder: a system dialog carries
        /// no notification-style custom actions, so buttons are all that can be
        /// pressed here.
        private func buildNode(_ el: AXUIElement, depth: Int) -> UINode? {
            guard depth < Self.maxDepth, nodeBudget > 0 else { return nil }
            nodeBudget -= 1
            nextID += 1
            let id = nextID

            let role = axAttr(el, kAXRoleAttribute) as? String ?? ""
            let title = axAttr(el, kAXTitleAttribute) as? String ?? ""
            let desc = axAttr(el, kAXDescriptionAttribute) as? String ?? ""
            let label = title.isEmpty ? desc : title
            let text = axAttr(el, kAXValueAttribute) as? String ?? ""

            if role == (kAXButtonRole as String) {
                buttons[id] = el
                return UINode(id: id, role: role, label: label, text: text)
            }

            var children: [UINode] = []
            if let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
                for kid in kids {
                    if let node = buildNode(kid, depth: depth + 1) { children.append(node) }
                }
            }
            return UINode(id: id, role: role, label: label, text: text, children: children)
        }

        private func axAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
            var val: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success ? val : nil
        }
    }
}
