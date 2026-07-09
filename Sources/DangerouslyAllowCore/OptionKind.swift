import Foundation

/// How much access a menu option grants, ordered by how long the grant persists.
public enum OptionKind: String, Equatable, CaseIterable {
    /// Grants this one call only. "Yes", "Allow once".
    case allowOnce
    /// Grants until the harness exits. "Allow for this session (0 apps)".
    case allowSession
    /// Persists past this run. "Allow for all future sessions",
    /// "Yes, and don't ask again", "Yes, and bypass permissions".
    case allowAlways
    /// Refuses. "No, suggest changes (esc)", "Deny, and tell Claude ...".
    case deny
    /// Neither grants nor refuses. "Modify with external editor".
    case neutral

    public var grantsAccess: Bool {
        switch self {
        case .allowOnce, .allowSession, .allowAlways: return true
        case .deny, .neutral: return false
        }
    }
}

/// Which grant the watcher is willing to click.
public enum AllowPolicy: String, CaseIterable {
    case once
    case session
    case always

    /// Ordered preference. Each policy falls back only to *less* persistent
    /// grants, never more — so `--policy session` can never click
    /// "Allow for all future sessions" just because no session option existed.
    public var preference: [OptionKind] {
        switch self {
        case .once: return [.allowOnce]
        case .session: return [.allowSession, .allowOnce]
        case .always: return [.allowAlways, .allowSession, .allowOnce]
        }
    }
}
