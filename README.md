# Shared app toolkit

The shared pipeline for every iOS app Joe works on, currently PlowR and
Wockett. Created 2026-09-27. It lives here, outside the app repos, so no app
depends on another: each repo carries a small config, thin wrappers, and a
`CLAUDE.md` that imports `PROCESS.md` from here.

GitHub: `FreeScoopDev/app-toolkit` (private). Checked out at `~/.claude/toolkit`.

| Start here | For |
| --- | --- |
| `PROCESS.md` | How every change and every release ships, for every app |
| `NEW-APP.md` | Starting a new app, from Xcode to the first auto-merged PR |

## Layout

| Path | What |
| --- | --- |
| `bin/test.sh <repo> [--unit-only]` | Runs the scheme's tests; verdict from exit code + `** TEST SUCCEEDED **` + the xcresult bundle; 0 tests = failure |
| `bin/lint.sh <repo> [--fix]` | SwiftLint from the repo root, with the exclusions proved in effect |
| `bin/ci_pick_simulator.sh` | Prints the UDID of the newest available iPhone simulator |
| `bin/repo-check.sh <repo> [--apply]` | Compares the GitHub repo with the standard (public, squash only, auto-merge, "Protect main" requiring `requiredChecks`); `--apply` fixes it, except visibility |
| `bin/new-app.sh <repo> <owner/name> [--local-only]` | Adds `templates/app` to a fresh Xcode project, commits, creates the public repo, applies the standard |
| `lib/app_config.py <repo>` | Reads `<repo>/.claude/app.json`, prints shell assignments; rejects unknown keys |
| `templates/app/` | The standard files a new app starts with; `__APP__`-style placeholders |

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
  "reviewFocus": ["what the critic should check every time for this app"],
  "notes": "free text"
}
```

Required: `app`, `project`, `scheme`, `unitTestTarget`, `lintExcluded`.
`repo-check.sh` also needs `github` and `requiredChecks`.
The repos are public, so nothing private goes in this file.

## Each repo's wrappers

`scripts/test.sh`, `scripts/lint.sh` and `scripts/ci_pick_simulator.sh` in each
repo only forward to `bin/` here, passing the repo root. CI never calls them
(Xcode Cloud runs the scheme; GitHub Actions runs SwiftLint directly), so a
clone without this toolkit still builds and passes CI. The wrappers just say
where the toolkit is expected if it's missing.

## Agents

`~/.claude/agents/critic.md`, `test-auditor.md` and `release-checker.md` read
the same `app.json` (and the repo's `CLAUDE.md`) instead of naming an app.

## Changing anything here

Work in a worktree of this repo, never in `~/.claude/toolkit` itself: that
checkout is what every app's scripts run from, and what every app's
`CLAUDE.md` imports. Change it through a PR, and pull it into
`~/.claude/toolkit` after the merge. Run both apps' `scripts/test.sh` and
`scripts/lint.sh` (with `APP_TOOLKIT` pointing at the worktree) before calling
a change done, because it affects every app at once.
