#!/usr/bin/env bash
#
# Checks an app's GitHub repo against the standard every app uses: public,
# squash-only, auto-merge on, branches deleted after merge, secret scanning
# and push protection on, and a "Protect main" ruleset requiring exactly the
# checks in .claude/app.json. The standard and why each part exists are in
# lib/repo_settings.py.
#
# Usage: repo-check.sh <repo root> [--apply]
#   Without --apply it only reports, and exits 1 on any difference.
#   --apply fixes what it can. It never makes a repo public; that is Joe's call.
set -euo pipefail
TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${1:?usage: repo-check.sh <repo root> [--apply]}"
shift
exec python3 "$TOOLKIT/lib/repo_settings.py" "$ROOT" "$@"
