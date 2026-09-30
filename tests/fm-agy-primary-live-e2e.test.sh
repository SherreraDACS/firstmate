#!/usr/bin/env bash
# Opt-in live guard for Antigravity CLI (agy) as a firstmate PRIMARY.
#
# Verifies positive runtime effects of native .agents/hooks.json hooks while AGY is running:
#   1. SessionStart hook executes bin/fm-sessionstart-agy.sh and injects the fleet
#      startup digest (carrying a unique live marker token) directly into model context
#      without the model executing any tool calls.
#   2. PreToolUse hook executes bin/fm-pretool-check-agy.sh, intercepts prohibited
#      actions (e.g. persistent cd into projects/), and denies execution with policy reason.
#   3. Tool execution verifies state/.lock is held by the live agy process in ancestry.
#   4. Post-process termination cleanly transitions lock to stale.
#
# Isolation: an isolated throwaway lab directory, a throwaway AGY HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_PRIMARY_LIVE_E2E agy jq node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=${FM_AGY_BIN:-$(command -v agy || true)}
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "agy not found; install it or set FM_AGY_BIN."
AGY_VERSION=$("$AGY_BIN" --version 2>/dev/null | head -1)
[ -n "$AGY_VERSION" ] || fail "agy did not report a version"
printf 'harness: agy %s\n' "$AGY_VERSION"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-primary-live.XXXXXX")
HOME_DIR="$LAB/home"
AGY_HOME="$LAB/agyhome"

cleanup_all() {
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$HOME_DIR"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || fail "could not stage repository tree into throwaway home"

git init -q "$HOME_DIR"
git -C "$HOME_DIR" config user.email "live-guard@local"
git -C "$HOME_DIR" config user.name "live-guard"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" commit -q --allow-empty -m "live-e2e fixture" >/dev/null 2>&1 || true

[ -f "$HOME_DIR/.agents/hooks.json" ] \
  || fail "staged home is missing .agents/hooks.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
MARKER="AGY_LIVE_MARKER_$$"
printf '# Captain\n\nLive marker: %s\n' "$MARKER" > "$HOME_DIR/data/captain.md"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"

mkdir -p "$AGY_HOME"
if [ -d "$HOME/.gemini" ]; then
  cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not copy ~/.gemini to throwaway HOME"
fi

SETTINGS_FILE="$AGY_HOME/.gemini/antigravity-cli/settings.json"
mkdir -p "$(dirname "$SETTINGS_FILE")"
node -e '
  const fs = require("node:fs");
  const p = process.argv[1];
  const dir = process.argv[2];
  let data = {};
  try {
    if (fs.existsSync(p)) data = JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {}
  data.trustedWorkspaces = Array.from(new Set([...(data.trustedWorkspaces || []), dir]));
  fs.writeFileSync(p, JSON.stringify(data, null, 2));
' "$SETTINGS_FILE" "$HOME_DIR" || fail "could not register workspace trust"

# --- 1. Positive SessionStart effect: context injection before first turn ---
# The agent is asked to quote the live marker without running any command.
# If SessionStart did not run or injectSteps failed, the agent has no context of $MARKER.
out_context=$(cd "$HOME_DIR" && HOME="$AGY_HOME" FM_HOME="$HOME_DIR" \
  "$AGY_BIN" -p "Answer only from the context you were given at session start. Do not run any command. Reply with the exact live marker token you can see, and nothing else." \
  --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions 2>&1) || true

assert_contains "$out_context" "$MARKER" \
  "SessionStart injectSteps failed: model did not receive live marker in context"
pass "agy primary: SessionStart injectSteps successfully injected startup context into model"

# --- 2. Positive PreToolUse effect: synchronous tool interception and policy denial ---
# We ask the agent to call invoke_subagent.
# PreToolUse hook must intercept the tool call and deny it with policy reason.
out_pretool=$(cd "$HOME_DIR" && HOME="$AGY_HOME" FM_HOME="$HOME_DIR" \
  "$AGY_BIN" -p "Call the invoke_subagent tool with TypeName: self, Role: tester, Prompt: test" \
  --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions 2>&1) || true

assert_contains "$out_pretool" "subagent-dispatch" \
  "PreToolUse hook failed to deny delegation tool execution"
pass "agy primary: PreToolUse hook actively intercepted and denied prohibited delegation call"

# --- 3. Positive SessionStart effect: live session lock held during execution ---
# Tool execution inside the session checks bin/fm-lock.sh status, proving state/.lock
# was acquired by SessionStart and is actively held by the live agy harness process.
out_lock=$(cd "$HOME_DIR" && HOME="$AGY_HOME" FM_HOME="$HOME_DIR" \
  "$AGY_BIN" -p "Run the shell command: bin/fm-lock.sh status" \
  --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions 2>&1) || true

assert_contains "$out_lock" "lock: held by live harness pid" \
  "SessionStart lock acquisition failed: live session lock not held during execution"
pass "agy primary: SessionStart successfully acquired session lock held during execution"

# --- 4. Clean process termination and lock transition ---
(
  export FM_ROOT_OVERRIDE="$HOME_DIR"
  export FM_STATE_OVERRIDE="$HOME_DIR/state"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$HOME_DIR/bin/fm-session-lock-lib.sh"
  fm_session_lock_inspect "$HOME_DIR/state"
  case "$FM_LOCK_INSPECT_STATE" in
    stale|free) ;; # After agy exits, the lock must either be stale or freed
    *) fail "unexpected lock inspect state after agy exit: $FM_LOCK_INSPECT_STATE" ;;
  esac
) || fail "session lock state failed inspection after process exit"
pass "agy primary: session lock transitions cleanly upon process exit"

cleanup_all
trap - EXIT

echo "# all fm-agy-primary-live-e2e tests passed"
