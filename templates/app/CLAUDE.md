# __APP__ — project memory

Read this first. It exists so each session doesn't re-derive the same facts.
Started __DATE__ from the FreeScoopDev app template. Correct it when it goes
stale: a wrong note is worse than none.

## How work ships

@~/.claude/toolkit/PROCESS.md

That file is the process for every app: branches, auto-merge, `changelog.d/`,
releases, git rules, verifying claims. It lives in the shared toolkit
(`FreeScoopDev/app-toolkit`, checked out at `~/.claude/toolkit`). If it did not
load, clone that repo there before doing anything else.

What is specific to __APP__:

| Thing | Value |
| --- | --- |
| GitHub repo | `__REPO__` |
| Joe's folder | `~/Desktop/Apps/__APP__` (read-only git for Claude) |
| Claude's worktrees | `~/Desktop/Apps/__APP__-claude/<branch>`, one per branch (PROCESS.md) |
| Xcode project / scheme | `__PROJECT__.xcodeproj` / `__SCHEME__` |
| Unit tests | `__UNIT_TESTS__` |
| Required checks on `main` | listed in `.claude/app.json` → `requiredChecks` |
| Slack | `#__SLUG__-ci`, `#__SLUG__-releases` |
| App Store Apple ID | not created yet |

## What this is

(One paragraph: what the app does, who it's for, what's live.)

## Non-obvious things that have already cost time

(Add each one the day it costs time, with the date and what to check first.)

## Conventions

(Design system, naming, anything a reviewer should check every time. Put the
review checklist in `.claude/app.json` → `reviewFocus` too.)

## Running things

    scripts/test.sh              # full scheme (what CI runs)
    scripts/test.sh --unit-only  # faster, but NOT what CI runs
    scripts/lint.sh              # SwiftLint with verified exclusions

`~/.claude/toolkit/bin/repo-check.sh .` checks the GitHub settings against the
standard.
