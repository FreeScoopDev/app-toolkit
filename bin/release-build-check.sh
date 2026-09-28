#!/usr/bin/env bash
#
# Checks that a Release Flow build came from the release PR's merge commit.
#
# Why: Release Flow archives whatever `main` is when Joe clicks Start, and
# routine PRs auto-merge. On 2026-09-26 build 155 was started seven minutes
# after the release PR merged and matched; five feature PRs landed on `main`
# over the next day. A click a day later would have shipped them under the
# previous version's What's New and QA cards, unlisted. Xcode Cloud's Slack
# post names the build's commit, so this is a two-minute check, before Joe
# spends an hour on QA cards.
#
# Usage: release-build-check.sh <repo root> <build commit> [--merge-commit <sha>]
#   <build commit>   the commit in the Slack post (short or full SHA)
#   --merge-commit   the release PR's merge commit, if already known; without
#                    it, the newest merged PR whose branch starts with
#                    chore/release- is looked up with gh (needs the network)
# Exit 0 when they match, 1 when they do not, 2 on a usage error.
set -euo pipefail

ROOT="${1:?usage: release-build-check.sh <repo root> <build commit> [--merge-commit <sha>]}"
BUILD="${2:?usage: release-build-check.sh <repo root> <build commit> [--merge-commit <sha>]}"
shift 2
MERGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --merge-commit) MERGE="${2:?--merge-commit needs a sha}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

git -C "$ROOT" --no-optional-locks fetch origin main --quiet 2>/dev/null || echo "note: could not fetch origin/main; using what is already here" >&2
g() { git -C "$ROOT" --no-optional-locks "$@"; }

if ! BUILD_SHA=$(g rev-parse --verify --quiet "${BUILD}^{commit}"); then
  echo "MISMATCH: build commit $BUILD is not in this repository at all. Is the Slack post from this app?"; exit 1
fi

if [ -z "$MERGE" ]; then
  REPO=$(g remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
  MERGE=$(gh pr list --repo "$REPO" --state merged --limit 30 --json headRefName,mergeCommit,number \
    --jq 'map(select(.headRefName | startswith("chore/release-"))) | first | "\(.mergeCommit.oid) #\(.number)"') || { echo "could not list merged PRs for $REPO" >&2; exit 2; }
  [ -n "$MERGE" ] && [ "$MERGE" != " #" ] || { echo "no merged PR whose branch starts with chore/release- in the last 30" >&2; exit 2; }
  PR=${MERGE#* }; MERGE=${MERGE%% *}
else
  PR="(given)"
fi
MERGE_SHA=$(g rev-parse --verify --quiet "${MERGE}^{commit}") || { echo "release merge commit $MERGE is not in this repository" >&2; exit 2; }

if [ "$BUILD_SHA" = "$MERGE_SHA" ]; then
  echo "OK: build commit ${BUILD_SHA:0:7} is the release PR's merge commit $PR. Record ${BUILD_SHA:0:7} on the Notion row with the build number."
  exit 0
fi

echo "MISMATCH: build commit ${BUILD_SHA:0:7} is not the release PR's merge commit ${MERGE_SHA:0:7} $PR."
if g merge-base --is-ancestor "$MERGE_SHA" "$BUILD_SHA" 2>/dev/null; then
  n=$(g rev-list --count "$MERGE_SHA..$BUILD_SHA")
  echo "The build contains $n commit(s) after the release commit, none of them in this version's What's New or QA cards:"
  g log --format='  %h %s' "$MERGE_SHA..$BUILD_SHA"
elif g merge-base --is-ancestor "$BUILD_SHA" "$MERGE_SHA" 2>/dev/null; then
  echo "The build is OLDER than the release commit: it is missing what the release PR merged."
else
  echo "The build commit is not on the release commit's line at all."
fi
echo "Do not run the QA cards against this build. Start Release Flow again from the release commit, or cut the extra changes into the version first."
exit 1
