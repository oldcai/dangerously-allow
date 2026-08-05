import DangerouslyAllowCore
import Foundation

enum TmuxError: Error, CustomStringConvertible {
    case notFound
    case failed(String, Int32, String)

    var description: String {
        switch self {
        case .notFound:
            return "tmux not found on PATH. Install it: brew install tmux"
        case let .failed(cmd, code, err):
            return "tmux \(cmd) exited \(code): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Read/write access to a tmux pane. `capture-pane` is the read side of the
/// channel, `send-keys` the write side — the same mechanism lazytyper uses to
/// deliver transcriptions into a running CLI.
struct TmuxChannel {
    let target: String
    private let tmux: String

    init(target: String) throws {
        self.target = target
        guard let path = TmuxChannel.locate() else { throw TmuxError.notFound }
        self.tmux = path
    }

    static func locate() -> String? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Fall back to PATH lookup.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "tmux"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// nil when tmux could not be started at all — fork failure under load, a
    /// binary that vanished mid-session. Distinct from "tmux ran and said no".
    private func attempt(_ args: [String]) -> (code: Int32, out: String, err: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return nil
        }
        // Read before waiting so a large pane cannot fill the pipe and deadlock.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(decoding: data, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let joined = args.joined(separator: " ")
        guard let result = attempt(args) else {
            throw TmuxError.failed(joined, -1, "could not start tmux")
        }
        guard result.code == 0 else {
            throw TmuxError.failed(joined, result.code, result.err)
        }
        return result.out
    }

    /// Visible contents of the pane, as plain text. Cursor glyphs (`❯`, `●`)
    /// survive; we deliberately do not pass `-e`, so no escape sequences appear.
    func capturePane() throws -> String {
        try run(["capture-pane", "-p", "-t", target])
    }

    func sendKeys(_ keys: [String]) throws {
        try run(["send-keys", "-t", target] + keys)
    }

    /// Asking tmux whether the pane is still there. See `TmuxProbe` for why the
    /// exit code alone cannot answer that.
    func paneStatus() -> PaneStatus {
        let args = ["display-message", "-p", "-t", target, "#{pane_id}"]
        guard let result = attempt(args) else { return .unknown }
        return TmuxProbe.classify(exitCode: result.code, stdout: result.out, stderr: result.err)
    }
}
