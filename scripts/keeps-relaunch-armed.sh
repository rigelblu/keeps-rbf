#!/bin/bash
# Relaunch keeps as the packaged, signed keeps.app (#keeps-18) with the trace armed.
#
# RUN THIS FROM YOUR OWN TERMINAL (Warp) — never from an agent shell, BECAUSE this script execs the
# inner binary. That rule is about the exec path, not about agent shells in general: an agent can
# relaunch keeps safely with `open -n /Applications/keeps.app --env KEEPS_DEBUG=1`, since a
# LaunchServices launch uses keeps' own TCC identity (2026-07-27, 2026-08-26). Scenario 5 (2026-07-07)
# settled the question that used to sit open here, and it settled it the *other* way: launcher
# attribution HOLDS for bundles on the exec path, so keeps launched below inherits the launching
# app's Accessibility trust, not its own. An agent shell carries no AX grant, so keeps comes up
# unable to read or move a single window — and the `--capture-once` at the bottom would then
# overwrite your baseline snapshot using that crippled instance. Only `open`/Finder launches use
# keeps' own TCC identity (that grant survives rebuilds — the signing identity is stable).
#
# Env is read once at launch — memory: keeps-trace-arm-env-on-launched-instance.
# Launch method: inner-binary exec (launch-story decision). Scenario 2b passed on BOTH launch
# paths, so the `open` + `launchctl setenv KEEPS_*` fallback was never needed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"   # self-locating, same as scripts/package-app.sh
APP="$REPO/.build/keeps.app"
BIN="$APP/Contents/MacOS/keeps"
LOG="$HOME/Library/Logs/keeps-debug.log"   # local path: survives reboots (unlike /tmp)

bash "$REPO/scripts/package-app.sh"        # build + assemble + sign (rebuild-stable identity)

pkill -f '\.build/(debug|release)/keeps' 2>/dev/null || true     # old unbundled launch path
pkill -f 'keeps.app/Contents/MacOS/keeps' 2>/dev/null || true    # packaged launch path
# Poll for actual death, not a blind sleep — the new instance must not race the outgoing one.
for _ in $(seq 1 20); do
  pgrep -f '\.build/(debug|release)/keeps|keeps\.app/Contents/MacOS/keeps' >/dev/null 2>&1 || break
  sleep 0.25
done
nohup env KEEPS_DEBUG="$LOG" "$BIN" >/dev/null 2>&1 &
disown
sleep 2

PID="$(pgrep -f 'keeps.app/Contents/MacOS/keeps' | head -1 || true)"  # `|| true`: pipefail would abort here on no-match, killing the very diagnostic below
[ -n "$PID" ] || { echo "keeps NOT running — launch failed"; exit 1; }
echo "keeps pid=$PID — verifying armed env on the LIVE instance:"
ps eww -p "$PID" -o command | tr ' ' '\n' | grep '^KEEPS_'
tail -1 "$LOG"

# Fresh baseline capture of the current config so future restores work with live windows
# (the stale Jun-17 snapshots are preserved in rb-drive/agents/v0.x/agents-dogfood/store-backup-2026-07-06/).
"$BIN" --capture-once
