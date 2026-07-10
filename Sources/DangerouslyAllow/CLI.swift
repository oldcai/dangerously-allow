import DangerouslyAllowCore
import Foundation

private let usage = """
dangerously-allow — auto-approve permission prompts from coding agents on macOS

USAGE
  dangerously-allow run [options] <command>       launch an agent in tmux, watcher attached
  dangerously-allow watch <tmux-target> [options] watch an agent already running in tmux
  dangerously-allow app <name> [options]          approval cards in a native app (e.g. ChatGPT)
  dangerously-allow notifications [options]       Allow-style actions on notification banners
  dangerously-allow gui [--dry-run]               native macOS TCC dialogs (needs sudo)

OPTIONS (run + watch)
  --policy once|session|always   which grant to click        (default: session)
  --never-approve <regex>        refuse if the pane matches  (repeatable)
  --dry-run                      log the plan, send no keys
  --verbose                      print the parsed menu
  --llm-fallback                 ask an LLM to label menus the rules miss
  --llm-model <id>               fallback model      (default: claude-haiku-4-5)
  --notify                       macOS notification when left for a human

OPTIONS (watch only)
  --once                         exit after the first approval
  --poll <ms>                    capture interval            (default: 400)
  --nav-delay <ms>               pause between arrow keys    (default: 80)
  --no-require-trigger           match menus with no question line above

LLM FALLBACK
  Only runs when the rule-based classifier does not recognise a menu. The model
  labels each row (it never picks one); its labels are reconciled with the rule
  engine's, most-reluctant-wins, and the policy then selects the target. The
  policy ceiling and --never-approve veto still apply, and it defers to a human
  when the model, the rules, or the policy disagree. Needs ANTHROPIC_API_KEY (or
  ANTHROPIC_AUTH_TOKEN) in the environment.

OPTIONS (run only)
  --name <name>                  tmux session name           (default: da-<pid>)
  --log <file>                   watcher log destination
  --no-attach                    leave the session detached

OPTIONS (app + notifications)
  --policy / --never-approve / --dry-run / --verbose / --notify / --once /
  --poll / --no-require-trigger  as above
  --dump                         print the app's pruned AX tree once and exit

  `app <name>` matches a running app by name or bundle id and presses the
  option the policy allows on approval cards it shows — e.g. the ChatGPT
  desktop app's "Allow once / Always allow / Deny". `notifications` does the
  same for action buttons on macOS notification banners. Both need this
  terminal to have Accessibility permission (System Settings → Privacy &
  Security → Accessibility) — no sudo. A card only counts when it offers both
  a grant and a refusal, like the TUI path.

POLICY
  once     click "Yes" / "Allow once"
  session  click "Allow for this session"; falls back to a one-time allow
  always   click "Allow for all future sessions" / "don't ask again" / "Trust folder"

  A policy never escalates: --policy session will not click an
  "all future sessions" option just because no session option exists.

EXAMPLES
  dangerously-allow run claude
  dangerously-allow run --policy always codex
  dangerously-allow run --never-approve 'rm -rf' --never-approve 'push --force' gemini
  dangerously-allow run --dry-run claude          # watch and log, press nothing
  dangerously-allow watch my-session --verbose    # attach to a running agent
"""

@main
struct CLI {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = args.first else {
            Log.plain(usage)
            exit(0)
        }

        switch subcommand {
        case "-h", "--help", "help":
            Log.plain(usage)
        case "-v", "--version":
            Log.plain("dangerously-allow 0.2.0")
        case "gui":
            args.removeFirst()
            AXScanner.run(dryRun: args.contains("--dry-run"), pollInterval: 0.5)
        case "watch":
            args.removeFirst()
            runWatch(args)
        case "app":
            args.removeFirst()
            runApp(args)
        case "notifications":
            args.removeFirst()
            runNotifications(args)
        case "run":
            args.removeFirst()
            exit(runRun(args))
        // Back-compat: the original tool took no subcommand and scanned GUI dialogs.
        case "--dry-run":
            AXScanner.run(dryRun: true, pollInterval: 0.5)
        default:
            Log.error("unknown subcommand '\(subcommand)'")
            Log.plain(usage)
            exit(2)
        }
    }

    /// Pull the value that follows `args[i]`, or exit with a usage error.
    private static func take(_ args: [String], _ i: inout Int, _ name: String) -> String {
        guard i + 1 < args.count else {
            Log.error("\(name) requires a value")
            exit(2)
        }
        i += 1
        return args[i]
    }

    private static func parsePolicy(_ raw: String) -> AllowPolicy {
        guard let policy = AllowPolicy(rawValue: raw) else {
            Log.error("--policy must be once|session|always, got '\(raw)'")
            exit(2)
        }
        return policy
    }

    // MARK: - watch

    private static func runWatch(_ args: [String]) {
        guard let target = args.first, !target.hasPrefix("-") else {
            Log.error("watch requires a tmux target, e.g. `dangerously-allow watch my-session`")
            exit(2)
        }

        var opts = WatchOptions(target: target)
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--policy": opts.policy = parsePolicy(take(args, &i, "--policy"))
            case "--dry-run": opts.dryRun = true
            case "--once": opts.stopAfterFirst = true
            case "--verbose", "-v": opts.verbose = true
            case "--no-require-trigger": opts.requireTrigger = false
            case "--never-approve": opts.neverApprove.append(take(args, &i, "--never-approve"))
            case "--poll": opts.pollInterval = (Double(take(args, &i, "--poll")) ?? 400) / 1000
            case "--nav-delay": opts.navDelay = (Double(take(args, &i, "--nav-delay")) ?? 80) / 1000
            case "--llm-fallback": opts.llmModel = opts.llmModel ?? "claude-haiku-4-5"
            case "--llm-model": opts.llmModel = take(args, &i, "--llm-model")
            case "--notify": opts.notify = true
            default:
                Log.error("unknown option '\(args[i])'")
                exit(2)
            }
            i += 1
        }

        signal(SIGINT) { _ in
            Log.plain("")
            Log.info("stopped")
            exit(0)
        }

        do {
            try Watcher(options: opts).run()
        } catch {
            Log.error("\(error)")
            exit(1)
        }
    }

    // MARK: - app / notifications

    private static func runApp(_ args: [String]) {
        guard let name = args.first, !name.hasPrefix("-") else {
            Log.error("app requires an app name or bundle id, e.g. `dangerously-allow app ChatGPT`")
            exit(2)
        }
        watchApp(AppWatchOptions(appName: name), Array(args.dropFirst()))
    }

    private static func runNotifications(_ args: [String]) {
        // Notification banners live in Notification Center's process, and their
        // buttons are AX actions on the banner element — AppWatcher knows how.
        watchApp(AppWatchOptions(appName: "com.apple.notificationcenterui"), args)
    }

    private static func watchApp(_ base: AppWatchOptions, _ args: [String]) {
        var opts = base
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--policy": opts.policy = parsePolicy(take(args, &i, "--policy"))
            case "--dry-run": opts.dryRun = true
            case "--once": opts.stopAfterFirst = true
            case "--verbose", "-v": opts.verbose = true
            case "--no-require-trigger": opts.requireTrigger = false
            case "--never-approve": opts.neverApprove.append(take(args, &i, "--never-approve"))
            case "--poll": opts.pollInterval = (Double(take(args, &i, "--poll")) ?? 500) / 1000
            case "--notify": opts.notify = true
            case "--dump": opts.dump = true
            default:
                Log.error("unknown option '\(args[i])'")
                exit(2)
            }
            i += 1
        }

        signal(SIGINT) { _ in
            Log.plain("")
            Log.info("stopped")
            exit(0)
        }

        AppWatcher(options: opts).run()
    }

    // MARK: - run

    private static func runRun(_ args: [String]) -> Int32 {
        var opts = RunOptions(sessionName: "da-\(getpid())", command: [])
        var i = 0
        loop: while i < args.count {
            switch args[i] {
            case "--name": opts.sessionName = take(args, &i, "--name")
            case "--log": opts.logPath = take(args, &i, "--log")
            case "--no-attach": opts.attach = false
            case "--policy":
                let raw = take(args, &i, "--policy")
                _ = parsePolicy(raw) // validate here so the child cannot fail late
                opts.watchArgs += ["--policy", raw]
            case "--never-approve":
                opts.watchArgs += ["--never-approve", take(args, &i, "--never-approve")]
            case "--dry-run": opts.watchArgs.append("--dry-run")
            case "--verbose": opts.watchArgs.append("--verbose")
            case "--llm-fallback": opts.watchArgs.append("--llm-fallback")
            case "--llm-model": opts.watchArgs += ["--llm-model", take(args, &i, "--llm-model")]
            case "--notify": opts.watchArgs.append("--notify")
            case "--":
                i += 1
                break loop
            default:
                // The first bare token starts the agent's own command line.
                if args[i].hasPrefix("-") {
                    Log.error("unknown option '\(args[i])'")
                    return 2
                }
                break loop
            }
            i += 1
        }

        opts.command = Array(args[i...])
        guard !opts.command.isEmpty else {
            Log.error("run requires a command, e.g. `dangerously-allow run claude`")
            return 2
        }
        return Runner.run(opts)
    }
}
