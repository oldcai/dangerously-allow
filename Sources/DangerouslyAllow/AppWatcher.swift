import AppKit
import ApplicationServices
import DangerouslyAllowCore

struct AppWatchOptions {
    /// App to watch: a localized name ("ChatGPT") or bundle id
    /// ("com.openai.codex", "com.apple.notificationcenterui").
    var appName: String
    var policy: AllowPolicy = .session
    var dryRun = false
    var stopAfterFirst = false
    var pollInterval: TimeInterval = 0.5
    var neverApprove: [String] = []
    var requireTrigger = true
    var verbose = false
    var notify = false
    /// Print each window's pruned AX tree once and exit — for capturing the
    /// labels of a card the classifier does not know yet.
    var dump = false
}

/// Polls an app's Accessibility tree, and when an approval card appears —
/// ChatGPT's "Allow once / Always allow / Deny", a notification banner with an
/// Allow action — presses the option the policy allows.
///
/// This is the third channel, next to `Watcher` (TUI menus through tmux) and
/// `AXScanner` (TCC dialogs): a native card inside an app window is neither a
/// terminal drawing nor a system dialog, but it is reachable through AX.
/// Notification banners are a twist: Notification Center exposes a banner's
/// buttons as AX *actions on the banner element*, not as child buttons, so the
/// tree builder surfaces each non-standard action as a synthetic pressable.
final class AppWatcher {
    private let opts: AppWatchOptions
    /// Fingerprint of the card we already acted on, cleared once it leaves the
    /// screen — the same lingering-frame guard `Watcher` uses.
    private var handled: String?

    private let tree = AXTree()

    init(options: AppWatchOptions) {
        self.opts = options
    }

    func run() {
        if !AXIsProcessTrusted() {
            Log.warn("AXIsProcessTrusted() = false — grant this terminal Accessibility in")
            Log.warn("  System Settings → Privacy & Security → Accessibility")
        }
        Log.info("watching app '\(opts.appName)' for approval cards")
        Log.info("policy: \(opts.policy.rawValue)\(opts.dryRun ? "  (DRY RUN — nothing pressed)" : "")")
        if !opts.neverApprove.isEmpty {
            Log.info("never-approve: \(opts.neverApprove.joined(separator: ", "))")
        }

        var warnedNotRunning = false
        while true {
            let apps = matchingApps()
            if apps.isEmpty {
                if !warnedNotRunning {
                    Log.warn("no running app matches '\(opts.appName)' — waiting for it")
                    warnedNotRunning = true
                }
            } else {
                warnedNotRunning = false
                if scan(apps), opts.stopAfterFirst { return }
            }
            if opts.dump { return }
            Thread.sleep(forTimeInterval: opts.pollInterval)
        }
    }

    // MARK: - one poll

    /// Returns true when a card was confirmed this pass.
    private func scan(_ apps: [NSRunningApplication]) -> Bool {
        var sawHandled = false
        for app in apps {
            for window in tree.windows(ofPID: app.processIdentifier) {
                guard let root = tree.build(window, within: 1.5) else { continue }
                if opts.dump {
                    Log.info("window of \(app.localizedName ?? "?"):")
                    dump(root, indent: 1)
                    continue
                }
                guard let prompt = ButtonPromptDetector.detect(
                    root: root, policy: opts.policy, requireTrigger: opts.requireTrigger
                ) else { continue }
                if prompt.fingerprint == handled {
                    sawHandled = true
                    continue
                }
                let confirmed = handle(prompt, appName: app.localizedName ?? opts.appName)
                sawHandled = true
                if confirmed { return true }
            }
        }
        if !sawHandled { handled = nil }
        return false
    }

    /// Returns true when the card was confirmed.
    private func handle(_ prompt: DetectedButtonPrompt, appName: String) -> Bool {
        handled = prompt.fingerprint

        if let blocked = PromptDetector.blockingPattern(
            screen: prompt.fullText, neverApprove: opts.neverApprove
        ) {
            Log.warn("REFUSING — card matches --never-approve /\(blocked)/")
            Log.warn("  leaving for a human: \(prompt.cardText.prefix(140))")
            if opts.notify { Notify.post("Vetoed a card in \(appName)") }
            return false
        }

        if opts.verbose {
            for o in prompt.options {
                let mark = o == prompt.target ? "●" : " "
                Log.info("  \(mark) \(o.label)  [\(o.kind.rawValue)]")
            }
        }

        Log.info("card in \(appName): \(prompt.cardText.prefix(140))")
        guard let target = prompt.target else {
            Log.warn("  nothing on it is acceptable under --policy \(opts.policy.rawValue) — leaving for a human")
            if opts.notify { Notify.post("Card in \(appName) needs a human") }
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

    private func matchingApps() -> [NSRunningApplication] {
        let needle = opts.appName.lowercased()
        let all = NSWorkspace.shared.runningApplications
        let exact = all.filter {
            $0.localizedName?.lowercased() == needle || $0.bundleIdentifier?.lowercased() == needle
        }
        if !exact.isEmpty { return exact }
        return all.filter {
            ($0.localizedName?.lowercased().contains(needle) ?? false)
                || ($0.bundleIdentifier?.lowercased().contains(needle) ?? false)
        }
    }

    // MARK: - --dump

    private func dump(_ node: UINode, indent: Int) {
        let hasWords = !node.label.isEmpty || !node.text.isEmpty
        let pressable = tree.isPressable(node.id)
        if hasWords || pressable {
            var line = String(repeating: "  ", count: indent) + node.role
            if !node.label.isEmpty { line += " \"\(node.label.prefix(80))\"" }
            if !node.text.isEmpty { line += " text=\"\(node.text.prefix(80))\"" }
            if pressable {
                line += "  [\(OptionClassifier.classify(node.label).rawValue)]"
            }
            Log.plain(line)
        }
        for child in node.children { dump(child, indent: indent + 1) }
    }
}
