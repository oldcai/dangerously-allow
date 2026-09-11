import AppKit
import ApplicationServices
import DangerouslyAllowCore

struct DesktopOptions {
    var policies = DesktopPolicies()
    /// Apps whose in-app approval cards are answered. System dialogs are
    /// recognised by wording wherever they appear and ignore this list.
    var apps: [String] = AgentApps.defaults
    var dryRun = false
    var stopAfterFirst = false
    var pollInterval: TimeInterval = 0.5
    var neverApprove: [String] = []
    /// Gate prompts on recognised wording. Off: a wording list only knows
    /// the prompts it has already met, and the ones it has not are walked
    /// past in silence. `--require-trigger` puts it back.
    var requireTrigger = false
    var verbose = false
    var notify = false
}

/// The whole desktop surface in one process: the approval cards the ChatGPT and
/// Claude desktop apps show, the notification banners they post, and the native
/// macOS permission dialogs they trigger on the way to controlling your machine.
///
/// These used to be three commands you had to remember to start — and forgetting
/// one silently meant a prompt sat there waiting for a human. Now a bare
/// `dangerously-allow` runs all of it. `DesktopRouter` decides which detector
/// owns each window; see it for why the order matters.
final class DesktopWatcher {
    private let opts: DesktopOptions
    private let tree = AXTree()
    /// Fingerprints already acted on, pruned each pass to whatever is still on
    /// screen — a card lingers for several frames after it is pressed, and
    /// re-pressing it would answer the *next* prompt by accident.
    private var handled: Set<String> = []

    /// How long one window is worth. An approval card is buried in a renderer
    /// tree thousands of nodes deep, so those apps get room; everywhere else we
    /// are looking for a small native dialog and anything slower than this is
    /// an app that would not answer a press either.
    private static let cardWalk: TimeInterval = 1.5
    private static let dialogWalk: TimeInterval = 0.3
    /// Ceiling on one app's whole window list. Finder alone spent over two
    /// seconds of a sweep on windows that were never going to be prompts, and
    /// a prompt is at the front of the list anyway. Card apps get room: their
    /// card really is buried, and there are only ever a few of them.
    private static let perAppWalk: TimeInterval = 0.6
    private static let perCardAppWalk: TimeInterval = 4

    /// A prompt is frontmost, and its app is normally the active one, so the
    /// sweep starts there and presses as it goes — the alternative is answering
    /// it only after 128 other apps have been asked about their windows, which
    /// measured at two to five seconds.
    private static func rank(_ app: NSRunningApplication, lastAnswered: pid_t) -> Int {
        if app.processIdentifier == lastAnswered { return 0 }
        if app.isActive { return 1 }
        switch app.activationPolicy {
        case .regular: return 2
        case .accessory: return 3
        default: return 4
        }
    }

    /// The app the last prompt was answered in, swept first next time: prompts
    /// queue, and the next one is nearly always from the same app.
    private var lastAnswered: pid_t = -1

    init(options: DesktopOptions) {
        self.opts = options
    }

    /// One decision, whichever channel produced it, so the veto, the logging
    /// and the press have a single code path.
    private struct Answer {
        let channel: String
        let fingerprint: String
        /// The wording only — what `--never-approve` reads, along with labels.
        let text: String
        let fullText: String
        let options: [(label: String, kind: OptionKind)]
        let target: (id: Int, label: String, kind: OptionKind)?
        let policy: AllowPolicy
    }

    func run() {
        AXTree.capMessagingTimeout()
        if !AXIsProcessTrusted() {
            Log.warn("AXIsProcessTrusted() = false — grant this terminal Accessibility in")
            Log.warn("  System Settings → Privacy & Security → Accessibility, then re-run")
        }
        Log.info("watching the desktop\(opts.dryRun ? "  (DRY RUN — nothing pressed)" : "")")
        Log.info("  cards in: \(opts.apps.joined(separator: ", "))")
        Log.info("  policy: cards \(opts.policies.card.rawValue), "
            + "system dialogs \(opts.policies.dialog.rawValue)")
        if opts.policies.dialog == .always {
            Log.info("  a TCC grant is permanent — \"Allow\" is pressed; refusals and")
            Log.info("    \"Open System Settings\" never are. --policy session to be cautious")
        }
        if !opts.neverApprove.isEmpty {
            Log.info("  never-approve: \(opts.neverApprove.joined(separator: ", "))")
        }
        Log.info("Ctrl+C to stop")

        while true {
            let pressed = pass()
            if pressed, opts.stopAfterFirst { return }
            // Prompts queue: dismissing one uncovers the next, and an app that
            // wants three permissions asks three times. Sleeping the poll
            // interval between them is the whole of the wait, so a pass that
            // pressed something goes straight back round instead.
            if pressed { continue }
            Thread.sleep(forTimeInterval: opts.pollInterval)
        }
    }

    // MARK: - one poll

    /// One sweep of every window of every running app. Presses every prompt it
    /// finds — stopping at the first would make a queue of them drain one poll
    /// interval at a time. Returns true when it pressed anything.
    private func pass() -> Bool {
        var seen: Set<String> = []
        var pressed = false
        let started = Date()
        var apps = 0
        var windows = 0
        defer {
            if opts.verbose {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                Log.info("swept \(apps) apps, \(windows) windows in \(elapsed)s")
            }
        }
        let order = NSWorkspace.shared.runningApplications.sorted {
            Self.rank($0, lastAnswered: lastAnswered) < Self.rank($1, lastAnswered: lastAnswered)
        }
        for app in order {
            apps += 1
            let appStarted = Date()
            defer {
                let cost = Date().timeIntervalSince(appStarted)
                if opts.verbose, cost > 0.3 {
                    Log.info("  slow: \(app.localizedName ?? "?") took "
                        + String(format: "%.1f", cost) + "s")
                }
            }
            let cardsAllowed = AgentApps.isWatched(
                name: app.localizedName, bundleID: app.bundleIdentifier, in: opts.apps
            )
            let appDeadline = Date(
                timeIntervalSinceNow: cardsAllowed ? Self.perCardAppWalk : Self.perAppWalk
            )
            for window in tree.windows(ofPID: app.processIdentifier) {
                // Windows come front-to-back, so a prompt is at the top of the
                // list; the tail is what runs the clock down.
                if Date() >= appDeadline { break }
                windows += 1
                // Only the apps we answer cards in are worth walking in full.
                // Everywhere else we are looking for a system dialog, which is
                // tiny — so cap the walk, and treat a window that outgrows the
                // cap as what it is: an ordinary window, not a prompt.
                let budget = cardsAllowed ? AXTree.maxNodes : AXTree.dialogNodes
                guard let root = tree.build(
                    window,
                    budget: budget,
                    within: cardsAllowed ? Self.cardWalk : Self.dialogWalk
                ) else { continue }
                if tree.truncated, !cardsAllowed { continue }
                guard let answer = answer(
                    for: root, cardsAllowed: cardsAllowed
                ) else { continue }

                seen.insert(answer.fingerprint)
                guard handled.insert(answer.fingerprint).inserted else { continue }
                if handle(answer, appName: app.localizedName ?? "?") {
                    pressed = true
                    lastAnswered = app.processIdentifier
                    if opts.stopAfterFirst { return true }
                }
            }
        }
        handled.formIntersection(seen)
        return pressed
    }

    private func answer(for window: UINode, cardsAllowed: Bool) -> Answer? {
        switch DesktopRouter.route(
            window: window,
            cardsAllowed: cardsAllowed,
            policies: opts.policies,
            requireTrigger: opts.requireTrigger
        ) {
        case let .systemDialog(d):
            return Answer(
                channel: "system dialog",
                fingerprint: d.fingerprint,
                text: d.dialogText,
                fullText: d.fullText,
                options: d.options.map { ($0.label, $0.kind) },
                target: d.target.map { ($0.id, $0.label, $0.kind) },
                policy: opts.policies.dialog
            )
        case let .card(c):
            return Answer(
                channel: "card",
                fingerprint: c.fingerprint,
                text: c.cardText,
                fullText: c.fullText,
                options: c.options.map { ($0.label, $0.kind) },
                target: c.target.map { ($0.id, $0.label, $0.kind) },
                policy: opts.policies.card
            )
        case .ignored:
            return nil
        }
    }

    /// Returns true when the prompt was confirmed.
    private func handle(_ answer: Answer, appName: String) -> Bool {
        if let blocked = PromptDetector.blockingPattern(
            screen: answer.fullText, neverApprove: opts.neverApprove
        ) {
            Log.warn("REFUSING — \(answer.channel) matches --never-approve /\(blocked)/")
            Log.warn("  leaving for a human: \(answer.text.prefix(140))")
            if opts.notify { Notify.post("Vetoed a \(answer.channel) in \(appName)") }
            return false
        }

        Log.info("\(answer.channel) in \(appName): \(answer.text.prefix(140))")
        if opts.verbose {
            for option in answer.options {
                let mark = option.label == answer.target?.label ? "\u{25cf}" : " "
                Log.info("  \(mark) \(option.label)  [\(option.kind.rawValue)]")
            }
        }

        guard let target = answer.target else {
            Log.warn("  nothing on it is acceptable under --policy \(answer.policy.rawValue)"
                + " — leaving for a human")
            if opts.notify { Notify.post("A \(answer.channel) in \(appName) needs a human") }
            return false
        }

        Log.info("  -> pressing \"\(target.label)\" [\(target.kind.rawValue)]")
        if opts.dryRun {
            Log.info("  [dry-run] pressed nothing")
            return false
        }
        guard let err = tree.press(target.id) else {
            Log.error("  lost the element between scan and press — leaving it")
            return false
        }
        if err == .success {
            Log.info("  pressed \"\(target.label)\"")
            return true
        }
        Log.error("  press failed (AXError \(err.rawValue))")
        return false
    }
}
