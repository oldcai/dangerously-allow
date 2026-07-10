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

    /// How to press each node id handed to the detector. Rebuilt every scan.
    private enum Pressable {
        case button(AXUIElement)
        case action(AXUIElement, name: String)
    }
    private var pressables: [Int: Pressable] = [:]
    private var nextID = 0
    private var nodeBudget = 0

    /// Standard AX actions every element carries (AXPress, AXShowMenu,
    /// AXScrollToVisible…). Only *custom* actions — notification buttons,
    /// named like "Name:Close\nTarget:…" with the label in the description —
    /// become pressables.
    private static let standardActionPrefix = "AX"
    private static let maxDepth = 40
    private static let maxNodes = 30_000

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
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = axAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                pressables.removeAll()
                nextID = 0
                nodeBudget = Self.maxNodes
                guard let tree = buildNode(window, depth: 0) else { continue }
                if opts.dump {
                    Log.info("window of \(app.localizedName ?? "?"):")
                    dump(tree, indent: 1)
                    continue
                }
                guard let prompt = ButtonPromptDetector.detect(
                    root: tree, policy: opts.policy, requireTrigger: opts.requireTrigger
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

        guard let pressable = pressables[target.id] else {
            Log.error("  lost the element between scan and press — leaving it")
            return false
        }
        let err: AXError
        switch pressable {
        case let .button(el):
            err = AXUIElementPerformAction(el, kAXPressAction as CFString)
        case let .action(el, name):
            err = AXUIElementPerformAction(el, name as CFString)
        }
        if err == .success {
            Log.info("  pressed \"\(target.label)\"")
            return true
        }
        Log.error("  press failed (AXError \(err.rawValue))")
        return false
    }

    // MARK: - AX tree -> UINode

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
            // A leaf for the detector; nested renderer buttons collapse into it.
            pressables[id] = .button(el)
            return UINode(id: id, role: role, label: label, text: text)
        }

        var children: [UINode] = []
        if let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for kid in kids {
                if let node = buildNode(kid, depth: depth + 1) { children.append(node) }
            }
        }
        // Notification-banner buttons live here, as custom actions.
        for (name, actionLabel) in customActions(el) {
            nextID += 1
            pressables[nextID] = .action(el, name: name)
            children.append(UINode(id: nextID, role: "AXAction", label: actionLabel))
        }
        return UINode(id: id, role: role, label: label, text: text, children: children)
    }

    private func customActions(_ el: AXUIElement) -> [(name: String, label: String)] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(el, &namesRef) == .success,
              let names = namesRef as? [String] else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(Self.standardActionPrefix) else { return nil }
            var descRef: CFString?
            AXUIElementCopyActionDescription(el, name as CFString, &descRef)
            guard let label = descRef as String?, !label.isEmpty else { return nil }
            return (name, label)
        }
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
        let pressable = pressables[node.id] != nil
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

    private func axAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var val: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success ? val : nil
    }
}
