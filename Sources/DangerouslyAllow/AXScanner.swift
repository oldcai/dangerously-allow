import AppKit
import ApplicationServices

/// Auto-clicks native macOS TCC dialogs (Microphone, Screen Recording,
/// Accessibility, …). These are real AppKit windows, so they are reachable
/// through the Accessibility API — unlike a permission menu drawn *inside* a
/// terminal, which is just text and needs `Watcher`.
enum AXScanner {
    static let allowTitles: Set<String> = ["Allow", "OK", "Open System Settings"]

    static let permissionKeywords: [String] = [
        "would like to access", "would like to use",
        "would like to record", "would like to control",
        "wants to access", "wants to use",
        "Microphone", "Camera", "Screen Recording", "Accessibility",
        "Speech Recognition", "Input Monitoring", "Full Disk Access",
        "Automation", "Developer Tools", "Location",
    ]

    static func run(dryRun: Bool, pollInterval: TimeInterval) {
        Log.info("scanning for macOS permission dialogs\(dryRun ? " (DRY RUN)" : "")")
        Log.info("poll interval: \(pollInterval)s — Ctrl+C to stop")

        if !AXIsProcessTrusted() {
            Log.warn("AXIsProcessTrusted() = false — re-run with sudo, or grant Accessibility")
        }

        while true {
            scanAndAllow(dryRun: dryRun)
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    static func scanAndAllow(dryRun: Bool) {
        for app in NSWorkspace.shared.runningApplications {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = axAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                process(
                    window: window,
                    appName: app.localizedName ?? "pid:\(app.processIdentifier)",
                    dryRun: dryRun
                )
            }
        }
    }

    private static func process(window: AXUIElement, appName: String, dryRun: Bool) {
        var texts: [String] = []
        collectTexts(from: window, into: &texts)
        let blob = texts.joined(separator: " ")
        guard permissionKeywords.contains(where: { blob.localizedCaseInsensitiveContains($0) })
        else { return }

        var buttons: [(String, AXUIElement)] = []
        collectButtons(from: window, into: &buttons)

        for (title, element) in buttons where allowTitles.contains(title) {
            let context = String(blob.prefix(140))
            if dryRun {
                Log.info("[dry-run] would click '\(title)' in \(appName)")
            } else {
                let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if err == .success {
                    Log.info("clicked '\(title)' in \(appName)")
                } else {
                    Log.error("failed '\(title)' in \(appName) (AXError \(err.rawValue))")
                }
            }
            Log.plain("           \(context)")
            return
        }
    }

    private static func collectTexts(from el: AXUIElement, into out: inout [String]) {
        if let t = axAttr(el, kAXTitleAttribute) as? String, !t.isEmpty { out.append(t) }
        if let v = axAttr(el, kAXValueAttribute) as? String, !v.isEmpty { out.append(v) }
        if let d = axAttr(el, kAXDescriptionAttribute) as? String, !d.isEmpty { out.append(d) }
        guard let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for kid in kids { collectTexts(from: kid, into: &out) }
    }

    private static func collectButtons(from el: AXUIElement, into out: inout [(String, AXUIElement)]) {
        if let role = axAttr(el, kAXRoleAttribute) as? String,
           role == (kAXButtonRole as String),
           let title = axAttr(el, kAXTitleAttribute) as? String, !title.isEmpty {
            out.append((title, el))
        }
        guard let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for kid in kids { collectButtons(from: kid, into: &out) }
    }

    private static func axAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var val: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success ? val : nil
    }
}
