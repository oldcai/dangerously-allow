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
    /// Gate dialogs on recognised wording — see `DesktopOptions`. Off by
    /// default; `--require-trigger` puts it back.
    var requireTrigger = false
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

        AXTree.capMessagingTimeout()
        if !AXIsProcessTrusted() {
            Log.warn("AXIsProcessTrusted() = false — re-run with sudo, or grant Accessibility")
        }

        let scanner = Scan(options: options)
        while true {
            let pressed = scanner.pass()
            if pressed, options.stopAfterFirst { return }
            if options.dump { return }
            // Dialogs queue: dismissing one uncovers the next, and an app that
            // wants three permissions asks three times. Sleeping the poll
            // interval between them is the whole of the wait, so a pass that
            // pressed something goes straight back round instead.
            if pressed { continue }
            Thread.sleep(forTimeInterval: options.pollInterval)
        }
    }

    /// Back-compat for the bare `dangerously-allow --dry-run` invocation.
    static func run(dryRun: Bool, pollInterval: TimeInterval) {
        run(options: GuiWatchOptions(dryRun: dryRun, pollInterval: pollInterval))
    }

    private final class Scan {
        /// A dialog is frontmost, and its app is normally the active one, so
        /// the sweep starts there and presses as it goes — the alternative is
        /// answering it only after 128 other apps have been asked about their
        /// windows, which measured at two to five seconds.
        private static func rank(_ app: NSRunningApplication, lastAnswered: pid_t) -> Int {
            if app.processIdentifier == lastAnswered { return 0 }
            if app.isActive { return 1 }
            switch app.activationPolicy {
            case .regular: return 2
            case .accessory: return 3
            default: return 4
            }
        }

        /// Ceiling on one app's whole window list. Finder alone spent over two
        /// seconds of a sweep on windows that were never going to be dialogs,
        /// and a dialog is at the front of the list anyway.
        private static let perAppWalk: TimeInterval = 0.6

        private let opts: GuiWatchOptions
        /// The app the last dialog was answered in, swept first next time:
        /// prompts queue, and the next one is nearly always from the same app.
        private var lastAnswered: pid_t = -1
        /// Fingerprints already acted on, pruned each sweep to whatever is
        /// still on screen — a dialog lingers for a frame or two after it is
        /// pressed, and re-pressing it would answer the *next* one by accident.
        /// A set rather than one slot: with several dialogs up at once, a
        /// single slot forgets the first as soon as the second is pressed.
        private var handled: Set<String> = []
        /// Windows already reported under --verbose, so a 2 Hz poll does not
        /// reprint the same unrecognised dialog forever.
        private var reported: Set<String> = []
        private let tree = AXTree()

        init(options: GuiWatchOptions) {
            self.opts = options
        }

        /// One sweep of every window of every running app. Presses every
        /// dialog it finds — stopping at the first would make a queue of them
        /// drain one poll interval at a time. Returns true when it pressed
        /// anything.
        func pass() -> Bool {
            var seen: Set<String> = []
            var pressed = false
            let started = Date()
            var scanned = 0
            defer {
                if opts.verbose {
                    Log.info("swept \(scanned) apps in "
                        + String(format: "%.1f", Date().timeIntervalSince(started)) + "s")
                }
            }
            let order = NSWorkspace.shared.runningApplications.sorted {
                Self.rank($0, lastAnswered: lastAnswered) < Self.rank($1, lastAnswered: lastAnswered)
            }
            for app in order {
                scanned += 1
                let name = app.localizedName ?? "pid:\(app.processIdentifier)"
                let appStarted = Date()
                let appDeadline = Date(timeIntervalSinceNow: Self.perAppWalk)
                defer {
                    let cost = Date().timeIntervalSince(appStarted)
                    if opts.verbose, cost > 0.2 {
                        Log.info("  slow: \(name) took " + String(format: "%.1f", cost) + "s")
                    }
                }
                for window in tree.windows(ofPID: app.processIdentifier) {
                    // Windows come front-to-back, so a dialog is at the top of
                    // the list; the tail is what runs the clock down.
                    if Date() >= appDeadline, !opts.dump { break }
                    // A permission dialog is a handful of nodes; walking a
                    // whole Electron window to discover it is not one costs a
                    // synchronous round trip per node, and used to stall the
                    // sweep long enough to miss the dialog entirely.
                    guard let root = tree.build(window, budget: AXTree.dialogNodes, within: 0.3),
                          !tree.truncated || opts.dump else { continue }

                    switch SystemDialogDetector.detect(
                        root: root, policy: opts.policy, requireTrigger: opts.requireTrigger
                    ) {
                    case let .dialog(dialog):
                        if opts.dump {
                            report(root, appName: name, note: "dialog", force: true)
                            continue
                        }
                        seen.insert(dialog.fingerprint)
                        guard handled.insert(dialog.fingerprint).inserted else { continue }
                        if handle(dialog, appName: name) {
                            pressed = true
                            lastAnswered = app.processIdentifier
                            if opts.stopAfterFirst { return true }
                        }
                    case let .skipped(reason):
                        if opts.dump {
                            report(root, appName: name, note: describe(reason), force: true)
                        } else if opts.verbose, !isNoise(reason) {
                            report(root, appName: name, note: describe(reason), force: false)
                        }
                    }
                }
            }
            handled.formIntersection(seen)
            return pressed
        }

        /// Returns true when the dialog was confirmed.
        private func handle(_ dialog: DetectedSystemDialog, appName: String) -> Bool {
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
            guard let err = tree.press(target.id) else {
                Log.error("  lost the button between scan and press — leaving it")
                return false
            }
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

    }
}
