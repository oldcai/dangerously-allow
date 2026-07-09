#!/usr/bin/env bash
# End-to-end test of the tmux channel: render a real menu in a real pane, let
# the watcher read it with capture-pane and drive it with send-keys, then assert
# which option was actually confirmed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/debug/dangerously-allow"
MOCK="$ROOT/tools/mock-prompt.js"
NODE="$(command -v node)"

[[ -x "$BIN" ]] || { echo "build first: swift build"; exit 1; }
[[ -n "$NODE" ]] || { echo "node is required for the mock TUI"; exit 1; }
command -v tmux >/dev/null || { echo "tmux is required"; exit 1; }

pass=0; fail=0
sessions=()

cleanup() {
    for s in "${sessions[@]:-}"; do tmux kill-session -t "$s" 2>/dev/null; done
}
trap cleanup EXIT

# start_mock <session> <style> <start-index> <outfile>
start_mock() {
    tmux new-session -d -s "$1" -x 100 -y 30 "$NODE $MOCK --style $2 --start $3 --out $4"
    sessions+=("$1")
    sleep 0.4
}

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $name"
        pass=$((pass + 1))
    else
        echo "  ✗ $name"
        echo "      expected: '$expected'"
        echo "      actual:   '$actual'"
        fail=$((fail + 1))
    fi
}

# ---- confirms the option the policy selects, navigating down --------------
confirm_case() {
    local name="$1" style="$2" start="$3" policy="$4" expected="$5"
    local session="dap-it-$$-$RANDOM" out
    out="$(mktemp)"
    start_mock "$session" "$style" "$start" "$out"
    "$BIN" watch "$session" --policy "$policy" --once >/dev/null 2>&1
    check "$name" "$expected" "$(cat "$out" 2>/dev/null)"
    rm -f "$out"
}

echo "tmux channel integration tests"

confirm_case "gemini/session navigates Down onto 'Allow for this session'" \
    gemini 1 session "Allow for this session"

confirm_case "gemini/session navigates Up when cursor starts below target" \
    gemini 3 session "Allow for this session"

confirm_case "gemini/once confirms immediately without moving" \
    gemini 1 once "Allow once"

confirm_case "gemini/always walks two rows down" \
    gemini 1 always "Allow for all future sessions"

confirm_case "gemini/session reaches target from the last row" \
    gemini 5 session "Allow for this session"

confirm_case "claude/session falls back to one-time 'Yes'" \
    claude 1 session "Yes"

confirm_case "claude/always picks the 'don't ask again' row" \
    claude 1 always "Yes, and don't ask again for npm commands in /Users/oldcai"

# ---- --never-approve must leave the prompt untouched ----------------------
neverapprove_case() {
    local session="dap-it-$$-$RANDOM" out
    out="$(mktemp)"
    start_mock "$session" gemini 1 "$out"
    "$BIN" watch "$session" --policy session --never-approve 'rm -rf' >/dev/null 2>&1 &
    local pid=$!
    sleep 2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    check "--never-approve refuses to confirm 'rm -rf'" "" "$(cat "$out" 2>/dev/null)"
    rm -f "$out"
}
neverapprove_case

# ---- `run` launches the agent in tmux and drives it -----------------------
run_subcommand_case() {
    local session="dap-it-$$-$RANDOM" out log
    out="$(mktemp)"; log="$(mktemp)"
    sessions+=("$session")
    "$BIN" run --no-attach --name "$session" --policy session --log "$log" \
        -- "$NODE" "$MOCK" --style gemini --start 1 --out "$out" >/dev/null 2>&1
    check "run --no-attach drives the agent it launched" \
        "Allow for this session" "$(cat "$out" 2>/dev/null)"
    rm -f "$out" "$log"
}
run_subcommand_case

# ---- `run` refuses a command-less invocation ------------------------------
run_requires_command_case() {
    if "$BIN" run --policy session >/dev/null 2>&1; then
        echo "  ✗ run without a command must fail"
        fail=$((fail + 1))
    else
        echo "  ✓ run without a command exits non-zero"
        pass=$((pass + 1))
    fi
}
run_requires_command_case

# ---- --dry-run must send no keys ------------------------------------------
dryrun_case() {
    local session="dap-it-$$-$RANDOM" out log
    out="$(mktemp)"; log="$(mktemp)"
    start_mock "$session" gemini 1 "$out"
    "$BIN" watch "$session" --policy session --dry-run >"$log" 2>&1 &
    local pid=$!
    sleep 2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    check "--dry-run confirms nothing" "" "$(cat "$out" 2>/dev/null)"
    if grep -q "would send" "$log"; then
        echo "  ✓ --dry-run logs the planned keys"
        pass=$((pass + 1))
    else
        echo "  ✗ --dry-run logs the planned keys"
        sed 's/^/      /' "$log"
        fail=$((fail + 1))
    fi
    rm -f "$out" "$log"
}
dryrun_case

echo
echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
