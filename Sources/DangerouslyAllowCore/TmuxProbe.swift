import Foundation

/// What a probe of the watched pane established — including the honest third
/// answer, which the first version of this did not have.
public enum PaneStatus: Equatable {
    case present
    case gone
    /// The probe itself failed. Says nothing about the pane.
    case unknown
}

/// Reads the outcome of `tmux display-message -p -t <target> '#{pane_id}'`.
///
/// The trap: tmux **exits 0 and prints nothing** when the target does not
/// resolve. So a zero exit is not proof of life — only a pane id is — and a
/// non-zero exit is not proof of death, because spawning tmux can fail for
/// reasons that have nothing to do with the pane.
public enum TmuxProbe {
    /// stderr from a tmux that has no server to talk to. Everything it hosted
    /// went with it, so this really is death.
    static let serverGonePhrases = ["error connecting to", "no server running"]

    public static func classify(exitCode: Int32, stdout: String, stderr: String) -> PaneStatus {
        if exitCode == 0 {
            let id = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? .gone : .present
        }
        let lowered = stderr.lowercased()
        if serverGonePhrases.contains(where: { lowered.contains($0) }) { return .gone }
        return .unknown
    }
}

/// Decides when a watcher has outlived its pane.
///
/// A single reading is not enough to retire a watcher: exiting is permanent,
/// and the cost of being wrong is a session that silently stops being answered
/// while the user assumes it is covered. So only a run of agreeing readings
/// counts, and `unknown` — which is not evidence — neither accumulates nor
/// clears what came before.
public struct PaneLife {
    public static let needed = 3

    private var consecutiveGone = 0

    public init() {}

    public mutating func shouldStop(after status: PaneStatus) -> Bool {
        switch status {
        case .present:
            consecutiveGone = 0
        case .unknown:
            break
        case .gone:
            consecutiveGone += 1
        }
        return consecutiveGone >= Self.needed
    }
}
