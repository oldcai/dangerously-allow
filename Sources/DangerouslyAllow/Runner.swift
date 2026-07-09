import Foundation

struct RunOptions {
    var sessionName: String
    var command: [String]
    var watchArgs: [String] = []
    var logPath: String?
    var attach = true
}

/// Starts an agent inside tmux and rides along with a watcher on its pane.
///
/// The agent's TUI needs a pane we can both read (`capture-pane`) and write
/// (`send-keys`), so it cannot simply inherit this terminal. tmux supplies that
/// channel — the same arrangement lazytyper uses to deliver transcriptions into
/// a running CLI.
///
/// The watcher runs *beside* the pane as a child process, never inside it.
enum Runner {
    /// Wrap an argument so tmux's `sh -c` sees it as one token.
    static func shellQuote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isValidSessionName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    static func defaultLogPath(session: String) -> String {
        NSTemporaryDirectory() + "dangerously-allow-\(session).log"
    }

    static func run(_ opts: RunOptions) -> Int32 {
        guard let tmux = TmuxChannel.locate() else {
            Log.error("tmux is not installed. brew install tmux")
            return 1
        }
        guard isValidSessionName(opts.sessionName) else {
            Log.error("session name must be letters, digits, dashes, underscores")
            return 2
        }
        guard let selfPath = Bundle.main.executablePath else {
            Log.error("cannot locate my own executable")
            return 1
        }

        let logPath = opts.logPath ?? defaultLogPath(session: opts.sessionName)
        let command = opts.command.map(shellQuote).joined(separator: " ")

        // Detached sessions default to 80x24, which is too cramped for an agent
        // TUI. Attaching resizes to the real client, so this only matters when
        // we never attach.
        var newSession = ["new-session", "-d", "-s", opts.sessionName]
        if !opts.attach { newSession += ["-x", "200", "-y", "50"] }
        newSession.append(command)

        guard shell(tmux, newSession) == 0 else {
            Log.error("failed to create tmux session '\(opts.sessionName)'")
            Log.error("  a session with that name may already exist (tmux ls)")
            return 1
        }

        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            Log.error("cannot write watcher log to \(logPath)")
            _ = shell(tmux, ["kill-session", "-t", opts.sessionName])
            return 1
        }

        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: selfPath)
        watcher.arguments = ["watch", opts.sessionName] + opts.watchArgs
        watcher.standardOutput = logHandle
        watcher.standardError = logHandle
        do {
            try watcher.run()
        } catch {
            Log.error("failed to start watcher: \(error)")
            _ = shell(tmux, ["kill-session", "-t", opts.sessionName])
            return 1
        }

        Log.plain("session:  \(opts.sessionName)")
        Log.plain("watcher:  pid \(watcher.processIdentifier), log \(logPath)")
        Log.plain("")

        defer {
            if watcher.isRunning { watcher.terminate() }
            _ = shell(tmux, ["kill-session", "-t", opts.sessionName])
            try? logHandle.close()
        }

        if opts.attach {
            // Inherits this process's stdio, so tmux takes over the terminal.
            _ = shell(tmux, ["attach", "-t", opts.sessionName])
        } else {
            Log.plain("running detached; tail -f \(logPath)")
            while shell(tmux, ["has-session", "-t", opts.sessionName], quiet: true) == 0 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        return 0
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String], quiet: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if quiet {
            p.standardOutput = Pipe()
            p.standardError = Pipe()
        }
        do {
            try p.run()
        } catch {
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
