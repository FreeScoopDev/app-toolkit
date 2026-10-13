# CI — what runs, where, and why

| Where | What | Required on `main` |
| --- | --- | --- |
| GitHub Actions, `.github/workflows/guards.yml` | SwiftLint (Linux, 1x billing) | Yes, from day one |
| GitHub Actions, `.github/workflows/tests.yml` | `Unit tests (iOS)`: the `__UNIT_TESTS__` target on `macos-26`, through the toolkit's `bin/test.sh` at a pinned commit | Yes, once it has passed on a PR (NEW-APP.md, part 4) |
| GitHub Actions, `.github/workflows/critic-verdict.yml` | `Critic verdict`: a major PR records the critic's verdict (PROCESS.md) | Add it with `Unit tests (iOS)` |
| Xcode Cloud, `Release Flow` | Archive for TestFlight and the App Store, manual start on `main` only | No; it runs only when Joe starts a release |

Tests run on GitHub Actions, not Xcode Cloud: Xcode Cloud's 25 hours a month
are shared by every app, and when they ran out (2026-10-10) every PR's test
run was cancelled. The repository is public, so the macOS runner is free. A
private repo pays 10x for macOS minutes; see PROCESS.md, "Private repos".

Set up by following `~/.claude/toolkit/NEW-APP.md`. Record here what was
actually chosen (Xcode and macOS pins, Slack channel) the day it is set,
with the date. Settings that exist only in App Store Connect are invisible
to git; this file is their record.

## GitHub Actions

### `Unit tests (iOS)`

| | |
| --- | --- |
| Runs on | every PR to `main`, and every push to `main` |
| Runner | `macos-26`, newest Xcode 26 on the image |
| Toolkit commit | (the `ref:` in `tests.yml`; bump it deliberately) |
| First green PR | (PR number and date) |
| Proved it gates | (the throwaway PR that broke a test and went red) |

## Xcode Cloud

### `Release Flow`

| | |
| --- | --- |
| Start condition | Manual Start, `main` only |
| Action | Archive - iOS, scheme `__SCHEME__`, Distribution Preparation **TestFlight and App Store** |
| Post-action | TestFlight Internal Testing |
| Environment | (Xcode and macOS versions, pinned, with the date) |
| Notifies | Slack `#__SLUG__-releases` |
