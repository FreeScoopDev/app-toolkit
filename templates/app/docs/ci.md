# CI — what runs, where, and why

| Where | What | Required on `main` |
| --- | --- | --- |
| GitHub Actions, `.github/workflows/guards.yml` | SwiftLint (Linux, 1x billing) | Yes, from day one |
| Xcode Cloud, `CI Tests` | the `__SCHEME__` scheme's tests on every PR to `main` | Yes, once it has posted on a PR |
| Xcode Cloud, `Release Flow` | Archive for TestFlight and the App Store, manual start on `main` only | No; it runs only when Joe starts a release |

Set up by following `~/.claude/toolkit/NEW-APP.md`. Record here what was
actually chosen (Xcode and macOS pins, the test destination, Slack channels)
the day it is set, with the date. Settings that exist only in App Store
Connect are invisible to git; this file is their record.

## Xcode Cloud

### `CI Tests`

| | |
| --- | --- |
| Start condition | Pull Request Changes, source any branch, target `main` |
| Action | Test - iOS, scheme `__SCHEME__`, Use Scheme Setting, Required to pass |
| Environment | (Xcode and macOS versions, pinned, with the date) |
| Notifies | Slack `#__SLUG__-ci` |

### `Release Flow`

| | |
| --- | --- |
| Start condition | Manual Start, `main` only |
| Action | Archive - iOS, scheme `__SCHEME__`, Distribution Preparation **TestFlight and App Store** |
| Post-action | TestFlight Internal Testing |
| Environment | (same pins as CI Tests) |
| Notifies | Slack `#__SLUG__-releases` |
