#!/usr/bin/env bash
#
# Shared test runner for every app that has a .claude/app.json. Each repo's
# scripts/test.sh is a thin wrapper that calls this with its own root.
#
# Why this exists (each point cost a real, wrong "green" once):
#   1. `xcodebuild test | tail` returns *tail's* exit code, so a failed run
#      reports success. Output goes to files here; nothing is piped.
#   2. The scheme may run unit AND UI test targets, and Xcode Cloud's Test
#      action uses "Use Scheme Setting". The default here is therefore the
#      full scheme, i.e. what CI runs. --unit-only is faster and says so.
#   3. The xcodebuild log is not a reliable counter: during parallel testing
#      session output can land mid-way through a result line and eat its
#      verdict. Counts come from the xcresult bundle (what Xcode Cloud reads).
#      The verdict needs xcodebuild's exit code AND its ** TEST SUCCEEDED **
#      line AND the bundle's result, all three.
#   4. `-only-testing:` with a Swift Testing function name can match nothing
#      and still print TEST SUCCEEDED. A run of 0 tests is reported as a
#      failure here for that reason.
#
# Usage: test.sh <repo root> [--unit-only]
#   TEST_OUTPUT_DIR=<dir>  keep the log and result bundle under <dir> (CI uploads them)
set -euo pipefail

TOOLKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${1:?usage: test.sh <repo root> [--unit-only]}"
shift
cd "$ROOT"

# Captured first: a failing command inside `eval "$(...)"` does not trip set -e.
CONFIG="$(python3 "$TOOLKIT/lib/app_config.py" "$ROOT")" || exit 2
eval "$CONFIG"

ONLY=()
LABEL="full $APP_SCHEME scheme, same as CI"
if [[ "${1:-}" == "--unit-only" ]]; then
  ONLY=("-only-testing:$APP_UNIT_TARGET")
  LABEL="$APP_UNIT_TARGET only, NOT what CI runs"
elif [[ -n "${1:-}" ]]; then
  echo "unknown option: $1 (only --unit-only is supported)" >&2
  exit 2
fi

SIM="$(bash "$TOOLKIT/bin/ci_pick_simulator.sh")"
SLUG="$(tr '[:upper:]' '[:lower:]' <<<"$APP_NAME")"
# Where the log and the result bundle go. By default a fresh temp location;
# TEST_OUTPUT_DIR puts them under a directory the caller chooses, which CI
# needs to upload them after a failure. (Apple's `mktemp -t` ignores TMPDIR,
# so setting that is not enough: seen on 2026-09-28, when a failed GitHub
# Actions run uploaded nothing.)
if [[ -n "${TEST_OUTPUT_DIR:-}" ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$TEST_OUTPUT_DIR"
  LOG="$TEST_OUTPUT_DIR/$SLUG-test-$STAMP.log"
  BUNDLE="$TEST_OUTPUT_DIR/$SLUG-test-bundle-$STAMP/result.xcresult"   # must not pre-exist
  mkdir -p "$(dirname "$BUNDLE")"
else
  LOG="$(mktemp -t "$SLUG-test")"
  BUNDLE="$(mktemp -d -t "$SLUG-test-bundle")/result.xcresult"   # must not pre-exist
fi
ERRLOG="${LOG}.stderr"
echo "App:     $APP_NAME ($ROOT)"
echo "Running: $LABEL"
echo "Log:     $LOG  (deleted if the run passes)"
echo "Stderr:  $ERRLOG"
echo "Bundle:  $BUNDLE"
echo

set +e
xcodebuild test \
  -project "$APP_PROJECT" \
  -scheme "$APP_SCHEME" \
  -destination "id=$SIM" \
  -resultBundlePath "$BUNDLE" \
  ${ONLY[@]+"${ONLY[@]}"} \
  ${APP_XCODEBUILD_EXTRA[@]+"${APP_XCODEBUILD_EXTRA[@]}"} \
  > "$LOG" 2> "$ERRLOG"
XC_EXIT=$?
set -e

# Authoritative counts, from the result bundle.
read -r B_PASSED B_FAILED B_SKIPPED B_TOTAL B_RESULT <<<"$(
  xcrun xcresulttool get test-results summary --path "$BUNDLE" 2>/dev/null \
  | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("passedTests", "?"), d.get("failedTests", "?"), d.get("skippedTests", "?"),
          d.get("totalTestCount", "?"), d.get("result", "?"))
except Exception:
    print("? ? ? ? ?")'
)"

# Log-derived counts, for comparison only.
LOG_LINES=$(grep -cE "^Test case '[^']+'" "$LOG" || true)
ERRORS=$(cat "$LOG" "$ERRLOG" | grep -cE " error: " || true)

echo "xcodebuild exit : $XC_EXIT"
if [[ "$B_RESULT" == "?" ]]; then
  echo "bundle          : UNREADABLE, falling back to the log, which can undercount"
  B_PASSED=$(grep -cE "' passed on " "$LOG" || true)
  B_FAILED=$(grep -cE "' failed on " "$LOG" || true)
  B_TOTAL=$LOG_LINES; B_SKIPPED="?"; B_RESULT="unknown"
fi
echo "tests passed    : $B_PASSED"
echo "tests failed    : $B_FAILED"
echo "tests skipped   : $B_SKIPPED"
echo "tests total     : $B_TOTAL  (bundle result: $B_RESULT)"
echo "compile errors  : $ERRORS"
if [[ "$B_TOTAL" != "?" && "$LOG_LINES" -ne "$B_TOTAL" ]]; then
  echo "note            : the log shows $LOG_LINES result lines vs $B_TOTAL in the bundle."
  echo "                  The bundle is authoritative; the log is for reading."
fi
echo

if [[ "$XC_EXIT" -eq 0 ]] && grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG" \
   && [[ "$B_RESULT" == "Passed" ]] && [[ "$B_FAILED" == "0" ]] \
   && [[ "$B_TOTAL" != "?" ]] && [[ "$B_TOTAL" -gt 0 ]]; then
  echo "** TEST SUCCEEDED **  ($LABEL)"
  # A passing run's bundle and logs are never read again, and each bundle is
  # 50-100 MB: 87 of them had filled 1.2 GB of a full disk on 2026-09-27.
  # A failing run keeps them (paths printed below) for reading.
  rm -rf -- "$(dirname "${BUNDLE:?}")" "${LOG:?}" "${ERRLOG:?}"
  exit 0
fi

if [[ "$B_TOTAL" == "0" ]]; then
  echo "0 tests ran. A filter that matches nothing still prints TEST SUCCEEDED;"
  echo "that is not a pass."
fi
echo "** TEST FAILED **  ($LABEL)"
echo
echo "--- failures ---"
xcrun xcresulttool get test-results summary --path "$BUNDLE" 2>/dev/null \
  | python3 -c 'import sys, json
try:
    for f in json.load(sys.stdin).get("testFailures", [])[:25]:
        print("  %s: %s" % (f.get("testName", "?"), f.get("failureText", "")))
except Exception:
    pass' || true
grep -E "' failed on |: error: " "$LOG" | head -25 || true
echo
echo "Full log: $LOG"
echo "Stderr:   $ERRLOG"
echo "Bundle:   $BUNDLE"
exit 1
