# Shared app toolkit

One set of scripts for every iOS app Joe works on, currently PlowR and Wockett.
Created 2026-09-27. It lives here, outside both repos, so neither app depends on
the other: each repo only carries a small config and thin wrappers.

## Layout

| Path | What |
| --- | --- |
| `bin/test.sh <repo> [--unit-only]` | Runs the scheme's tests; verdict from exit code + `** TEST SUCCEEDED **` + the xcresult bundle; 0 tests = failure |
| `bin/lint.sh <repo> [--fix]` | SwiftLint from the repo root, with the exclusions proved in effect |
| `bin/ci_pick_simulator.sh` | Prints the UDID of the newest available iPhone simulator |
| `lib/app_config.py <repo>` | Reads `<repo>/.claude/app.json`, prints shell assignments; rejects unknown keys |

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
  "reviewFocus": ["what the critic should check every time for this app"],
  "notes": "free text"
}
```

Required: `app`, `project`, `scheme`, `unitTestTarget`, `lintExcluded`.
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

This folder is a local git repo (no remote). Commit each change with a line
saying why, and run both apps' `scripts/test.sh` and `scripts/lint.sh` before
calling a change done, because it affects both at once.
