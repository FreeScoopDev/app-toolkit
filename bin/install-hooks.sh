#!/usr/bin/env bash
#
# Registers the toolkit's SessionStart hook (bin/session-start.sh) in
# ~/.claude/settings.json, so every Claude Code session, in every project,
# is told when the checkout it started in is behind origin/main and given
# the current CLAUDE.md. Run it once after cloning the toolkit; running it
# again is a no-op. Nothing else in the settings file is touched.
#
# The hook command points at the canonical checkout, $HOME/.claude/toolkit,
# not at whatever checkout this script runs from: a worktree of the toolkit
# is temporary, and the hook has to outlive it.
#
# Usage: install-hooks.sh
#   CLAUDE_SETTINGS_FILE overrides the settings file (the self-test uses a
#   temporary one); TOOLKIT_HOME overrides the canonical checkout.
set -euo pipefail
FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
TOOLKIT_HOME="${TOOLKIT_HOME:-$HOME/.claude/toolkit}"
CMD="$TOOLKIT_HOME/bin/session-start.sh"

python3 - "$FILE" "$CMD" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})
entries = hooks.setdefault("SessionStart", [])
for entry in entries:
    for hook in entry.get("hooks", []):
        if hook.get("command") == cmd:
            print(f"already installed in {path}: {cmd}")
            sys.exit(0)
entries.append({"hooks": [{"type": "command", "command": cmd, "timeout": 30}]})
tmp = path + ".tmp"
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(f"installed SessionStart hook in {path}: {cmd}")
PY
