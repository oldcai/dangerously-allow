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
    /// When set, unrecognised menus are sent to this model to label. nil = off.
    var llmModel: String?
    /// Post a macOS notification when the fallback leaves a prompt for a human.
    var notify = false
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
    /// Built once when `--llm-fallback` is set and credentials are present.
    private let adjudicator: NetworkAdjudicator?

    init(options: WatchOptions) throws {
        self.opts = options
        self.channel = try TmuxChannel(target: options.target)
        if let model = options.llmModel {
            if let a = NetworkAdjudicator(model: model) {
                self.adjudicator = a
            } else {
                Log.warn("--llm-fallback set but no credentials — set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN. Fallback disabled.")
                self.adjudicator = nil
            }
        } else {
            self.adjudicator = nil
        }
    }

    func run() {
        Log.info("watching tmux target '\(opts.target)'")
        Log.info("policy: \(opts.policy.rawValue)\(opts.dryRun ? "  (DRY RUN — no keys sent)" : "")")
        if !opts.neverApprove.isEmpty {
            Log.info("never-approve: \(opts.neverApprove.joined(separator: ", "))")
        }
        if let adjudicator {
            Log.info("llm fallback: \(adjudicator.model) will label menus the rules miss")
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
                } else if let adjudicator {
                    // Rules did not recognise the screen. If it still looks like a
                    // menu, ask the model to label it — once per distinct menu.
                    let scan = MenuScan.scan(screen)
                    if scan.rows.count >= 2 {
                        let fingerprint = MenuScan.fingerprint(scan.rows)
                        if handled != fingerprint {
                            let confirmed = adjudicate(
                                screen: screen, fingerprint: fingerprint, adjudicator: adjudicator
                            )
                            if confirmed, opts.stopAfterFirst { return }
                        }
                    } else {
                        handled = nil
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

    // MARK: - LLM fallback

    /// Ask the model to label an unrecognised menu, then act on the reconciled
    /// verdict. Marks the menu handled in every outcome, so a lingering prompt
    /// costs at most one API call. Returns true only when a row was confirmed.
    private func adjudicate(
        screen: String, fingerprint: String, adjudicator: NetworkAdjudicator
    ) -> Bool {
        handled = fingerprint

        // Veto before spending an API call — never send a blocked pane out, and
        // never act on one.
        if let blocked = PromptDetector.blockingPattern(screen: screen, neverApprove: opts.neverApprove) {
            Log.warn("LLM fallback: REFUSING — screen matches --never-approve /\(blocked)/")
            return false
        }

        Log.info("LLM fallback: unrecognised menu — asking \(adjudicator.model) to label it")
        switch AdjudicatedDetector.detect(screen: screen, policy: opts.policy, adjudicator: adjudicator) {
        case .notAMenu:
            return false
        case let .deferToHuman(reason):
            Log.warn("LLM fallback: leaving for a human — \(reason)")
            notify("Unrecognised prompt: \(reason)")
            return false
        case let .act(number, label, kind):
            Log.info("LLM fallback: choosing #\(number) \"\(label)\" [\(kind.rawValue)]")
            if opts.dryRun {
                Log.info("  [dry-run] would navigate to option \(number) and confirm")
                return false
            }
            if navigateAdjudicated(targetNumber: number, fingerprint: fingerprint) {
                Log.info("  confirmed \"\(label)\"")
                return true
            }
            Log.warn("  LLM navigation failed")
            return false
        }
    }

    /// The same closed-loop navigation as the rule-based path — one arrow key,
    /// re-capture, re-read the cursor — driven by the option number the policy
    /// picked from the reconciled labels. Aborts if the menu changes underneath.
    private func navigateAdjudicated(targetNumber: Int, fingerprint: String) -> Bool {
        for _ in 0..<opts.maxNavSteps {
            guard let screen = try? channel.capturePane(),
                  let state = MenuScan.navigationState(for: screen, targetNumber: targetNumber),
                  state.fingerprint == fingerprint
            else {
                Log.warn("  menu changed mid-navigation — aborting")
                return false
            }
            guard let cursor = state.cursorIndex, let target = state.targetIndex else {
                Log.warn("  lost the cursor mid-navigation — aborting")
                return false
            }
            let move = PromptDetector.nextStep(cursor: cursor, target: target)
            do {
                try channel.sendKeys([move.tmuxKey])
            } catch {
                Log.error("  send-keys failed: \(error)")
                return false
            }
            if move == .confirm { return true }
            Thread.sleep(forTimeInterval: opts.navDelay)
        }
        Log.warn("  gave up after \(opts.maxNavSteps) navigation steps")
        return false
    }

    /// Post a macOS notification (only with --notify).
    private func notify(_ message: String) {
        guard opts.notify else { return }
        Notify.post(message)
    }
}
