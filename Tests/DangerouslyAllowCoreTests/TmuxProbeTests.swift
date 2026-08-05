import XCTest
@testable import DangerouslyAllowCore

/// Deciding whether the pane we are watching is still there sounds trivial and
/// is not: `tmux display-message -p -t <gone> '#{pane_id}'` **exits 0** and
/// prints nothing, so a successful call proves nothing on its own. Reading it
/// as "still alive" leaves a watcher polling a dead session forever; reading a
/// failed *invocation* as "gone" kills a watcher whose pane is perfectly fine —
/// which is what happened: a watcher exited eleven minutes into a session that
/// outlived it by another forty.
///
/// Strings and exit codes below were taken from tmux 3.5a, not invented.
final class TmuxProbeTests: XCTestCase {
    func testPaneIDMeansPresent() {
        XCTAssertEqual(TmuxProbe.classify(exitCode: 0, stdout: "%51\n", stderr: ""), .present)
    }

    /// The one that bites: success, and nothing printed.
    func testExitZeroWithNoPaneIDMeansGone() {
        XCTAssertEqual(TmuxProbe.classify(exitCode: 0, stdout: "", stderr: ""), .gone)
        XCTAssertEqual(TmuxProbe.classify(exitCode: 0, stdout: "\n", stderr: ""), .gone)
    }

    /// No server at all — everything it was hosting is gone with it.
    func testMissingServerMeansGone() {
        let stderr = "error connecting to /private/tmp/tmux-501/nosuchsocket "
            + "(No such file or directory)"
        XCTAssertEqual(TmuxProbe.classify(exitCode: 1, stdout: "", stderr: stderr), .gone)
        XCTAssertEqual(
            TmuxProbe.classify(exitCode: 1, stdout: "", stderr: "no server running on /tmp/x"),
            .gone
        )
    }

    /// Anything else says the *command* failed, which is not evidence about the
    /// pane. Spawning tmux can fail transiently — fork under load, a server
    /// mid-restart — and a watcher must not treat that as a death sentence.
    func testOtherFailuresAreUnknown() {
        XCTAssertEqual(TmuxProbe.classify(exitCode: -1, stdout: "", stderr: ""), .unknown)
        XCTAssertEqual(
            TmuxProbe.classify(exitCode: 1, stdout: "", stderr: "lost server"),
            .unknown
        )
        XCTAssertEqual(
            TmuxProbe.classify(exitCode: 2, stdout: "", stderr: "usage: display-message"),
            .unknown
        )
    }

    // MARK: - the debounce

    /// Only a run of agreeing observations retires a watcher, so one odd read
    /// cannot. `unknown` is not evidence either way and must not accumulate.
    func testWatcherRetiresOnlyAfterConsecutiveGoneReadings() {
        var life = PaneLife()
        XCTAssertFalse(life.shouldStop(after: .gone))
        XCTAssertFalse(life.shouldStop(after: .gone))
        XCTAssertTrue(life.shouldStop(after: .gone), "three in a row is a dead pane")
    }

    func testPresenceResetsTheCount() {
        var life = PaneLife()
        XCTAssertFalse(life.shouldStop(after: .gone))
        XCTAssertFalse(life.shouldStop(after: .gone))
        XCTAssertFalse(life.shouldStop(after: .present))
        XCTAssertFalse(life.shouldStop(after: .gone))
        XCTAssertFalse(life.shouldStop(after: .gone))
    }

    func testUnknownNeitherRetiresNorResets() {
        var life = PaneLife()
        XCTAssertFalse(life.shouldStop(after: .gone))
        XCTAssertFalse(life.shouldStop(after: .unknown))
        XCTAssertFalse(life.shouldStop(after: .unknown))
        XCTAssertFalse(life.shouldStop(after: .gone))
        XCTAssertTrue(life.shouldStop(after: .gone))
    }
}
