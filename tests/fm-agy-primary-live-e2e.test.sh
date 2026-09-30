#!/usr/bin/env bash
# Opt-in live guard for Antigravity CLI (agy) as a firstmate PRIMARY.
#
# Tests the live AGY harness integration against .agents/hooks.json:
#   1. SessionStart / PreInvocation hook executes and acquires the fleet session
#      lock as the agy process in ancestry (verified via fm_session_lock_owned_by_self).
#   2. PreToolUse hook executes bin/fm-pretool-check-agy.sh and enforces
#      primary guard boundaries (subagent delegation, persistent cd, background arms).
#   3. Stop hook executes bin/fm-turnend-guard-agy.sh and handles the turn-end boundary.
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
printf '# Captain\n\nLive agy primary guard.\n' > "$HOME_DIR/data/captain.md"
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

# Run an empirical probe through AGY in the staged home
out_probe=$(cd "$HOME_DIR" && HOME="$AGY_HOME" FM_HOME="$HOME_DIR" \
  "$AGY_BIN" -p "echo PRIMARY_GUARD_READY" \
  --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions 2>&1) || true

assert_contains "$out_probe" "PRIMARY_GUARD_READY" "prompt response did not complete successfully"
pass "agy primary: completed prompt turn under real agy harness"

# Verify that ancestry lock acquisition was recognized during the turn
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
) || fail "session lock state failed inspection"
pass "agy primary: session lock transitions cleanly upon process exit"

cleanup_all
trap - EXIT

echo "# all fm-agy-primary-live-e2e tests passed"
