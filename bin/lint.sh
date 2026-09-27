#!/usr/bin/env bash
#
# Shared SwiftLint runner for every app that has a .claude/app.json. Each
# repo's scripts/lint.sh is a thin wrapper that calls this with its own root.
#
# Why this exists:
#   SwiftLint resolves `excluded:` paths relative to THE CONFIG FILE'S OWN
#   DIRECTORY. `swiftlint --config /somewhere/else.yml` therefore matches
#   nothing and silently lints the test targets the config means to exclude,
#   with output that looks completely normal. This always runs from the repo
#   root with the in-place config, then proves the exclusions took effect.
#
# Two independent checks, so neither can pass vacuously:
#   1. app.json's lintExcluded must equal .swiftlint.yml's excluded list.
#      They are separate files; a change to one without the other aborts.
#   2. No violation may be reported inside an excluded path. This one reads
#      SwiftLint's actual output, not any config.
#
# Usage: lint.sh <repo root> [--fix]
#   --fix autocorrects, and MUST be followed by the repo's scripts/test.sh:
#   autofix has broken builds before (redundant_discardable_let inside a
#   @ViewBuilder, empty_count on XCUIElementQuery).
set -euo pipefail

TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${1:?usage: lint.sh <repo root> [--fix]}"
shift
cd "$ROOT"

# Captured first: a failing command inside `eval "$(...)"` does not trip set -e.
CONFIG="$(python3 "$TOOLKIT/lib/app_config.py" "$ROOT")" || exit 2
eval "$CONFIG"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not installed. brew install swiftlint" >&2
  exit 1
fi
if [[ ! -f .swiftlint.yml ]]; then
  echo "ABORT: no .swiftlint.yml at $ROOT" >&2
  exit 2
fi

if [[ "${1:-}" == "--fix" ]]; then
  echo "WARNING: swiftlint --fix has broken builds before. Run scripts/test.sh after."
  echo
  swiftlint --fix
  echo
  echo "Now run: scripts/test.sh"
  exit 0
elif [[ -n "${1:-}" ]]; then
  echo "unknown option: $1 (only --fix is supported)" >&2
  exit 2
fi

OUT="$(swiftlint lint --quiet 2>/dev/null || true)"

# 1. app.json and .swiftlint.yml must agree.
ACTUAL=$(awk '/^excluded:/{f=1;next} /^[^ -]/{f=0} f&&/^ *- /{gsub(/^ *- */,"");sub(/ *#.*/,"");print}' .swiftlint.yml | sort | tr '\n' ' ' | sed 's/ $//')
EXPECTED=$(printf '%s\n' "${APP_LINT_EXCLUDED[@]}" | sort | tr '\n' ' ' | sed 's/ $//')
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "ABORT: excluded paths differ." >&2
  echo "  .claude/app.json lintExcluded: $EXPECTED" >&2
  echo "  .swiftlint.yml excluded:       $ACTUAL" >&2
  echo "Change both together, deliberately." >&2
  exit 2
fi

# 2. The exclusions are in effect, judged from SwiftLint's own output.
for excluded in "${APP_LINT_EXCLUDED[@]}"; do
  if grep -q "/${excluded}/" <<<"$OUT"; then
    echo "ABORT: violations reported inside excluded path '${excluded}/'." >&2
    echo "The config was not applied from the repo root; counts are unreliable." >&2
    exit 2
  fi
done

TOTAL=$(grep -c . <<<"$OUT" || true)
SERIOUS=$(grep -c ": error:" <<<"$OUT" || true)

echo "$APP_NAME SwiftLint: $TOTAL violations, $SERIOUS at error severity"
echo "(exclusions verified in effect)"
if [[ "$SERIOUS" -gt 0 ]]; then
  echo
  echo "--- error severity, by rule ---"
  grep ": error:" <<<"$OUT" | grep -oE '\(([a-z_]+)\)$' | sort | uniq -c | sort -rn
fi
