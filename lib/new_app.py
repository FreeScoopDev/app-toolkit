#!/usr/bin/env python3
"""Turn a fresh Xcode project into a FreeScoopDev app repo.

Usage: new_app.py <repo root> <owner/name> [--local-only]

Adds the standard files from templates/app (CLAUDE.md importing PROCESS.md,
CHANGELOG.md, changelog.d/, .claude/app.json, .swiftlint.yml, the scripts/
wrappers, the Linux guards workflow, docs/ci.md), commits them, creates the
public GitHub repo, pushes, and applies the repo standard (repo_settings.py).
--local-only stops after the commit, touching nothing on GitHub.

Everything is checked before anything is written: an existing file is never
overwritten, and a project Xcode Cloud could not build (no shared scheme, no
unit test target) is refused with what to do about it.
"""
import re
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

TOOLKIT = Path(__file__).resolve().parent.parent
TEMPLATES = TOOLKIT / "templates" / "app"
# Stored under another name so they don't act on the toolkit repo itself.
RENAMES = {"gitignore": ".gitignore", "swiftlint.yml": ".swiftlint.yml"}
PLACEHOLDER = re.compile(r"__[A-Z_]+__")


def fail(msg: str) -> None:
    sys.stderr.write(f"new-app: {msg}\n")
    sys.exit(2)


def run(*cmd: str, cwd: Path | None = None) -> str:
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if res.returncode != 0:
        fail(f"{' '.join(cmd)} failed: {res.stderr.strip() or res.stdout.strip()}")
    return res.stdout


def main() -> None:
    args = sys.argv[1:]
    local_only = "--local-only" in args
    args = [a for a in args if a != "--local-only"]
    if len(args) != 2 or "/" not in args[1]:
        fail("usage: new-app.sh <repo root> <owner/name> [--local-only]")
    root = Path(args[0]).expanduser().resolve()
    repo = args[1]
    app = repo.split("/", 1)[1]

    # 1. Is this a project Xcode Cloud can build?
    if not root.is_dir():
        fail(f"{root} is not a folder. Create the project in Xcode first (NEW-APP.md, part 1).")
    projects = sorted(root.glob("*.xcodeproj"))
    if len(projects) != 1:
        fail(f"expected exactly one .xcodeproj in {root}, found {len(projects)}")
    project = projects[0].stem
    schemes = sorted((projects[0] / "xcshareddata" / "xcschemes").glob("*.xcscheme"))
    if not schemes:
        fail("the project has no shared scheme, and Xcode Cloud can only use a shared one. "
             "In Xcode: Product → Scheme → Manage Schemes… → tick Shared next to the app's scheme → Close. "
             "Then run this again.")
    scheme = project if any(s.stem == project for s in schemes) else schemes[0].stem
    unit_tests = f"{project}Tests"
    if not (root / unit_tests).is_dir():
        fail(f"no {unit_tests}/ folder. Create the project with Include Tests ticked "
             f"(or add a Unit Testing Bundle target named {unit_tests}).")

    values = {
        "__APP__": app,
        "__REPO__": repo,
        "__PROJECT__": project,
        "__SCHEME__": scheme,
        "__UNIT_TESTS__": unit_tests,
        "__SLUG__": app.lower(),
        "__DATE__": date.today().isoformat(),
    }

    # 2. Plan every file; refuse before writing anything if one exists.
    plan: list[tuple[Path, Path]] = []
    for src in sorted(p for p in TEMPLATES.rglob("*") if p.is_file()):
        rel = src.relative_to(TEMPLATES)
        dest = root / rel.parent / RENAMES.get(rel.name, rel.name)
        plan.append((src, dest))
    existing = [str(d.relative_to(root)) for _, d in plan if d.exists()]
    if existing:
        fail("these already exist and would be overwritten, so nothing was written: "
             + ", ".join(existing))

    # 3. On GitHub, the repo must not exist yet (checked before any write).
    if not local_only:
        if subprocess.run(["gh", "repo", "view", repo], capture_output=True).returncode == 0:
            fail(f"{repo} already exists on GitHub. Nothing was written.")

    # 4. Write, substituting placeholders; a leftover placeholder is a bug.
    for src, dest in plan:
        text = src.read_text()
        for k, v in values.items():
            text = text.replace(k, v)
        left = PLACEHOLDER.findall(text)
        if left:
            fail(f"{src.relative_to(TEMPLATES)} still has {sorted(set(left))} after substitution")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        shutil.copymode(src, dest)
        print(f"  added {dest.relative_to(root)}")

    # 5. Commit.
    if not (root / ".git").exists():
        run("git", "init", "-q", "-b", "main", cwd=root)
    run("git", "add", "-A", cwd=root)
    run("git", "commit", "-q", "-m", "Start from the FreeScoopDev app template\n\n"
        "Standard files from app-toolkit/templates/app: CLAUDE.md importing the shared\n"
        "PROCESS.md, changelog.d/, .claude/app.json, SwiftLint, script wrappers, the\n"
        "Linux guards workflow and docs/ci.md.", cwd=root)
    print(f"Committed in {root}.")
    if local_only:
        print("--local-only: nothing was created on GitHub.")
        return

    # 6. Publish and protect.
    run("gh", "repo", "create", repo, "--public", "--source", str(root), "--remote", "origin", "--push")
    print(f"Created https://github.com/{repo} and pushed main.")
    res = subprocess.run([sys.executable, str(TOOLKIT / "lib" / "repo_settings.py"), str(root), "--apply"],
                         text=True)
    if res.returncode != 0:
        fail("the repo exists, but applying the standard failed (above). Fix, then run "
             "repo-check.sh --apply again.")
    print("\nNext: NEW-APP.md, part 3 (Joe: App Store Connect and Xcode Cloud).")


if __name__ == "__main__":
    main()
