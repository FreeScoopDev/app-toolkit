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
   → **Close**. Xcode Cloud can only use a shared scheme; Claude's script
   checks this and stops if it's missing.
5. Tell Claude: "new app `<App>` is created".

## Part 2 — Claude: repo and protection

    ~/.claude/toolkit/bin/new-app.sh ~/Desktop/Apps/<App> FreeScoopDev/<App>

It adds the standard files (CLAUDE.md importing `PROCESS.md`, CHANGELOG.md,
`changelog.d/`, `.claude/app.json`, SwiftLint, script wrappers, the Linux
guards workflow, `docs/ci.md`), commits, creates the **public** GitHub repo,
pushes, and applies the repo standard: squash only, auto-merge on, branches
deleted after merge, and a "Protect main" ruleset requiring **SwiftLint**.
Xcode Cloud's check is added in part 4, once it exists: a required check that
has never reported blocks every PR.

Then Claude works in one worktree per branch, in a folder beside Joe's
(`git worktree add -b <branch> ~/Desktop/Apps/<App>-claude/<branch> origin/main`,
PROCESS.md step 1). From here on Joe's
folder is his; see `PROCESS.md` → Git rules.

## Part 3 — Joe: App Store Connect, Slack and Xcode Cloud

**App record and Slack**

1. https://appstoreconnect.apple.com → **Apps** → **+** → **New App**.
   Platform iOS, name `<App>`, the bundle ID Xcode created, SKU `<App>`.
   **Create**. Xcode Cloud needs this record first.
2. In Slack, create **#`<app>`-ci** and **#`<app>`-releases** (lowercase).

**`CI Tests` (in Xcode: Apple requires the first workflow to be made there)**

3. Open `~/Desktop/Apps/<App>/<App>.xcodeproj` in Xcode.
4. **Product → Xcode Cloud → Create Workflow…**. If the menu isn't there, open
   the Report navigator (⌘9) → **Cloud** tab → **Get Started**.
5. Choose the product `<App>` → **Next** → **Edit Workflow**.
6. **General**: Name `CI Tests`.
7. **Environment**: pick the **same Xcode and macOS versions Wockett uses**
   (Claude will tell you which, from Wockett's `docs/ci.md`), not "Latest
   Release". Pinned, a toolchain change is a decision instead of a surprise.
8. **Start Conditions**: delete "Branch Changes". Add **Pull Request
   Changes**: Source any branch, Target `main`, start for any changes. Turn
   **Auto-cancel Builds** on.
9. **Actions**: delete the Archive action. Add **Test**: iOS, scheme
   `<App>`, **Use Scheme Setting**, destination the newest iPhone / Latest
   iOS. Tick **Required to pass**.
10. **Post-Actions**: **Notify → Slack** → `#<app>-ci` → Success and Failure.
11. **Save** → **Next** → **Grant Access** to GitHub. On GitHub, give the
    Xcode Cloud app access to **FreeScoopDev/`<App>`**. Save.
12. Back in Xcode, **Complete**. Don't start a build by hand.

**`Release Flow` (in App Store Connect)**

13. App Store Connect → Apps → `<App>` → **Xcode Cloud** → **Manage
    Workflows** → **+**.
14. Name `Release Flow`. Environment: the same pins as step 7. Clean **On**.
15. Start Conditions: remove the defaults. Add **Manual Start**, restricted to
    branch **`main`**.
16. Actions: **Archive**, iOS, scheme `<App>`, Distribution Preparation
    **TestFlight and App Store**. Check this one twice: "TestFlight (Internal
    Testing Only)" builds can never be submitted for review, which is why
    Wockett 1.11 never reached the App Store.
17. Post-Actions: **TestFlight Internal Testing** → your internal testers.
    **Notify → Slack** → `#<app>-releases` → Success and Failure.
18. **Save**. Don't press Start.
19. Tell Claude: "Xcode Cloud is set up for `<App>`".

## Part 4 — Claude: prove the gate, then require it

1. Opens a small PR (a line in `docs/ci.md`) and checks that
   `<App> | CI Tests | Test - iOS` appears and passes.
2. Proves it gates: a throwaway PR that breaks a unit test on purpose must go
   red on `Test - iOS`. Closes it unmerged. (PlowR did this with #8.)
3. Adds `"<App> | CI Tests | Test - iOS"` to `requiredChecks` in
   `.claude/app.json`, runs `repo-check.sh . --apply`, and confirms with a
   plain `repo-check.sh .` that the repo matches the standard.
4. Fills `docs/ci.md` with the settings chosen in part 3 and the date.

From then on the app runs on `PROCESS.md`, like the others.
