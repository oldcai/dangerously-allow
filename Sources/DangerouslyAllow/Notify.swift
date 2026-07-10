import Foundation

/// Post a macOS notification (only meaningful under --notify). Best-effort: a
/// failure to notify never affects a watch loop. Our own notifications carry
/// no actions, so the notification watcher can never press anything on them.
enum Notify {
    static func post(_ message: String) {
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(safe)\" with title \"dangerously-allow\""]
        p.standardError = Pipe()
        try? p.run()
    }
}
