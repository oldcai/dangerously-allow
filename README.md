# dangerously-allow

Auto-approves permission prompts from coding agents on macOS.

> **Read this before running it.** This tool presses "Allow" on prompts that
> exist to protect you. It grants an agent permission to run commands you did
> not individually approve. Use it on work you can afford to lose, in a
> directory under version control, and start with `--dry-run`.

There are several completely different kinds of prompt, and they need different
mechanisms:

| Prompt | Example | Mechanism |
| --- | --- | --- |
| Native macOS TCC dialog | "Terminal would like to access the Microphone" | Accessibility API (`gui`) |
| In-terminal TUI menu | `1. Allow for this session (0 apps)` | tmux `capture-pane` + `send-keys` (`run` / `watch`) |
| In-app approval card | ChatGPT desktop's "Allow once / Always allow / Deny" | Accessibility tree (`app`) |
| Notification banner action | an "Allow" button on a macOS notification | Accessibility actions (`notifications`) |

The second is what agents like Claude Code, Gemini CLI, and Codex actually show.
It is drawn *inside* the terminal — it is text, not an AppKit window, so the
Accessibility API cannot see it. That is why an AX-only approach never manages
to recognise and click these prompts.

## The channel

A TUI menu can only be read and driven through the terminal itself. tmux gives
both halves of that channel — the same trick `lazytyper` uses to deliver voice
transcriptions into a running CLI:

- **read** — `tmux capture-pane -p -t <target>` returns the visible pane as plain
  text. Highlight glyphs (`❯`, `●`) and box borders survive intact.
- **write** — `tmux send-keys -t <target> Down Enter` types into the pane.

## Install

```bash
make install              # builds release, installs into /usr/local/bin
make install PREFIX=~/.local
make uninstall
```

`/usr/local/bin` may need `sudo make install`. Requires tmux (`brew install tmux`).

```bash
make check                # 72 unit tests + 12 end-to-end tests through real tmux
make help                 # list targets
```

## Use

Launch an agent with the watcher riding along:

```bash
dangerously-allow run claude
dangerously-allow run --policy always codex
dangerously-allow run --never-approve 'rm -rf' gemini
dangerously-allow run --dry-run claude          # watch and log, press nothing
```

Or attach to a tmux session you already have an agent running in:

```bash
dangerously-allow watch my-session --verbose
dangerously-allow watch my-session --dry-run    # see what it would press
```

Native macOS dialogs are a separate mode, and still need root for AX access:

```bash
sudo dangerously-allow gui
```

## The ChatGPT desktop app, and notification banners

The ChatGPT desktop app (bundle id `com.openai.codex`) asks for approval with a
card — "Allow once", "Always allow", "Deny" — not a TUI menu, so the tmux
channel cannot see it. But unlike a terminal drawing, the card is real UI, and
it is fully visible to the Accessibility API:

```bash
dangerously-allow app ChatGPT                     # session policy: presses "Allow once"
dangerously-allow app ChatGPT --policy always     # presses "Always allow"
dangerously-allow app ChatGPT --dry-run --verbose # log the card, press nothing
```

An approval card is recognised the same way a TUI menu is: a *small* subtree
holding at least one option that grants and at least one that refuses. A lone
"Allow" button, a toolbar, or a sidebar never qualifies, and the card must
carry request-like wording ("Review command", "File access", "Network
access"…) unless you pass `--no-require-trigger`. The card's labels were taken
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
nothing to press and is never touched. Both modes need the terminal to have
Accessibility permission (System Settings → Privacy & Security →
Accessibility); neither needs sudo. If a card's wording is not recognised, run
with `--dump` to print the pruned AX tree and paste it into an issue.

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

The `gui` mode is the exception to the last two points: it needs `sudo`, and it
scans the Accessibility tree of every running app to find TCC dialogs.

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
  ButtonPrompt.swift             approval cards in a UI element tree (`app`)
Sources/DangerouslyAllow/
  TmuxChannel.swift              capture-pane / send-keys
  Watcher.swift                  closed-loop poll -> navigate -> confirm
  Runner.swift                   `run`: start the agent in tmux, spawn the watcher
  NetworkAdjudicator.swift       the LLM fallback's one network call (URLSession)
  AppWatcher.swift               AX tree -> UINode; presses the card's option
  AXScanner.swift                native macOS TCC dialogs
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

`make check` must stay green: 72 unit tests, and 12 end-to-end tests that drive a
mock TUI through a real tmux pane.

## License

MIT — see [LICENSE](LICENSE).

