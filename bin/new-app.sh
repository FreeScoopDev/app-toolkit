#!/usr/bin/env bash
#
# Turns a fresh Xcode project into a FreeScoopDev app repo: standard files,
# first commit, public GitHub repo, repo standard applied. The steps around it
# (what Joe does in Xcode, App Store Connect and Xcode Cloud) are NEW-APP.md.
#
# Usage: new-app.sh <repo root> <owner/name> [--local-only]
#   --local-only adds the files and commits, and touches nothing on GitHub.
set -euo pipefail
TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$TOOLKIT/lib/new_app.py" "$@"
