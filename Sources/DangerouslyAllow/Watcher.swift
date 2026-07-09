import DangerouslyAllowCore
import Foundation

struct WatchOptions {
    var target: String
    var policy: AllowPolicy = .session
    var dryRun = false
    var stopAfterFirst = false
    var pollInterval: TimeInterval = 0.4
    var navDelay: TimeInterval = 0.08
    var maxNavSteps = 12
    var neverApprove: [String] = []
    var requireTrigger = true
    var verbose = false
}

/// Polls a tmux pane, and when a permission menu appears, walks the cursor onto
/// the option the policy allows and presses Enter.
///
/// Navigation is closed-loop: one arrow key, re-capture, re-read the cursor.
/// A blind "press Down N times" would desynchronise whenever a TUI skips a
/// disabled row or wraps around the ends of the list.
///
/// We never type the option's digit. Gemini CLI's `useSelectionList` fires
/// `SELECT_CURRENT` the moment a digit cannot prefix a longer valid number, so
/// digit-then-Enter would confirm the menu *and* leak a stray Enter into
/// whatever the harness showed next.
final class Watcher {
    private let channel: TmuxChannel
    private let opts: WatchOptions
    /// Prompt we already acted on, cleared once it leaves the screen. Prevents
    /// re-confirming a menu that lingers for a frame, while still allowing an
    /// identical prompt to be approved again later.
    private var handled: String?

    init(options: WatchOptions) throws {
        self.opts = options
        self.channel = try TmuxChannel(target: options.target)
    }

    func run() {
        Log.info("watching tmux target '\(opts.target)'")
        Log.info("policy: \(opts.policy.rawValue)\(opts.dryRun ? "  (DRY RUN — no keys sent)" : "")")
        if !opts.neverApprove.isEmpty {
            Log.info("never-approve: \(opts.neverApprove.joined(separator: ", "))")
        }

        while true {
            guard channel.paneExists() else {
                Log.info("pane '\(opts.target)' is gone — exiting")
                return
            }
            do {
                let screen = try channel.capturePane()
                if let prompt = PromptDetector.detect(
                    screen: screen,
                    policy: opts.policy,
                    requireTrigger: opts.requireTrigger
                ) {
                    if handled != prompt.fingerprint {
                        if handle(prompt: prompt, screen: screen), opts.stopAfterFirst {
                            return
                        }
                    }
                } else {
                    handled = nil
                }
            } catch {
                Log.error("capture failed: \(error)")
            }
            Thread.sleep(forTimeInterval: opts.pollInterval)
        }
    }

    /// Returns true when the prompt was confirmed.
    private func handle(prompt: DetectedPrompt, screen: String) -> Bool {
        if let blocked = PromptDetector.blockingPattern(screen: screen, neverApprove: opts.neverApprove) {
            Log.warn("REFUSING — screen matches --never-approve /\(blocked)/")
            Log.warn("  leaving prompt for a human: \(prompt.target.label)")
            handled = prompt.fingerprint
            return false
        }

        if opts.verbose {
            for o in prompt.options {
                let mark = o.isCursor ? "●" : " "
                Log.info("  \(mark) \(o.number). \(o.label)  [\(o.kind.rawValue)]")
            }
        }

        guard let startCursor = prompt.cursorIndex else {
            Log.warn("found a permission menu but no cursor glyph — not guessing.")
            Log.warn("  target would have been: \(prompt.target.label)")
            Log.warn("  re-run with --verbose to see the parsed menu")
            handled = prompt.fingerprint
            return false
        }

        Log.info("prompt: \(prompt.options.count) options, cursor on #\(prompt.options[startCursor].number)")
        Log.info("  -> choosing #\(prompt.target.number) \"\(prompt.target.label)\" [\(prompt.target.kind.rawValue)]")

        if opts.dryRun {
            let dist = abs(prompt.targetIndex - startCursor)
            let dir = prompt.targetIndex > startCursor ? "Down" : "Up"
            let plan = dist == 0 ? "Enter" : "\(dir)×\(dist), Enter"
            Log.info("  [dry-run] would send: \(plan)")
            handled = prompt.fingerprint
            return false
        }

        return navigateAndConfirm(prompt)
    }

    private func navigateAndConfirm(_ prompt: DetectedPrompt) -> Bool {
        for step in 0..<opts.maxNavSteps {
            // Re-read the world each iteration; the TUI may have moved or closed.
            guard let screen = try? channel.capturePane(),
                  let now = PromptDetector.detect(
                      screen: screen, policy: opts.policy, requireTrigger: opts.requireTrigger
                  ),
                  now.fingerprint == prompt.fingerprint
            else {
                Log.warn("prompt changed mid-navigation after \(step) step(s) — aborting")
                return false
            }
            guard let cursor = now.cursorIndex else {
                Log.warn("lost the cursor mid-navigation — aborting")
                return false
            }

            let move = PromptDetector.nextStep(cursor: cursor, target: now.targetIndex)
            do {
                try channel.sendKeys([move.tmuxKey])
            } catch {
                Log.error("send-keys failed: \(error)")
                return false
            }

            if move == .confirm {
                Log.info("  confirmed \"\(now.target.label)\"")
                handled = prompt.fingerprint
                return true
            }
            Thread.sleep(forTimeInterval: opts.navDelay)
        }
        Log.warn("gave up after \(opts.maxNavSteps) navigation steps")
        handled = prompt.fingerprint
        return false
    }
}
