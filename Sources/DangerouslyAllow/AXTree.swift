import AppKit
import ApplicationServices
import DangerouslyAllowCore

/// Builds a pruned `UINode` tree from a live accessibility element, and
/// remembers how to press whatever it handed out an id for.
///
/// Shared by every watcher: the detectors are pure functions over `UINode`, and
/// this is the one place that touches `AXUIElement`. Ids are only valid until
/// the next `build` — a tree is a snapshot, and pressing through a stale one is
/// how you click the wrong button.
final class AXTree {
    enum Pressable {
        case button(AXUIElement)
        /// Notification banners expose their buttons as AX *actions on the
        /// banner*, not as child elements, so those become synthetic nodes.
        case action(AXUIElement, name: String)
    }

    private(set) var pressables: [Int: Pressable] = [:]
    /// True when the walk ran out of budget — the tree is a fragment, and a
    /// fragment is only safe to reason about if you wanted the whole thing.
    private(set) var truncated = false
    private var nextID = 0
    private var budget = 0
    private var deadline = Date.distantFuture

    static let maxDepth = 40
    /// Enough for an Electron app's renderer tree, where an approval card sits
    /// dozens of levels down among thousands of nodes.
    static let maxNodes = 30_000
    /// A native permission dialog is a title, a sentence and a few buttons.
    /// Anything that outgrows this is an ordinary window, and walking the rest
    /// of it costs a synchronous round trip per node for no possible gain.
    static let dialogNodes = 600

    /// Accessibility calls are synchronous IPC into the target app, and the
    /// default timeout is generous enough that one busy app — an Electron
    /// renderer mid-layout, say — can stall a whole sweep for minutes. Cap it
    /// globally: a prompt we answer a quarter-second late is still answered,
    /// and a sweep that never finishes answers nothing at all.
    static let messagingTimeout: Float = 0.25

    static func capMessagingTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }
    /// Standard actions every element carries (AXPress, AXShowMenu, …). Only
    /// custom ones — named like "Name:Close\nTarget:…", with the human label in
    /// the description — are worth surfacing.
    private static let standardActionPrefix = "AX"

    /// Fresh ids, and a fresh press table, on every call.
    ///
    /// `deadline` is the one that really matters. A node budget bounds a *big*
    /// tree, but not a *slow* one: against an app that has stopped answering,
    /// every read costs the full messaging timeout, and even a few hundred
    /// nodes can stall the sweep for minutes. Time is the honest unit.
    func build(_ element: AXUIElement, budget: Int = maxNodes, within: TimeInterval) -> UINode? {
        pressables.removeAll()
        truncated = false
        nextID = 0
        self.budget = budget
        deadline = Date(timeIntervalSinceNow: within)
        return node(element, depth: 0)
    }

    func isPressable(_ id: Int) -> Bool { pressables[id] != nil }

    /// nil when the element is gone from the table — the tree moved on.
    func press(_ id: Int) -> AXError? {
        switch pressables[id] {
        case let .button(element):
            return AXUIElementPerformAction(element, kAXPressAction as CFString)
        case let .action(element, name):
            return AXUIElementPerformAction(element, name as CFString)
        case nil:
            return nil
        }
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            ? value : nil
    }

    func windows(ofPID pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
               "com.google.Chrome.canary", "org.chromium.Chromium"].contains(bundleID)
        else { return windows }

        // Chrome's native confirmation may be a group/sheet inside the browser
        // window, not a separate AXWindow. Scan it independently before the
        // toolbar/page can exhaust the normal dialog budget. Keep live handles;
        // each subsequent build still creates its own fresh press table.
        var dialogs: [AXUIElement] = []
        var remaining = Self.dialogNodes
        let deadline = Date(timeIntervalSinceNow: 0.2)
        for window in windows {
            findNativeDialogs(window, depth: 0, remaining: &remaining,
                              deadline: deadline, into: &dialogs)
        }
        return dialogs + windows
    }

    private func findNativeDialogs(
        _ element: AXUIElement, depth: Int, remaining: inout Int,
        deadline: Date, into dialogs: inout [AXUIElement]
    ) {
        guard depth < Self.maxDepth, remaining > 0, Date() < deadline else { return }
        remaining -= 1
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        guard NativeDialogSurface.shouldDescend(role: role) else { return }
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        if NativeDialogSurface.isDialog(role: role, subrole: subrole) {
            dialogs.append(element)
            return
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            guard remaining > 0, Date() < deadline else { break }
            findNativeDialogs(child, depth: depth + 1, remaining: &remaining,
                              deadline: deadline, into: &dialogs)
        }
    }

    // MARK: - internals

    private func node(_ element: AXUIElement, depth: Int) -> UINode? {
        guard depth < Self.maxDepth else { return nil }
        guard budget > 0, Date() < deadline else {
            truncated = true
            return nil
        }
        budget -= 1
        nextID += 1
        let id = nextID

        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
        let label = title.isEmpty ? description : title
        let text = attribute(element, kAXValueAttribute) as? String ?? ""

        if role == (kAXButtonRole as String) {
            // A leaf for the detectors: nested renderer buttons collapse into
            // it, and its inner text belongs to the option, not to the card.
            pressables[id] = .button(element)
            return UINode(id: id, role: role, label: label, text: text)
        }

        var children: [UINode] = []
        if let kids = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for kid in kids {
                if let child = node(kid, depth: depth + 1) { children.append(child) }
            }
        }
        for (name, label) in customActions(element) {
            nextID += 1
            pressables[nextID] = .action(element, name: name)
            children.append(UINode(id: nextID, role: "AXAction", label: label))
        }
        return UINode(id: id, role: role, label: label, text: text, children: children)
    }

    private func customActions(_ element: AXUIElement) -> [(name: String, label: String)] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(Self.standardActionPrefix) else { return nil }
            var descriptionRef: CFString?
            AXUIElementCopyActionDescription(element, name as CFString, &descriptionRef)
            guard let label = descriptionRef as String?, !label.isEmpty else { return nil }
            return (name, label)
        }
    }
}
