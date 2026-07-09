# dangerously-allow

Auto-approves permission prompts from coding agents on macOS.

There are two completely different kinds of prompt, and they need two different
mechanisms:

| Prompt | Example | Mechanism |
| --- | --- | --- |
| Native macOS TCC dialog | "Terminal would like to access the Microphone" | Accessibility API (`gui`) |
| In-terminal TUI menu | `1. Allow for this session (0 apps)` | tmux `capture-pane` + `send-keys` (`run` / `watch`) |

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
make check                # 35 unit tests + 12 end-to-end tests through real tmux
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
Sources/DangerouslyAllow/
  TmuxChannel.swift              capture-pane / send-keys
  Watcher.swift                  closed-loop poll -> navigate -> confirm
  Runner.swift                   `run`: start the agent in tmux, spawn the watcher
  AXScanner.swift                native macOS TCC dialogs
tools/mock-prompt.js             a fake agent menu that renders like the real ones
tools/integration-test.sh        drives it through real tmux
```

Labels and rendering were taken from the shipped harnesses, not guessed —
Gemini CLI's `ToolConfirmationMessage.js` / `BaseSelectionList.js`, and the
string table of the Claude Code binary. `RealCaptureTests.swift` pins verbatim
`capture-pane` output as a fixture.
