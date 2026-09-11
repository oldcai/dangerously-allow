# dangerously-allow

Auto-approves the permission prompts the **Claude and ChatGPT desktop apps** put
in your way, on macOS.

> **Read this before running it.** This tool presses "Allow" on prompts that
> exist to protect you. It grants an agent permission to act on your machine
> without your individually approving each step. Use it on work you can afford
> to lose, in a directory under version control, and start with `--dry-run`.

```bash
dangerously-allow
```

That is the whole thing. No subcommand, no sudo — it watches everything the
desktop agents can ask for:

| Prompt | Example |
| --- | --- |
| In-app approval card | ChatGPT desktop's "Allow once / Always allow / Deny" |
| Native macOS permission dialog | "ChatGPT wants access to control Finder" |
| Notification banner action | an "Allow" button on a macOS notification |

The desktop apps are the reason this exists. A CLI agent can simply be told to
allow everything — `claude --dangerously-skip-permissions` — and needs no help
from anyone. The desktop apps have no such switch, and they ask constantly:
before touching a file, before driving the browser, and above all before taking
control of your machine, which is a *system* dialog rather than one of their own.

Answering all of that means three unrelated mechanisms, which is why it used to
be three commands you had to remember to start. Forgetting one silently meant a
prompt sat there waiting for a human. Now one process does all three.

## Install

```bash
make install              # builds release, installs into /usr/local/bin
make install PREFIX=~/.local
make uninstall
```

`/usr/local/bin` may need `sudo make install`. tmux is only needed for the
secondary terminal-agent mode (`brew install tmux`).

```bash
make check                # 120 unit tests + 12 end-to-end tests through real tmux
make help                 # list targets
```

Grant your terminal Accessibility permission (System Settings → Privacy &
Security → Accessibility). That is the only setup, and it replaces the `sudo`
earlier versions asked for.

## Use

```bash
dangerously-allow                               # the usual: watch everything
dangerously-allow --dry-run --verbose           # see what it would press, press nothing
dangerously-allow --never-approve 'Full Disk Access'
dangerously-allow --app Cursor                  # answer another app's cards too
```

Anything shaped like a prompt — a window with a handful of buttons, one of
which grants something — is answered wherever it appears, whatever its wording.
That includes prompts no keyword list knows: Chrome's "Allow remote debugging?"
is nobody's TCC sentence, and it is answered all the same. `--require-trigger`
narrows this back to prompts whose wording is recognised.

Chrome/Chromium native dialog groups and sheets are also scanned separately
when embedded in the browser window. Discovery skips `AXWebArea` content, so
web-page dialogs are not promoted to native permission prompts. The remote
debugging confirmation uses the dialog policy: the default presses **Allow**,
never **Cancel** or **Turn off in settings**; `--policy session` leaves it alone.

The native-dialog detector skips `AXWebArea` documents, including small popups
without a browser toolbar. Approval *cards* are still only answered in apps on a list — the ChatGPT
and Claude desktop apps, and notification banners — so that a card keeps the
cautious card policy and its one-shot "Allow once". `--app` extends that list,
by localized name or bundle id.

Several prompts at once are answered in one sweep, and a sweep that pressed
something looks again immediately instead of sleeping out the poll interval —
so a queue of dialogs drains as fast as the apps can put them up.

The three channels can still be run one at a time, which is mostly useful with
`--dump` when a prompt is not recognised and you want the AX tree to paste into
an issue:

```bash
dangerously-allow app ChatGPT --dump            # one app's pruned AX tree
dangerously-allow gui --verbose --dry-run       # dialogs it passed over, and why
dangerously-allow notifications
```

### Terminal agents (secondary)

A CLI agent can usually just be told to allow everything, so this is for the
cases where it cannot be. The watcher reads the TUI menu out of a tmux pane and
drives it with arrow keys:

```bash
dangerously-allow run claude
dangerously-allow run --policy always codex
dangerously-allow watch my-session --dry-run    # attach to a running agent
```

## Native permission dialogs are a permanent grant

The system-dialog channel is the only one whose answer is written to disk by the
system. A TCC dialog's "Allow" is not a one-time yes — it is an entry in the TCC
database that survives a relaunch and a reboot — so it is classified
`.allowAlways` however mildly the button is worded.

This is also why a window is offered to the system-dialog detector *first*, and
its answer is final. "ChatGPT wants access to control Finder" is a window of
ChatGPT, an app whose cards we also answer, and it satisfies the card detector's
grant-and-refusal shape perfectly well — but that detector reads a plain "Allow"
as `.allowOnce`. Routed there, the cautious card policy would press a permanent
system grant believing it was a one-shot. `DesktopRouter` exists to make that
ordering explicit, and `DesktopRouterTests` pins it.

So the system-dialog channel **defaults to `--policy always`** and presses that
"Allow", while cards default to `session`. The reason is structural: a TCC
dialog almost never
offers a session- or once-scoped button, so a `session` default — which only
presses grants that die with the process — would leave the common dialogs
untouched, doing nothing on the very prompt you ran it for. What still holds is
that **a refusal or a neutral button is never pressed, under any policy** — the
target is drawn only from `AllowPolicy.preference`, which lists grant kinds
alone:

| Button | Kind | default (`always`) | `--policy session` |
| --- | --- | --- | --- |
| "Allow", "OK" | `allowAlways` | pressed | left for a human |
| "Allow While Using App" | `allowAlways` | pressed | left — a permanent entry with a usage condition, not a bounded grant |
| "Allow Once" (Location) | `allowOnce` | pressed (fallback) | pressed |
| "Open System Settings", "Learn More" | `neutral` | never | never |
| "Don't Allow", "Cancel" | `deny` | never | never |

So `--policy session` is the cautious knob: it leaves permanent TCC grants for
a human and presses only an explicit "Allow Once". The other difference from
the `app` path: a system dialog need not offer a refusal. macOS 15's
screen-capture prompt offers "Allow" and "Open System Settings" and nothing
else — the way out is Esc — so the grant-and-refusal invariant cannot apply
here. What stands in for it is the shape (at most five buttons), a button that
grants something, and the policy ceiling above. Recognised wording is *not*
required by default: a keyword list only knows the prompts someone has already
transcribed, and every sentence it has not met — Chrome's remote-debugging
dialog, the next OS release's rephrasing — was being walked past in silence.
`--require-trigger` puts the wording gate back.

If a dialog is not recognised, `--verbose` prints every dialog-shaped window it
passed over, the reason, and each button's classified kind; `--dump` prints
every window carrying text, once, then exits. Paste that into an issue —
wording is the thing that goes stale. macOS 15's screen-capture prompt says
neither "would like to access" nor "Screen Recording", which is exactly how it
slipped past an earlier keyword list.

## Approval cards, and notification banners

The ChatGPT desktop app (`com.openai.codex`) and the Claude desktop app
(`com.anthropic.claudefordesktop`) ask for approval with a card — "Allow once",
"Always allow", "Deny" — not a TUI menu, so the tmux channel cannot see it. But
unlike a terminal drawing, the card is real UI, and it is fully visible to the
Accessibility API. Both are answered by default; `--app` adds others. To watch
just one:

```bash
dangerously-allow app ChatGPT                     # session policy: presses "Allow once"
dangerously-allow app ChatGPT --policy always     # presses "Always allow"
dangerously-allow app ChatGPT --dry-run --verbose # log the card, press nothing
```

An approval card is recognised the same way a TUI menu is: a *small* subtree
holding at least one option that grants and at least one that refuses. A lone
"Allow" button, a toolbar, or a sidebar never qualifies, and the card must
carry request-like wording ("Review command", "File access", "Network
access"…) only if you pass `--require-trigger`. The card's labels were taken
from the app bundle's own string table (`approvalRequestCard.*` in app.asar),
not guessed. `--never-approve` vetoes on the card's text — including the
command it shows.

Notification banners are the same idea with a twist: Notification Center
exposes a banner's buttons as AX *actions on the banner element*, not as child
buttons. `notifications` watches for banners that offer an Allow-style action
and presses it:

```bash
dangerously-allow notifications --dry-run     # see what it would press
dangerously-allow notifications
```

A banner with no grant action — your average "meeting in 5 minutes" — offers
nothing to press and is never touched. Both need the terminal to have
Accessibility permission (System Settings → Privacy & Security →
Accessibility); neither needs sudo. If a card's wording is not recognised, run
with `--dump` to print the pruned AX tree and paste it into an issue.

## Sweeping without stalling

A system dialog can be posted by any process, so every pass walks every window
of every running app — around 115 apps on an ordinary desktop. Accessibility
calls are synchronous IPC into the target app, and that is the trap: one app
that has stopped answering costs the full messaging timeout *per attribute
read*, and a walk that should take milliseconds takes minutes. An early build of
this mode never completed a single sweep; Finder alone was unbounded.

Three things keep it honest, and the third is the one that matters:

- the messaging timeout is capped globally, so no single read can hang;
- windows outside the card apps get a small node budget, because a permission
  dialog is a title, a sentence and a few buttons — anything larger is an
  ordinary window and walking the rest of it buys nothing;
- **every walk carries a wall-clock deadline.** A node budget bounds a *big*
  tree but not a *slow* one; time is the only unit that bounds both. A window
  that outruns its deadline is abandoned for this pass.

A sweep now costs a few seconds — mostly Finder — at no measurable CPU, since
it is blocked on IPC rather than computing. Run `--verbose` to see the per-pass
timing and which apps are slow.

## Policies

`--policy` decides which grant is acceptable. **A policy never escalates**: it
falls back only to *less* persistent grants, never more. `--policy session` will
not click "Allow for all future sessions" merely because no session option
existed.

| Policy | Clicks | Falls back to |
| --- | --- | --- |
| `once` | "Yes", "Allow once" | — |
| `session` *(default)* | "Allow for this session" | a one-time allow |
| `always` | "Allow for all future sessions", "don't ask again", "Trust folder" | session, then once |

Folder trust ("Do you trust the files in this folder?") is classified as a
**permanent** grant even though its label says neither "always" nor "session" —
accepting it lets that directory's config execute code in every future session.
So the default policy deliberately leaves it for a human.

## Why arrow keys and not the option number

Typing the digit looks simpler, and it is wrong. Gemini CLI's `useSelectionList`
fires `SELECT_CURRENT` the instant a digit cannot prefix a longer valid number —
so for a 5-item menu, pressing `2` *already confirms*. A follow-up `Enter` would
then leak into whatever the agent displayed next, potentially confirming a second
prompt nobody looked at.

So the watcher never types digits. It reads the cursor glyph, sends **one** arrow
key, re-captures, and re-reads the cursor — closing the loop on every step. That
also survives menus that skip disabled rows or wrap around the ends, which a
blind "press Down N times" would silently desynchronise from.

## Not firing on the wrong thing

An agent printing a numbered list is not a permission prompt. Before touching a
menu, the watcher requires all of:

1. a contiguous block `1. … N.` (wrapped labels are rejoined),
2. at least one option that grants access **and** at least one that refuses —
   every real permission prompt offers a way out,
3. a question line above the block (`--no-require-trigger` to relax),
4. a visible cursor glyph. If it cannot see which row is highlighted it refuses
   to guess, logs the menu, and leaves the prompt alone.

`--never-approve <regex>` (repeatable) is a hard veto: if the pane matches, the
prompt is left for a human no matter what the policy says.

```bash
dangerously-allow watch agent --never-approve 'rm -rf' --never-approve 'push --force'
```

## When the rules don't recognise a menu

Agents reword their prompts between versions, and a menu the rule classifier has
never seen would otherwise be left untouched. `--llm-fallback` (opt-in; needs
`ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`) sends *only* those unrecognised
menus to a model — `claude-haiku-4-5` by default — and asks it to **label** each
row. It never chooses one.

The model reports whether the screen is a permission request and what each row
grants. Those labels are reconciled with the rule engine's own,
**most-reluctant-wins**, and the policy then selects the target exactly as on the
rule path. So a model can never pick a refusal, and can never call a permanent
grant "session-scoped" to slip it past the policy — a disagreement can only make
the watcher *refuse*, never grant more. `--never-approve` is checked before the
pane is sent anywhere, and anything uncertain — the model unsure, the model and
rules disagreeing, no refusal row present, the API unreachable — is left for a
human (with a macOS notification under `--notify`).

```bash
dangerously-allow watch my-session --llm-fallback
dangerously-allow run --llm-fallback --dry-run claude    # log the plan, press nothing
```

## What it will not do

Worth checking for yourself before you trust a tool that clicks "Allow" — every
claim here is one grep away in `Sources/DangerouslyAllowCore/`:

- It never selects a refusal or a neutral option. The target is drawn only from
  `AllowPolicy.preference`, which contains grant kinds and nothing else — on
  the tmux path and the AX path alike.
- It never types an option's digit, so it cannot confirm a menu by accident.
- If it cannot see which row is highlighted, it refuses to act and says so.
- Under the default `session` policy it grants nothing that outlives the agent
  process — no "don't ask again", no "all future sessions", no folder trust.
  In the ChatGPT app, `session` presses "Allow once", because the card offers
  no session-scoped button.
- In `run`/`watch` it reads and writes exactly one tmux pane: the one you name.
- In `app` it reads the AX tree of the one app you name, and presses at most
  one option on a card that offers both a grant and a refusal.
- No telemetry and no config file. It makes **no network call unless you pass
  `--llm-fallback`** — which sends unrecognised menus to the Anthropic API, and
  nothing else. The only file it writes is the watcher log: `--log <file>`, or a
  temp file whose path `run` prints on startup.

The `gui` mode is the exception to the last two points: it scans the
Accessibility tree of every running app to find TCC dialogs, since the system
picks which process presents one. It presses at most one button per dialog —
never a refusal, never a neutral like "Open System Settings" — and defaults to
`--policy always` because a TCC grant is permanent by nature; pass
`--policy session` to leave those permanent grants for a human.

## A safer alternative first

If you want to auto-approve *everything*, the agent's own flag is safer than
screen-scraping, because it cannot mis-click:

- Claude Code — `--dangerously-skip-permissions`
- Gemini CLI — `--approval-mode=yolo`
- Codex — `--full-auto`

This tool exists for the cases those flags do not cover: approving *selectively*,
attaching to an agent that is **already running**, and working uniformly across
harnesses that expose no such flag.

## Layout

```
Sources/DangerouslyAllowCore/    pure logic, no I/O — where the tests live
  OptionKind.swift               grant kinds; policy preference chains
  OptionClassifier.swift         label -> grant kind
  ScreenParser.swift             ANSI, box borders, wrapped labels, cursor glyph
  PromptDetector.swift           menu detection, target choice, navigation step
  MenuScan.swift                 screen -> rows + rule kinds + navigation state
  Adjudicator.swift              LLM-fallback types; reconcile / validate / merge
  AdjudicatorAPI.swift           Messages API request + response (no network)
  AdjudicatedDetector.swift      scan -> judge -> reconcile -> policy -> outcome
  JSONValue.swift                typed JSON tree for building the request body
  ButtonPrompt.swift             approval cards in a UI element tree
  SystemDialog.swift             native macOS permission dialogs
  DesktopRouter.swift            which detector owns a window; the watched apps
Sources/DangerouslyAllow/
  AXTree.swift                   the only file that touches AXUIElement
  DesktopWatcher.swift           the default mode: all three channels, one loop
  AppWatcher.swift               `app` / `notifications`: one app's cards
  AXScanner.swift                `gui`: every app's AX tree -> SystemDialog
  TmuxChannel.swift              capture-pane / send-keys
  Watcher.swift                  closed-loop poll -> navigate -> confirm
  Runner.swift                   `run`: start the agent in tmux, spawn the watcher
  NetworkAdjudicator.swift       the LLM fallback's one network call (URLSession)
  Notify.swift                   `--notify` macOS notifications
tools/mock-prompt.js             a fake agent menu that renders like the real ones
tools/integration-test.sh        drives it through real tmux
```

Labels and rendering were taken from the shipped harnesses, not guessed —
Gemini CLI's `ToolConfirmationMessage.js` / `BaseSelectionList.js`, and the
string table of the Claude Code binary. `RealCaptureTests.swift` pins verbatim
`capture-pane` output as a fixture.

## Contributing

Prompt wording changes as agents ship new versions. If `dangerously-allow`
mis-reads a menu, run `dangerously-allow watch <session> --verbose --dry-run`,
and paste the parsed menu into an issue along with the raw
`tmux capture-pane -p -t <session>` output. New harnesses are usually just a few
labels in `OptionClassifier` plus a fixture in `RealCaptureTests`.

`make check` must stay green: 120 unit tests, and 12 end-to-end tests that drive a
mock TUI through a real tmux pane.

## License

MIT — see [LICENSE](LICENSE).
