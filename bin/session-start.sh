#!/usr/bin/env bash
#
# Claude Code SessionStart hook. bin/install-hooks.sh puts it in
# ~/.claude/settings.json, so it runs at the start of every session, in every
# project. It reads the hook's JSON on stdin and prints, only when something
# is wrong, text that Claude Code adds to the session's context.
#
# Why: a session started in Joe's checkout reads that folder's CLAUDE.md, and
# Claude never updates that folder (PROCESS.md, git rules), so the file drifts
# from main. On 2026-09-28 the checkout was 13 commits behind and a session
# was handed a process that had been replaced the day before. When the
# checkout is behind origin/main and its CLAUDE.md differs, this prints the
# current CLAUDE.md from origin/main; it also says when the toolkit checkout
# itself is behind. Up to date, it prints nothing.
#
# A hook must never break a session start: no `set -e`, a watchdog on the
# fetch, and every path exits 0.
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("cwd", ""))
except Exception:
    print("")' 2>/dev/null)
[ -n "$CWD" ] || CWD=$PWD

# fetch_main <root>: refreshes origin/main, giving up after 15 s. Offline, the
# stale remote-tracking ref is used, which still says "behind" if it was.
fetch_main() {
  ( git -C "$1" --no-optional-locks fetch origin main --quiet >/dev/null 2>&1 ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 15 ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
  wait "$pid" 2>/dev/null || true
}

# behind_count <root>: commits on origin/main that HEAD lacks, or empty.
behind_count() {
  git -C "$1" --no-optional-locks rev-list --count HEAD..origin/main 2>/dev/null
}

# check_checkout <dir>: the session's folder.
check_checkout() {
  local root behind
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
  fetch_main "$root"
  behind=$(behind_count "$root"); [ -n "$behind" ] || return 0
  [ "$behind" -gt 0 ] || return 0
  echo "STALE CHECKOUT: $root is $behind commit(s) behind origin/main ($(git -C "$root" --no-optional-locks rev-parse --short origin/main 2>/dev/null)). Do all branch work in a worktree cut from origin/main after a fetch; never switch, pull, merge or commit in this folder."
  if git -C "$root" --no-optional-locks diff --quiet HEAD origin/main -- CLAUDE.md 2>/dev/null; then
    echo "Its CLAUDE.md matches origin/main, so the rules you were given are current."
  else
    echo "Its CLAUDE.md is out of date. The current one, from origin/main, follows. Follow it, and read \$HOME/.claude/toolkit/PROCESS.md, which it imports, before any git work."
    echo "----- CLAUDE.md @ origin/main -----"
    git -C "$root" --no-optional-locks show origin/main:CLAUDE.md 2>/dev/null || echo "(origin/main has no CLAUDE.md)"
    echo "----- end of CLAUDE.md @ origin/main -----"
  fi
}

# check_toolkit: only the canonical checkout, which every app's scripts and
# CLAUDE.md import from. A worktree or CI checkout of the toolkit is skipped,
# so the self-test never needs the network.
check_toolkit() {
  local k behind
  k="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [ "$k" = "$HOME/.claude/toolkit" ] || return 0
  git -C "$k" remote get-url origin >/dev/null 2>&1 || return 0
  fetch_main "$k"
  behind=$(behind_count "$k"); [ -n "$behind" ] || return 0
  [ "$behind" -gt 0 ] || return 0
  echo "TOOLKIT BEHIND: $k is $behind commit(s) behind origin/main, so PROCESS.md, the scripts and the agents may be out of date. Bring it up to date with a fast-forward, which changes nothing else: git -C $k pull --ff-only"
}

# clean_test_clones: deletes simulator copies that xcodebuild's parallel
# testing left in ~/Library/Developer/XCTestDevices (one per run, until
# bin/test.sh turned parallel testing off for local runs), shut down and more
# than two hours old, so a copy another session's run has just made is never
# touched. The simulator service erases them in the background. Silent, and
# given 20 s at most.
clean_test_clones() {
  command -v xcrun >/dev/null 2>&1 || return 0
  local devices="$HOME/Library/Developer/XCTestDevices"
  [ -d "$devices" ] || return 0
  (
    xcrun simctl --set testing list devices -j 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for runtime, devs in data.get("devices", {}).items():
    for d in devs:
        if d.get("state") == "Shutdown" and d.get("name", "").startswith("Clone "):
            print(d["udid"])' 2>/dev/null | while read -r udid; do
      [ -n "$(find "$devices/$udid" -maxdepth 0 -mmin +120 2>/dev/null)" ] || continue
      xcrun simctl --set testing delete "$udid" >/dev/null 2>&1
    done
  ) >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 20 ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
  wait "$pid" 2>/dev/null || true
}

check_checkout "$CWD"
check_toolkit
clean_test_clones
exit 0
