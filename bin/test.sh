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
#   5. A local run tests on the one simulator: no parallel clones, and no
#      diagnostics archive on a failure. With the scheme's "execute in
#      parallel", xcodebuild copies the simulator into
#      ~/Library/Developer/XCTestDevices for each run and left one copy
#      behind every time ("Clone 2 of iPhone 17": 55 of them by 2026-09-29).
#      Those copies, and the diagnostics a failing test attaches, helped fill
#      the disk until test runs failed to install the app. Swift Testing still
#      runs tests in parallel inside the one simulator. CI (where CI is set)
#      keeps both: its machine is thrown away, and a failed run's
#      diagnostics are worth uploading.
#
# Usage: test.sh <repo root> [--unit-only | --ui-only]
#   TEST_OUTPUT_DIR=<dir>        keep the log and result bundle under <dir> (CI uploads them)
#   TEST_XCODEBUILD_ARGS="..."   extra xcodebuild arguments for this run (CI's UI job)
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
  LABEL="$APP_UNIT_TARGET only, NOT the full scheme"
elif [[ "${1:-}" == "--ui-only" ]]; then
  # CI runs the two targets as two parallel jobs; each half is half the
  # scheme, and the pair together is what a local run does in one go.
  [[ -n "${APP_UI_TARGET:-}" ]] || { echo "$APP_NAME has no uiTestTarget in .claude/app.json" >&2; exit 2; }
  ONLY=("-only-testing:$APP_UI_TARGET")
  LABEL="$APP_UI_TARGET only, NOT the full scheme"
elif [[ -n "${1:-}" ]]; then
  echo "unknown option: $1 (--unit-only and --ui-only are supported)" >&2
  exit 2
fi
# Extra xcodebuild arguments for one run, on top of app.json's, e.g. CI's UI
# job passes "-parallel-testing-enabled NO" so the runner boots one simulator.
EXTRA=()
LOCAL=()
if [[ -z "${CI:-}" ]]; then
  LOCAL=(-parallel-testing-enabled NO -collect-test-diagnostics never)
fi
if [[ -n "${TEST_XCODEBUILD_ARGS:-}" ]]; then
  read -r -a EXTRA <<<"$TEST_XCODEBUILD_ARGS"
fi

SIM="$(bash "$TOOLKIT/bin/ci_pick_simulator.sh")"
SLUG="$(tr '[:upper:]' '[:lower:]' <<<"$APP_NAME")"

# One local run per app per simulator. Two worktrees of one app testing at
# once install the same app on the same simulator, and each install kills the
# other run's test host ("Test crashed with signal kill before establishing
# connection", seen twice on 2026-10-09 with PlowR). So a second run waits for
# the first. The lock is a directory (mkdir is atomic) holding the owner's PID
# and worktree; a lock whose PID is gone was left by a killed run and is taken
# over. CI has one run per machine and skips this.
if [[ -z "${CI:-}" ]]; then
  LOCK="${TEST_LOCK_DIR:-${TMPDIR:-/tmp}}/app-toolkit-test-$SLUG-$SIM.lock"
  WAITED=0
  until mkdir "$LOCK" 2>/dev/null; do
    OWNER_PID="$(cat "$LOCK/pid" 2>/dev/null || true)"
    # No PID a minute on: the owner died between taking the lock and writing it.
    if [[ -z "$OWNER_PID" && -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]] \
       || { [[ -n "$OWNER_PID" ]] && ! kill -0 "$OWNER_PID" 2>/dev/null; }; then
      echo "Taking over a test lock left by a run that is gone (pid $OWNER_PID)."
      rm -rf -- "${LOCK:?}"
      continue
    fi
    if [[ $WAITED -eq 0 ]]; then
      echo "Waiting: another $APP_NAME test run has this simulator ($(cat "$LOCK/root" 2>/dev/null || echo unknown), pid ${OWNER_PID:-?})."
      echo "Two runs on one simulator kill each other's test host, so this one starts when that one ends."
    fi
    WAITED=$((WAITED + 1))
    sleep 2
  done
  echo $$ > "$LOCK/pid"
  echo "$ROOT" > "$LOCK/root"
  trap 'rm -rf -- "${LOCK:?}"' EXIT
  [[ $WAITED -eq 0 ]] || echo "Lock free after about $((WAITED * 2)) s; starting."
fi
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
  ${LOCAL[@]+"${LOCAL[@]}"} \
  ${APP_XCODEBUILD_EXTRA[@]+"${APP_XCODEBUILD_EXTRA[@]}"} \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  > "$LOG" 2> "$ERRLOG"
XC_EXIT=$?
set -e

# Each install leaves the app it replaced in the simulator's Dead folder
# (com.apple.containermanagerd), 30 MB or so a run, and nothing empties it
# while the simulator stays booted: 110 copies filled a 228 GB disk to zero
# on 2026-09-29. Local runs clear the ones over a minute old; this run's own
# install is done by now.
if [[ -z "${CI:-}" ]]; then
  DEAD="$HOME/Library/Developer/CoreSimulator/Devices/$SIM/data/Library/Caches/com.apple.containermanagerd/Dead"
  find "$DEAD" -mindepth 1 -maxdepth 1 -name 'temp.*' -mmin +1 -exec rm -rf {} + 2>/dev/null || true
fi

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
# Compiler errors only ("/path/File.swift:12:3: error: ..."). On one simulator
# the app's own output reaches this log, and Core Data prints its store
# diagnostics as "CoreData: error: ...": 2452 such lines in a passing run.
ERRORS=$(cat "$LOG" "$ERRLOG" | grep -cE "^(/[^:]+:[0-9]+:([0-9]+:)? )?error: " || true)

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
