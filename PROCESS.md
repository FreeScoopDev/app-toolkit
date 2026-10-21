# How a change ships — every FreeScoopDev app

This is the process for every app. Each app's `CLAUDE.md` imports this file
(`@~/.claude/toolkit/PROCESS.md`) and adds only what is specific to that app:
its required check names, its release details, its traps. Change the process
here, once, and every app follows. Agreed with Joe 2026-09-23; auto-merge and
`changelog.d/` since 2026-09-27.

**Joe decides what ships. Claude does the git work and the bookkeeping. Checks
run by themselves, and a change that passes them merges itself.**

## Every change: no Joe step

`main` is protected by a "Protect main" ruleset: pull requests only, squash
merge only, no force-push, no deletion, and the required checks listed in the
app's `.claude/app.json` (`requiredChecks`). `bin/repo-check.sh <repo>` in
this toolkit verifies that GitHub still matches this standard.

Claude, in a worktree of its own for each branch:

1. `git fetch`, then creates the branch in a new worktree from `origin/main`,
   never a local `main`:
   `git worktree add -b <branch> ~/Desktop/Apps/<App>-claude/<branch, / as -> origin/main`
   (`<App>` is `app` in `.claude/app.json`; `feat/route-store` lives in
   `PlowR-claude/feat-route-store`). One worktree per branch is what lets
   several sessions work on one app at once: two sessions sharing a folder
   overwrite each other's branch. Run side by side only what won't collide at
   merge: different apps, or clearly separate areas of one app. Local test
   runs of one app take turns on the simulator (`bin/test.sh` waits for the
   other run), because two at once kill each other's test host. A local
   `main` goes stale, and a branch cut from it silently leaves out
   merged work. One change per branch, prefixed `feat/`, `fix/`, `chore/`,
   `docs/` or `test/`. **Never stack a PR on another branch.** The test
   workflows (GitHub Actions `tests.yml`, Xcode Cloud `CI Tests`) only run
   PRs whose base is `main`, so a stacked PR gets no check until retargeted.
2. **On a major change, writes the spec before any code** (see "Major changes"
   below): what the change is for, numbered acceptance criteria, and every
   "must not" stated explicitly. It goes in the private specs repo,
   `~/Desktop/Apps/specs/<App>/<branch-name>.md` (`<App>` is `app` in
   `.claude/app.json`), committed and pushed straight to its `main`: no PR,
   no CI. The repo's `README.md` has the shape.
3. Makes the change, adds its **changelog entry as a new file in
   `changelog.d/`** (format in that folder's README), and runs
   `scripts/test.sh`.
4. Merges `origin/main` in, pushes the branch and opens the PR. The
   description says how each claim is known (see "Verifying claims").
5. **On a major change, runs the critic.** Spawns the `critic` agent with the
   repo path, the diff range (`origin/main...HEAD`) and the spec file; fixes
   every BLOCK finding, pushes, and runs it once more on the fixes until the
   verdict is not BLOCK. It runs once the branch is a stable build (slice
   complete, checks green), not after each intermediate push. Records the final verdict in the PR description's `**Critic
   verdict:**` line, and the spec's path (the path only: the specs repo is
   private, so never a link) on the `**Spec:**` line. Appends each run's
   findings to the spec file under `## Critic` and pushes it. If the PR adds
   or changes tests, also runs `test-auditor` on them and fixes what it finds.
6. Queues the merge: `gh pr merge <N> --auto --squash`, unless the PR is one
   of those under "Joe merges these" below. Gives Joe the link.
   If Claude Code's auto-mode safety check refuses it, Claude does not retry
   or look for a way around it: it tells Joe, and he clicks **Squash and
   merge** once every required check is green. (The check queued #93–#106
   on Wockett, then refused #107 and #108 on 2026-09-28; why is not known.)
7. About 2 minutes later, confirms every check named in the app's
   `requiredChecks` (`.claude/app.json`) has appeared on the PR
   (`gh pr checks <N>`). A check that never appears means its provider never
   got the event: re-fire with `gh pr close <N> && gh pr reopen <N>`, which
   re-sends the pull-request event to GitHub Actions and Xcode Cloud alike.
   Then check the merge is still queued
   (`gh pr view <N> --json autoMergeRequest`) and queue it again if not.
8. Fixes anything that blocks the merge: a red check, or a conflict (merge
   `origin/main` in, run `scripts/test.sh`, push). GitHub squash-merges once
   every required check is green, and deletes the branch.
9. After the merge, removes the branch's worktree (`git worktree remove`),
   deletes the local branch, and deletes the worktree's DerivedData folder:
   the one in `~/Library/Developer/Xcode/DerivedData/` whose `info.plist`
   `WorkspacePath` is the worktree's `.xcodeproj`
   (`/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' <folder>/info.plist`).
   `git worktree remove` leaves it behind, about 290 MB a branch; ten of them
   were found on a nearly full disk on 2026-10-12. Only that folder: other
   sessions may be building in the rest.

### Major changes

A change is **major** when its branch starts with `feat/`, or it changes more
than `criticMinLines` lines of Swift (added plus deleted, from `.claude/app.json`;
the template starts at 40) outside the test targets (`unitTestTarget`,
`uiTestTarget`). The number is a starting point, not a measured threshold:
change it in the app's `app.json`, and the process and the check follow.

The **Critic verdict** check (`.github/workflows/critic-verdict.yml`, logic in
`scripts/critic_verdict.py`) applies the same definition to every PR and fails
a major one whose description has no verdict line, or whose verdict is BLOCK.
Editing the description re-runs it. It proves a verdict was recorded, not that
the review was good. An app with no remote has no PR and no check: the spec
file's `## Critic` section is the record.

**Findings become standing checks.** When the critic finds the same class of
problem twice in an app, Claude adds that class to the app's `reviewFocus` in
`.claude/app.json`, which the critic checks on every run, and says so in the
PR.

Why: routine PRs merge themselves and nobody reads the code, so the critic is
the only reviewer. Before 2026-10-09 it ran when a session chose to, and plans
lived only in the chat that made them, so the critic's first finding was
often that there was no spec to check against.

**Hold.** If Joe says "hold #N", Claude runs `gh pr merge <N> --disable-auto`,
and that PR waits for Joe's own **Squash and merge**.

**Joe merges these.** A PR is never queued for auto-merge when it touches an
app's privacy policy or terms, `docs/staff/**`, an
`apple-app-site-association` file or any `.github/workflows/` file, and no
`app-toolkit` PR ever is. Claude opens it, says in the description that
it waits for Joe, and Joe clicks **Squash and merge**. Why: `docs/` is live on
the website minutes after a merge, a workflow change can rewrite the checks
that guard every later PR, and toolkit scripts run on Joe's Mac in every
session (2026-10-12 audit, security findings 11 and 12).

Why auto-merge: by the time Joe clicked Merge, the required checks had already
passed, and he was not reviewing code, so the click added only waiting. `main`
is not what users get; the gate that matters is the release, which stays Joe's.

Why `changelog.d/`: every open PR used to add its entry at the same line of
`CHANGELOG.md`, so the second to land always conflicted (Wockett #90, #91,
#92 in one afternoon), and a conflicted PR cannot auto-merge.

## Shipping a version: Joe's steps

**Before the release PR, crashes and feedback.** Claude runs the
`crash-triage` agent on every crash file in `~/Desktop/Apps/crashlogs/`
(`.ips`, `.crash`, `.xccrashpoint`, MetricKit `.json`) for this app that is
newer than the last release tag's commit (`git log -1 --format=%cI <tag>`),
passing the files and the repo path. It also asks Joe for anything only he can
see: new crashes in Xcode Organizer (Window → Organizer → Crashes, this app,
since the last version) and new TestFlight feedback (App Store Connect →
the app → TestFlight → Feedback). Each real problem goes back through "Every
change" before the cut, or onto the Ship Card as a known issue Joe accepts.
Nothing new is a fine answer, and the Ship Card says so. This replaces the
weekly QA pass, which ran on a timer with nothing new to read.

Claude opens the **release PR**: it moves every `changelog.d/` entry into
`CHANGELOG.md` under the new version's headings, deletes those files (the
README stays), bumps `MARKETING_VERSION`, and runs the `release-checker`
agent. For an app that syncs with CloudKit, Claude also asks Joe for an export
of the Production schema (CloudKit Console → the container → Production →
Export Schema…) and checks it with `bin/cloudkit-schema-check.sh`. When
Production lacks a field the models need, a record of that type that sets it
can't sync from a TestFlight or App Store build (every record of the type, for
a field that's always set), and nothing in the code shows it (PlowR 1.2.0 had
ten). **The release PR is never auto-merged. Merging it is Joe's decision to
ship.** Its description starts with a **Ship Card**:

- **What's New**: App Store copy covering everything users have not seen since
  the version that is *live* (check `https://itunes.apple.com/lookup?id=<Apple
  ID>`), not just since the last cut.
- **What to Test**: TestFlight copy.
- **QA cards**: the Testing/QA cards from the Notion Releases page. The
  regression card includes the release-checker's **For the regression QA
  card** steps (Dynamic Type at the largest sizes, contrast in light and dark
  mode), which can only be checked on a device.
- **Console steps**: anything only Joe can do (a CloudKit schema deploy, an
  App Store Connect product), written as exact clicks. Omitted when none.
- **Release check**: the `release-checker` report.
- **Crashes and feedback**: what `crash-triage` found and what Joe reported
  from Organizer and TestFlight, with what was done about each, or "nothing
  new since vX.Y".

Joe then:

1. Merges the release PR.
2. Does the console steps, if the Ship Card lists any.
3. First, App Store Connect → Xcode Cloud → **Usage**: look at the hours
   left this period. Every app shares one pool of 25, and it ran out around
   2026-10-10. If it is nearly empty, or Start Build is refused, tell Claude
   and follow "Release Flow unavailable" below. Otherwise App Store Connect →
   Apps → the app → Xcode Cloud → Release Flow → **Start
   Build**, right after the release PR merges: Release Flow archives whatever
   `main` is at that moment, and routine PRs merge themselves. Waits for the
   app's Slack release channel and gives Claude the build number **and the
   commit named in the post**. Never predict the number: Xcode Cloud uses one
   counter across all workflows, and every PR's `CI Tests` run consumes one.
   Claude then runs `bin/release-build-check.sh <repo> <commit>`: the build
   must be the release PR's merge commit, or it carries changes the Ship Card
   never listed. A mismatch means no QA on that build; Claude lists the extra
   commits and the next step is a fresh build or a fresh cut.
4. Installs it from TestFlight, works through the QA cards, and tells Claude
   which passed and which failed ("all passed" is enough). Claude sets each
   card to Passed or Failed in Notion, and puts the build number, the checked
   commit and the QA result on the Releases row. A failure goes back through
   "Every change", then step 3 again.
5. App Store Connect → Distribution → new version → Add Build → pastes What's
   New → Add for Review → Submit. Tells Claude "submitted build N".

After step 5, Claude tags the build's commit `vX.Y` (lightweight) and pushes
the tag, and sets the Notion Releases row to `In Review` with the build number
and the commit the check confirmed.

**Release Flow unavailable** (Xcode Cloud down, or its hours used up): only
the build in step 3 changes. Claude makes a fresh worktree of the release
PR's merge commit
(`git worktree add --detach ~/Desktop/Apps/<App>-claude/release-<version> <merge commit>`)
and Joe archives that folder in Xcode (Product → Archive → Distribute App),
never his own folder if it can be avoided: it builds whatever is on disk
there, which is how Wockett build 84 shipped without a merged fix. The app's
`CLAUDE.md` says how a manual archive gets its build number. Everything else
still applies: the Ship Card, the `release-checker` report, the crash step,
and `bin/release-build-check.sh <repo> <commit archived> --merge-commit <merge
commit>`, with the merge commit passed explicitly, since no Slack post names
one. PlowR 1.7.0 went out this way on 2026-10-11 with none of those, and the
record had to be rebuilt afterwards.

## Token budget

Claude's usage has a 5-hour and a weekly limit. One night of parallel
branch builds on 2026-10-20 used about 1.05 billion cache-read tokens, 78% of
it in subagents that each re-read a 350-650K context on every call, all on
the most expensive model. These rules keep that down; they apply to every app.

1. **Builds and mechanical checks run on Sonnet.** A subagent that implements
   a branch from its spec, `test-auditor` and `release-checker` run on
   `sonnet` (the two agents are set that way in `agents/`; pass
   `model: sonnet` on a build subagent). Opus is for design, specs and the
   `critic`. If a Sonnet build fails twice on the same problem, stop and hand
   it to Opus with what was tried, rather than letting it loop.
2. **Small, finishing builds.** One build subagent gets one slice, not a
   whole milestone: it commits, pushes and stops. Past about 300K tokens of
   context, or 150 tool calls with no push, end it and start a fresh agent
   with a short handoff note.
3. **Restart the orchestrating session at milestones.** After a milestone
   merges, or at about 300K context, write a handoff note (state, open PRs,
   next step) and start a new session or `/compact`. Joe does the restart.
4. **The critic runs once per stable build** (see "Major changes"), not on
   every push. It stays on Opus: it is the only reviewer, so this rule cuts
   how often it runs, not how well.
5. **Few parallel builds.** Separate worktrees are still how independent
   slices run side by side, but start the fewest that keep Joe unblocked,
   and stagger a batch when the 5-hour window is above about 60%
   (`get_usage` shows it).
6. **Report the cost.** A build or critic subagent's final summary includes
   its call count and whether it hit a limit above, so the next brief is
   sized from real numbers.

## Git rules

- Claude commits, pushes branches, queues auto-merge and pushes release tags.
  It never pushes to `main`, never force-pushes, never merges past a failing
  or missing check, and never auto-merges the release PR or a PR under "Joe
  merges these".
- **Joe's folder** (`~/Desktop/Apps/<App>`) is his. Git there is read-only,
  with `--no-optional-locks`: no `switch`, `checkout`, `merge`, `pull` or
  `commit`. If it needs updating before an emergency archive, give Joe the
  command. Cost: a fast-forward that landed 14 s into a manual archive shipped
  a build without a merged fix (Wockett build 84).
- **A session started in Joe's folder still gets the current rules.** That
  folder is often behind `main`, and its `CLAUDE.md` with it. The toolkit's
  SessionStart hook (`bin/session-start.sh`, installed once by
  `bin/install-hooks.sh`) prints a STALE CHECKOUT banner with the current
  `CLAUDE.md` from `origin/main` when that happens, and a TOOLKIT BEHIND
  line when `~/.claude/toolkit` needs a fast-forward. If the banner is in
  the session's context, follow the printed file, not the one on disk.
- **The toolkit is pulled only after Joe sees what's coming.** Its scripts
  run on Joe's Mac in every session, so the TOOLKIT BEHIND line lists the
  incoming commits and files. Claude shows Joe that list and fast-forwards
  `~/.claude/toolkit` only after he says yes.
- Every branch is pushed. A repo with no remote has no copy when a disk or a
  sync goes wrong (the 2026-09-26 iCloud move cost SqwatrApp its history).
- In multi-step shell, `set -euo pipefail`. A failing guard does not stop a
  `&&` chain on the next line.

**Private repos.** Repos are public by default; private is for client work
(JDayOffroad). On GitHub's free plan a private repo can have no ruleset or
branch protection (the API answers 403) and no auto-merge, so nothing on
GitHub enforces the gate and the steps above that rely on it do not apply.
The gate is then a rule: a branch merges only after `scripts/test.sh`
passes locally and its Linux checks are green, and the app's `CLAUDE.md`
says who merges. Never add a macOS job to a private repo casually: GitHub
bills macOS minutes there at 10x, an estimated $264 per 15 days at the
live apps' load.

## Verifying claims

A cheap check is almost always available. Before stating a finding, ask what
would make it false and whether that can be checked in under two minutes.

| How it is known | Worth |
| --- | --- |
| Read the source | A hypothesis. Say so. |
| Inspected the built artifact | Real, for anything about what ships |
| Ran it | Real, for behaviour |
| Broke it on purpose and watched it fail | The only proof a guard guards anything |

**An assertion that cannot fail is worse than none**, because it is counted as
coverage. Before claiming a test or a script guards something, break the
thing on purpose and watch it go red.

## Working with Joe

- Give the reasoning alongside the instruction; he is learning the system.
- Anything Joe has to do is written as numbered steps: where to click, what
  to type, what he should see, and what to do if he doesn't. If a risk can be
  removed on Claude's side instead, remove it rather than handing Joe a rule.
- Terminal commands as one complete copy-paste block, with a plain-English
  note on what it does.
- When Joe asks for something (a command, a link, a file), put the thing
  itself in the reply, even if it was given earlier, and repeat it in the
  turn's final message: text between tool calls in a long turn gets missed.
- Anything for Joe's clipboard goes through `LC_ALL=en_US.UTF-8 pbcopy`
  (and `pbpaste`). Claude's shell has no `LANG`, so plain `pbcopy` garbled
  "·" into "¬∑", and the pasted text landed in a real database.
- Delete build copies (scratch DerivedData, archives, mutant copies, result
  bundles) as soon as their check is done, and check
  `df -h /System/Volumes/Data` before a batch of builds: they once filled
  Joe's disk and broke his iPhone build. Never clear the shared DerivedData or
  another session's files without asking.
