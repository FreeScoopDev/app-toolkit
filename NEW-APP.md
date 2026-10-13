# Starting a new app

From "we're making an app" to the first PR that merges itself. About an hour,
most of it in parts 1 and 3, which only Joe can do (they need his Apple and
GitHub sign-ins). Claude does parts 2 and 4.

The Apple steps are written from how Wockett and PlowR were set up, with
Xcode 26. If a screen doesn't match a step, stop and tell Claude what you see.

Throughout, `<App>` is the app's name, e.g. `Kiln`. Decide it first: it becomes
the GitHub repo, the Xcode project and the Slack channels, and renaming later is
expensive (Wockett's project is still called `PoCSquat` for that reason).

## Part 1 — Joe: create the project in Xcode

1. Xcode → **File → New → Project…** → **iOS** → **App** → **Next**.
2. Product Name: `<App>`. Team: your team. Organization Identifier: the same as
   your other apps. Interface **SwiftUI**, Language **Swift**. Testing System:
   **Swift Testing** (make sure tests are included). Click **Next**.
3. Save in `~/Desktop/Apps` (the local folder, not an iCloud one). Tick
   **Create Git repository on my Mac**. Click **Create**.
4. **Product → Scheme → Manage Schemes…** → tick **Shared** next to `<App>`
   → **Close**. Xcode Cloud and the GitHub test runner can only use a shared
   scheme; Claude's script checks this and stops if it's missing.
5. Tell Claude: "new app `<App>` is created".

## Part 2 — Claude: repo and protection

    ~/.claude/toolkit/bin/new-app.sh ~/Desktop/Apps/<App> FreeScoopDev/<App>

It adds the standard files (CLAUDE.md importing `PROCESS.md`, CHANGELOG.md,
`changelog.d/`, `.claude/app.json`, SwiftLint, script wrappers, the Linux
guards workflow, the `tests.yml` GitHub Actions workflow pinned to the
toolkit's current commit, `docs/ci.md`, and a blank `PrivacyInfo.xcprivacy` in
the app's folder), commits, creates the **public** GitHub repo, pushes, and
applies the repo standard: squash only, auto-merge on, branches deleted after
merge, and a "Protect main" ruleset requiring **SwiftLint**. `Unit tests
(iOS)` is required in part 4, once it has passed on a PR: a required check
that has never reported blocks every PR.

The repo is public by default, which is what makes the macOS test runner
free and the ruleset possible. A private repo (client work) gets neither on
the free plan; before creating one, read PROCESS.md, "Private repos", and
expect to remove `tests.yml`.

Then Claude works in one worktree per branch, in a folder beside Joe's
(`git worktree add -b <branch> ~/Desktop/Apps/<App>-claude/<branch> origin/main`,
PROCESS.md step 1). From here on Joe's
folder is his; see `PROCESS.md` → Git rules.

## Part 3 — Joe: App Store Connect, Slack and Release Flow

Tests run on GitHub Actions (`tests.yml`, already in the repo), so Xcode
Cloud has one job here: the Release Flow archive. Both live apps moved their
tests off Xcode Cloud after its shared 25 hours a month ran out.

**App record and Slack**

1. https://appstoreconnect.apple.com → **Apps** → **+** → **New App**.
   Platform iOS, name `<App>`, the bundle ID Xcode created, SKU `<App>`.
   **Create**. Xcode Cloud needs this record first.
2. In Slack, create **#`<app>`-releases** (lowercase).

**`Release Flow` (in Xcode: Apple requires the first workflow to be made there)**

3. Open `~/Desktop/Apps/<App>/<App>.xcodeproj` in Xcode.
4. **Product → Xcode Cloud → Create Workflow…**. If the menu isn't there, open
   the Report navigator (⌘9) → **Cloud** tab → **Get Started**.
5. Choose the product `<App>` → **Next** → **Edit Workflow**.
6. **General**: Name `Release Flow`. Clean **On**.
7. **Environment**: pick the **same Xcode and macOS versions Wockett's
   Release Flow uses** (Claude will tell you which, from Wockett's
   `docs/ci.md`), not "Latest Release". Pinned, a toolchain change is a
   decision instead of a surprise.
8. **Start Conditions**: delete "Branch Changes". Add **Manual Start**,
   restricted to branch **`main`**.
9. **Actions**: keep **Archive**, iOS, scheme `<App>`, Distribution
   Preparation **TestFlight and App Store**. Check this one twice:
   "TestFlight (Internal Testing Only)" builds can never be submitted for
   review, which is why Wockett 1.11 never reached the App Store. Delete any
   Test action.
10. **Post-Actions**: **TestFlight Internal Testing** → your internal testers.
    **Notify → Slack** → `#<app>-releases` → Success and Failure.
11. **Save** → **Next** → **Grant Access** to GitHub. On GitHub, give the
    Xcode Cloud app access to **FreeScoopDev/`<App>`**. Save.
12. Back in Xcode, **Complete**. Don't start a build.
13. Tell Claude: "Release Flow is set up for `<App>`".

## Part 4 — Claude: prove the gate, then require it

1. Opens a small PR (a line in `docs/ci.md`) and checks that `Unit tests
   (iOS)` and `Critic verdict` appear, and that the tests pass.
2. Proves the tests gate: a throwaway PR that breaks a unit test on purpose
   must go red on `Unit tests (iOS)`. Closes it unmerged. (PlowR did this
   with #8, then on Xcode Cloud.)
3. Adds `"Unit tests (iOS)"` and `"Critic verdict"` to `requiredChecks` in
   `.claude/app.json`, runs `repo-check.sh . --apply`, and confirms with a
   plain `repo-check.sh .` that the repo matches the standard.
4. Fills `docs/ci.md` with the first green PR, the throwaway PR, the Release
   Flow settings chosen in part 3, and the date.

From then on the app runs on `PROCESS.md`, like the others.
