import DangerouslyAllowCore
import Foundation

private let usage = """
dangerously-allow — auto-approve the permission prompts the Claude and ChatGPT
desktop apps put in your way, on macOS

USAGE
  dangerously-allow [options]                     watch the whole desktop

  With no arguments it answers all of it, in one process: the approval cards
  inside the ChatGPT and Claude desktop apps, Allow-style actions on
  notification banners, and the native macOS permission dialogs they trigger on
  the way to controlling your machine ("ChatGPT wants access to control X").
  Needs this terminal to have Accessibility permission (System Settings →
  Privacy & Security → Accessibility). No sudo.

OPTIONS
  --policy once|session|always   which grant to click  (default: session for
                                 cards, always for system dialogs — see POLICY)
  --app <name>                   also answer cards in this app  (repeatable;
                                 a localized name or a bundle id)
  --never-approve <regex>        refuse if the prompt matches   (repeatable)
  --dry-run                      log the plan, press nothing
  --verbose                      print every option and the tier it was given
  --once                         exit after the first approval
  --poll <ms>                    scan interval                  (default: 500)
  --no-require-trigger           match prompts whose wording is not recognised
  --notify                       macOS notification when left for a human

ONE CHANNEL AT A TIME
  dangerously-allow gui [options]                 native macOS permission dialogs
  dangerously-allow app <name> [options]          approval cards in one app
  dangerously-allow notifications [options]       notification banners only

  The desktop mode's three channels, separately — mostly useful with --dump,
  which prints an app's pruned AX tree so an unrecognised prompt can be pasted
  into an issue verbatim.

TERMINAL AGENTS (secondary)
  dangerously-allow run [options] <command>       launch an agent in tmux, watcher attached
  dangerously-allow watch <tmux-target> [options] watch an agent already running in tmux

  A CLI agent can usually just be told to allow everything
  (`claude --dangerously-skip-permissions`), so this is for the cases where it
  cannot be: the watcher reads the TUI menu out of a tmux pane and drives it
  with arrow keys.

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

OPTIONS (gui)
  --policy / --never-approve / --dry-run / --verbose / --dump / --notify /
  --once / --poll / --no-require-trigger  as above  (--policy default: always)

  A native permission dialog is answered into the TCC database, so its grant
  outlives the process: a plain "Allow" is a *permanent* grant however mildly
  it is worded. gui defaults to --policy always and presses it, because a TCC
  dialog almost never offers a session- or once-scoped button — a session
  default would leave the common dialogs untouched. Refusals and neutral
  buttons ("Open System Settings") are never pressed under any policy; pass
  --policy session to press only an explicit "Allow Once". Unlike a card, a
  system dialog need not offer a refusal — macOS 15's screen-capture prompt
  offers "Allow" and "Open System Settings", and the way out is Esc — so the
  gate is the dialog's wording plus the policy ceiling. Run --verbose to see
  the dialogs it passed over and why.

POLICY
  once     click "Yes" / "Allow once"
  session  click "Allow for this session"; falls back to a one-time allow
  always   click "Allow for all future sessions" / "don't ask again" / "Trust folder"

  A policy never escalates: --policy session will not click an
  "all future sessions" option just because no session option exists.

  The two desktop channels start from different defaults because the same word
  means different things in each. "Allow once" on an in-app card really is
  one-shot, so cards default to session. "Allow" on a system dialog is written
  to the TCC database and outlives the process — it is a permanent grant however
  mildly it is worded — so system dialogs are pressed only under always, which
  is their default because they almost never offer anything narrower. Passing
  --policy sets both: --policy session stops answering system dialogs
  altogether unless one offers an explicit "Allow Once".

EXAMPLES
  dangerously-allow                               # the usual: watch everything
  dangerously-allow --dry-run --verbose           # see what it would press
  dangerously-allow --never-approve 'rm -rf' --never-approve 'Full Disk Access'
  dangerously-allow --app Cursor                  # answer another app's cards too
  dangerously-allow app ChatGPT --dump            # print one app's AX tree
  dangerously-allow run claude                    # secondary: a TUI agent in tmux
"""

@main
struct CLI {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        // No arguments is the point of the tool: start watching everything.
        guard let subcommand = args.first else {
            runDesktop([])
            return
        }

        switch subcommand {
        case "-h", "--help", "help":
            Log.plain(usage)
        case "-v", "--version":
            Log.plain("dangerously-allow 0.3.0")
        case "gui":
            args.removeFirst()
            runGui(args)
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
        default:
            // A leading flag means the desktop mode with options, not a typo:
            // `dangerously-allow --dry-run` has always started watching.
            guard subcommand.hasPrefix("-") else {
                Log.error("unknown subcommand '\(subcommand)'")
                Log.plain(usage)
                exit(2)
            }
            runDesktop(args)
        }
    }

    // MARK: - desktop (the default)

    private static func runDesktop(_ args: [String]) {
        var opts = DesktopOptions()
        var extraApps: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--policy":
                // One flag, both channels — see POLICY in the usage text for
                // why they start from different defaults.
                let policy = parsePolicy(take(args, &i, "--policy"))
                opts.policies = DesktopPolicies(dialog: policy, card: policy)
            case "--app": extraApps.append(take(args, &i, "--app"))
            case "--dry-run": opts.dryRun = true
            case "--once": opts.stopAfterFirst = true
            case "--verbose", "-v": opts.verbose = true
            case "--no-require-trigger": opts.requireTrigger = false
            case "--never-approve": opts.neverApprove.append(take(args, &i, "--never-approve"))
            case "--poll": opts.pollInterval = (Double(take(args, &i, "--poll")) ?? 500) / 1000
            case "--notify": opts.notify = true
            default:
                Log.error("unknown option '\(args[i])'")
                exit(2)
            }
            i += 1
        }
        opts.apps += extraApps

        signal(SIGINT) { _ in
            Log.plain("")
            Log.info("stopped")
            exit(0)
        }

        DesktopWatcher(options: opts).run()
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

    // MARK: - gui

    private static func runGui(_ args: [String]) {
        var opts = GuiWatchOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--policy": opts.policy = parsePolicy(take(args, &i, "--policy"))
            case "--dry-run": opts.dryRun = true
            case "--once": opts.stopAfterFirst = true
            case "--verbose", "-v": opts.verbose = true
            case "--dump": opts.dump = true
            case "--no-require-trigger": opts.requireTrigger = false
            case "--never-approve": opts.neverApprove.append(take(args, &i, "--never-approve"))
            case "--poll": opts.pollInterval = (Double(take(args, &i, "--poll")) ?? 500) / 1000
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

        AXScanner.run(options: opts)
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
