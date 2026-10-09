# Shared app toolkit

The shared pipeline for every iOS app Joe works on, currently PlowR and
Wockett. Created 2026-09-27. It lives here, outside the app repos, so no app
depends on another: each repo carries a small config, thin wrappers, and a
`CLAUDE.md` that imports `PROCESS.md` from here.

GitHub: `FreeScoopDev/app-toolkit`, public since 2026-09-27 (scripts and docs
only; nothing private goes in). Checked out at `~/.claude/toolkit`.

| Start here | For |
| --- | --- |
| `PROCESS.md` | How every change and every release ships, for every app |
| `NEW-APP.md` | Starting a new app, from Xcode to the first auto-merged PR |

## Layout

| Path | What |
| --- | --- |
| `bin/test.sh <repo> [--unit-only \| --ui-only]` | Runs the scheme's tests (or one target: CI runs the two as parallel jobs, `TEST_XCODEBUILD_ARGS` adding arguments for one run); verdict from exit code + `** TEST SUCCEEDED **` + the xcresult bundle; 0 tests = failure. `TEST_OUTPUT_DIR=<dir>` keeps the log and bundle under `<dir>` for CI to upload (Apple's `mktemp -t` ignores `TMPDIR`) |
| `bin/lint.sh <repo> [--fix]` | SwiftLint from the repo root, with the exclusions proved in effect |
| `bin/ci_pick_simulator.sh` | Prints the UDID of the newest available iPhone simulator |
| `bin/repo-check.sh <repo> [--apply]` | Compares the GitHub repo with the standard (public, squash only, auto-merge, secret scanning and push protection on, "Protect main" requiring `requiredChecks`); `--apply` fixes it, except visibility |
| `bin/new-app.sh <repo> <owner/name> [--local-only]` | Adds `templates/app` to a fresh Xcode project, commits, creates the public repo, applies the standard |
| `bin/cloudkit-schema-check.sh <repo> [schema.ckdb]` | Lists the fields each CloudKit record type needs for the repo's SwiftData models, with CloudKit Console's count; given a schema exported from the Console, names each missing record type, field or wrong type. Exit 1 when something is missing, 2 when it meets Swift it can't read |
| `bin/release-build-check.sh <repo> <commit>` | Says whether a Release Flow build's commit is the release PR's merge commit; lists the unlisted commits when it is not |
| `bin/session-start.sh` | Claude Code SessionStart hook: says when the session's checkout is behind `origin/main` and prints the current `CLAUDE.md`; says when this toolkit checkout is behind. Silent when everything is current |
| `bin/lint-hook.sh` | Claude Code PostToolUse hook: after Claude edits or writes a `.swift` file, runs SwiftLint on that file from its repo root with the repo's config and hands the violations to Claude. Report only, never `--fix`; silent otherwise |
| `bin/install-hooks.sh` | Registers both hooks in `~/.claude/settings.json`, once each; run after cloning the toolkit, and again after a pull that adds a hook |
| `lib/app_config.py <repo>` | Reads `<repo>/.claude/app.json`, prints shell assignments; rejects unknown keys |
| `templates/app/` | The standard files a new app starts with; `__APP__`-style placeholders |
| `agents/` | Joe's subagents; `~/.claude/agents/*.md` are symlinks to these |
| `tests/selftest.sh` | The toolkit's required check: runs every script on Linux, including the cases that must refuse and write nothing |

## Per-app config: `<repo>/.claude/app.json`

```json
{
  "app": "PlowR",
  "project": "PlowR.xcodeproj",
  "scheme": "PlowR",
  "unitTestTarget": "PlowRTests",
  "uiTestTarget": null,
  "xcodebuildExtraArgs": ["CODE_SIGNING_ALLOWED=NO"],
  "lintExcluded": ["PlowRTests", "docs"],
  "versionSource": "project.pbxproj",
  "github": "FreeScoopDev/PlowR",
  "requiredChecks": ["PlowR | CI Tests | Test - iOS", "Service-language guard", "SwiftLint"],
  "criticMinLines": 40,
  "reviewFocus": ["what the critic should check every time for this app"],
  "notes": "free text"
}
```

Required: `app`, `project`, `scheme`, `unitTestTarget`, `lintExcluded`.
`repo-check.sh` also needs `github` and `requiredChecks`. `criticMinLines`
defines a major change (PROCESS.md, "Major changes") for the process and for
the repo's "Critic verdict" check, which refuses to run without it.
The repos are public, so nothing private goes in this file.

## Each repo's wrappers

`scripts/test.sh`, `scripts/lint.sh` and `scripts/ci_pick_simulator.sh` in each
repo only forward to `bin/` here, passing the repo root. CI never calls them
(Xcode Cloud runs the scheme; GitHub Actions runs SwiftLint directly), so a
clone without this toolkit still builds and passes CI. The wrappers just say
where the toolkit is expected if it's missing.

`scripts/critic_verdict.py` is the exception: it is CI's own, run by
`.github/workflows/critic-verdict.yml`, so it carries its logic rather than
forwarding here. The self-test runs the template copy; a change to it reaches
an existing app only by copying it into that repo.

## Agents

`agents/` holds Joe's five subagents: `critic`, `test-auditor`,
`release-checker`, `crash-triage` and `aso-writer`. Moved here 2026-09-27, so
they are backed up and change through PRs like everything else. Claude Code
loads them from `~/.claude/agents/`, where each is a symlink to this folder.
After editing one here, the change reaches new sessions once the PR merges and
`~/.claude/toolkit` is pulled. They read the repo's `app.json` and `CLAUDE.md`
instead of naming an app. The self-test checks each file still loads: its
frontmatter, and a `name` that matches the file name.

## The session-start hook

A session started in Joe's own checkout of an app reads that folder's
`CLAUDE.md`. Claude never updates that folder (PROCESS.md, git rules), so the
file drifts from `main`: on 2026-09-28 Wockett's was 13 commits behind and a
session was handed a process replaced the day before. `bin/session-start.sh`
runs at every session start (Claude Code adds its output to the session's
context). When the checkout is behind `origin/main` it says so; when its
`CLAUDE.md` also differs, it prints the current one from `origin/main`. It also
says when `~/.claude/toolkit` itself is behind, with the fast-forward command.
Up to date, it prints nothing. It never fails a session start: no `set -e`, a
15 s watchdog on the fetch, exit 0 on every path.

Install it once: `bin/install-hooks.sh` adds the hook to
`~/.claude/settings.json` (idempotent, touches nothing else). The self-test
proves the hook by building a repo that is behind its origin and checking the
banner and the printed file, and proves the installer by running it twice.

## The lint hook

A lint error used to show up only when the PR's SwiftLint check went red,
which cost a push and a wait. `bin/lint-hook.sh` runs after every Edit or
Write. For a `.swift` file in a repo that has a `.swiftlint.yml`, it lints that
one file the way `bin/lint.sh` does: from the repo root, with the in-place
config, and with `--force-exclude`, because SwiftLint lints a file named on the
command line even when the config excludes it (checked 2026-10-09 with a force
unwrap in `PlowRTests`). Violations reach Claude as `additionalContext` next to
the tool result. It never blocks: no block decision, no exit 2, exit 0 on every
path. It never runs `--fix`, which has broken builds. The CI check is still the
judge, because local and CI SwiftLint have disagreed before.

The self-test proves it with a fake `swiftlint` that records where and how it
was called, so it runs on Linux.

## Changing anything here

Work in a worktree of this repo, never in `~/.claude/toolkit` itself: that
checkout is what every app's scripts run from, and what every app's
`CLAUDE.md` imports. Change it through a PR, like an app: `tests/selftest.sh`
is the required check (`.claude/app.json`), and the PR merges itself once it
passes. Then pull it into `~/.claude/toolkit`. Run both apps' `scripts/test.sh` and
`scripts/lint.sh` (with `APP_TOOLKIT` pointing at the worktree) before calling
a change done, because it affects every app at once.
