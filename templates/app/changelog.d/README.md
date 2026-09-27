# Changelog entries

Each change adds **one new file here** instead of editing `CHANGELOG.md`. Two
open PRs that both edit `CHANGELOG.md` conflict at the same line every time,
and a conflicted PR cannot auto-merge. Two PRs that each add a new file never
conflict.

## Format

Name the file after the branch, without its prefix:
`fix/stop-order` → `stop-order.md`.

The content is the entry exactly as it will appear in `CHANGELOG.md`: one or
more [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) headings, each
with its bullets. Explain *why*, not just what.

```markdown
### Fixed
- Stops stay in the order you set after a relaunch. …
```

Headings, in the order `CHANGELOG.md` uses: `Added`, `Changed`, `Fixed`,
`Internal`.

## When a version is cut

The PR that cuts a version moves every file's bullets into `[Unreleased]` under the
matching heading, deletes the files (this README stays), then cuts
`[Unreleased]` into the new version. `CHANGELOG.md` is only edited there.
