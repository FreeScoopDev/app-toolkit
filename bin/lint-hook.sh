#!/usr/bin/env bash
#
# Claude Code PostToolUse hook. bin/install-hooks.sh registers it for Edit
# and Write, so it runs right after Claude changes a file. For a
# .swift file inside a repo with a .swiftlint.yml, it runs SwiftLint on that
# one file from the repo root, with the repo's own config, and hands any
# violations to Claude as context. Anything else: silent.
#
# Why: a lint error used to surface only when the PR's SwiftLint check went
# red, which cost a push and a wait. The CI check stays the judge (local and
# CI SwiftLint have disagreed before); this is an early warning.
#
# Report only: never --fix (autofix has broken builds; see bin/lint.sh).
# From the repo root with the in-place config, because SwiftLint resolves
# `excluded:` relative to the config file; --force-exclude, because a path
# named on the command line is otherwise linted even when it is excluded.
#
# A hook must never block or fail an edit: no `set -e`, every path exits 0,
# and violations go out as additionalContext, never as a block decision.
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
FILE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("file_path", ""))
except Exception:
    print("")' 2>/dev/null)

case "$FILE" in *.swift) ;; *) exit 0 ;; esac
[ -f "$FILE" ] || exit 0
ROOT=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$ROOT/.swiftlint.yml" ] || exit 0
command -v swiftlint >/dev/null 2>&1 || exit 0

# Relative to the root, so the output names the file the way CI does.
REL=$(python3 -c 'import os, sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$FILE" "$ROOT" 2>/dev/null) || exit 0
OUT=$(cd "$ROOT" && swiftlint lint --quiet --force-exclude -- "$REL" 2>/dev/null)
[ -n "$OUT" ] || exit 0

printf '%s' "$OUT" | python3 -c '
import json, sys
out = sys.stdin.read().strip()
n = len(out.splitlines())
msg = (f"SwiftLint (report only, repo config) found {n} violation(s) in {sys.argv[1]} after this edit. "
       "Lines marked error fail the required SwiftLint check on the PR; fix them by hand, never with --fix.\n" + out)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))' "$REL" 2>/dev/null
exit 0
