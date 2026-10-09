#!/usr/bin/env bash
#
# Registers the toolkit's hooks in ~/.claude/settings.json, for every Claude
# Code session in every project:
#   SessionStart  bin/session-start.sh  says when the checkout is behind
#                                       origin/main and gives the current CLAUDE.md
#   PostToolUse   bin/lint-hook.sh      after Claude edits a .swift file (Edit or
#                                       Write), shows its SwiftLint
#                                       violations
# Run it once after cloning the toolkit; running it again is a no-op. A hook
# already registered is left as it is; nothing else in the file is touched.
#
# The hook commands point at the canonical checkout, $HOME/.claude/toolkit,
# not at whatever checkout this script runs from: a worktree of the toolkit
# is temporary, and the hooks have to outlive it.
#
# Usage: install-hooks.sh
#   CLAUDE_SETTINGS_FILE overrides the settings file (the self-test uses a
#   temporary one); TOOLKIT_HOME overrides the canonical checkout.
set -euo pipefail
FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
TOOLKIT_HOME="${TOOLKIT_HOME:-$HOME/.claude/toolkit}"

python3 - "$FILE" "$TOOLKIT_HOME" <<'PY'
import json, os, sys
path, home = sys.argv[1], sys.argv[2]
WANT = [  # (event, matcher or None, script, timeout in seconds)
    ("SessionStart", None, "session-start.sh", 30),
    ("PostToolUse", "Edit|Write", "lint-hook.sh", 30),
]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})
changed = False
for event, matcher, script, timeout in WANT:
    cmd = f"{home}/bin/{script}"
    entries = hooks.setdefault(event, [])
    if any(h.get("command") == cmd for e in entries for h in e.get("hooks", [])):
        print(f"already installed in {path}: {event} {cmd}")
        continue
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
    if matcher:
        entry = {"matcher": matcher, **entry}
    entries.append(entry)
    changed = True
    print(f"installed {event} hook in {path}: {cmd}")
if changed:
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
PY
