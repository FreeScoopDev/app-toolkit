#!/usr/bin/env python3
"""The "Critic verdict" check: a major PR must record the critic's verdict in
its description, and the verdict must not be BLOCK.

Usage: critic_verdict.py <base sha> <head sha> <head branch>
  The PR description comes from the PR_BODY environment variable (the workflow
  passes it through env, never by pasting it into a shell command).

Major, as defined once in .claude/app.json and read by PROCESS.md too: a
`feat/` branch, or more than `criticMinLines` changed lines (added plus
deleted) of Swift outside the test targets (`unitTestTarget`, `uiTestTarget`),
or any change under a `criticPaths` pathspec (consequence, not size).

The verdict is a line such as `**Critic verdict:** APPROVE WITH FINDINGS @ 1a2b3c4`.
HTML comments are removed first, so the PR template's hint text never counts.
The `@ <sha>` names the commit the critic reviewed (any unambiguous prefix of
7+ hex characters). It must be an ancestor of, or equal to, the PR head, and
if code that counts (the Swift and criticPaths rule above) changed after it,
the check fails: the verdict predates the code. Docs, release notes and tests
after it are fine. A verdict with no sha still passes, with a warning, so
older PR descriptions and templates keep working.
This proves a verdict was recorded for this code, not that the review was good.

Exit 0 pass, 1 fail, 2 a usage or config problem. Runs in CI on Linux; it
needs only python3 and git, never the toolkit.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

VERDICT = re.compile(r"^[\s>*_-]*critic verdict[\s*_]*:[\s*_]*(.*)$", re.IGNORECASE | re.MULTILINE)
KINDS = ("APPROVE WITH FINDINGS", "APPROVE", "BLOCK")
SHA = re.compile(r"@\s*(\S*)")


def fail(msg: str, code: int) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def numstat(span: str, pathspecs: list[str]) -> dict[str, int]:
    """Changed lines (added plus deleted) per path for a git diff range."""
    res = subprocess.run(["git", "diff", "--numstat", "--no-renames", span, "--", *pathspecs],
                         capture_output=True, text=True)
    if res.returncode != 0:
        fail(f"git diff {span} failed: {res.stderr.strip()}", 2)
    out = {}
    for line in res.stdout.splitlines():
        added, deleted, path = line.split("\t", 2)
        out[path] = 1 if added == "-" else int(added) + int(deleted)  # "-" is a binary file
    return out


def swift_lines(span: str, test_dirs: list[str]) -> dict[str, int]:
    return {p: n for p, n in numstat(span, ["*.swift"]).items()
            if not any(p.startswith(d + "/") for d in test_dirs)}


def counted_lines(span: str, test_dirs: list[str], critic_paths: list[str]) -> int:
    """The one rule for code that needs a review: Swift outside the test
    targets, plus anything under a criticPaths pathspec."""
    counted = swift_lines(span, test_dirs)
    if critic_paths:
        counted.update(numstat(span, critic_paths))
    return sum(counted.values())


def git_ok(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], capture_output=True, text=True)


def check_reviewed(sha: str, head: str, test_dirs: list[str], critic_paths: list[str]) -> str:
    """Fail unless the verdict's commit is the head or an ancestor with no
    counted code after it. Returns a short note for the pass message."""
    res = git_ok("rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}")
    if res.returncode != 0:
        fail(f"Critic verdict names commit {sha}, which is not a single commit in this repo "
             "(unknown or ambiguous prefix). Record the sha the critic reported, "
             "e.g. `APPROVE @ 1a2b3c4`.", 1)
    reviewed = res.stdout.strip()
    if git_ok("merge-base", "--is-ancestor", reviewed, head).returncode != 0:
        fail(f"Critic verdict names commit {sha}, which is not an ancestor of this PR's head. "
             "Re-run the critic on the current head and record its sha.", 1)
    if reviewed == git_ok("rev-parse", "--verify", f"{head}^{{commit}}").stdout.strip():
        return f"reviewed commit {sha} is the head"
    n = counted_lines(f"{reviewed}..{head}", test_dirs, critic_paths)
    if n > 0:
        fail(f"Critic verdict predates {n} changed lines of code after {sha}. "
             "Re-run the critic on the new head and record its sha.", 1)
    return f"reviewed commit {sha}; only docs, notes or tests changed since"


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: critic_verdict.py <base sha> <head sha> <head branch>", 2)
    base, head, branch = sys.argv[1:]
    try:
        cfg = json.loads(Path(".claude/app.json").read_text())
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read .claude/app.json: {e}", 2)
    limit = cfg.get("criticMinLines")
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
        fail(".claude/app.json needs criticMinLines, a whole number of lines (the template starts at 40)", 2)
    test_dirs = [t for t in (cfg.get("unitTestTarget"), cfg.get("uiTestTarget")) if t]
    critic_paths = cfg.get("criticPaths", [])
    if not isinstance(critic_paths, list) or not all(isinstance(p, str) and p for p in critic_paths):
        fail(".claude/app.json criticPaths must be a list of non-empty git pathspecs", 2)

    lines = sum(swift_lines(f"{base}...{head}", test_dirs).values())
    reasons = []
    if branch.startswith("feat/"):
        reasons.append("a feat/ branch")
    for spec in critic_paths:
        if numstat(f"{base}...{head}", [spec]):
            reasons.append(f"touches critic path {spec}")
    if lines > limit:
        reasons.append(f"{lines} changed lines of Swift outside the test targets (limit {limit})")
    if not reasons:
        print(f"Not major ({lines} changed lines of Swift outside the test targets, limit {limit}; "
              f"branch {branch}; no critic path touched): no critic verdict needed.")
        return

    body = re.sub(r"<!--.*?-->", "", os.environ.get("PR_BODY", ""), flags=re.DOTALL)
    found = [m.group(1).strip().strip("*_` ").upper() for m in VERDICT.finditer(body)]
    found = [v for v in found if v]
    why = " and ".join(reasons)
    if not found:
        fail(f"Major change ({why}), and the PR description has no critic verdict.\n"
             "Run the critic (PROCESS.md, Every change), then add a line like\n"
             "  **Critic verdict:** APPROVE WITH FINDINGS @ <sha the critic reported>\n"
             "Editing the description re-runs this check.", 1)
    verdict = found[-1]
    sha_match = SHA.search(verdict)
    kind = next((k for k in KINDS if verdict.startswith(k)), None)
    if kind is None:
        fail(f"Critic verdict '{verdict}' is not one of {', '.join(KINDS)}.", 1)
    if kind == "BLOCK":
        fail(f"Critic verdict is BLOCK ({why}). Fix every BLOCK finding, re-run the critic, "
             "and record the new verdict.", 1)
    if sha_match is None:
        print(f"Major change ({why}); critic verdict: {kind}.\n"
              "WARNING: the verdict is not tied to a commit, so it may predate the code. "
              f"Record it as `{kind} @ <sha>` using the sha the critic reported.")
        return
    sha = sha_match.group(1).lower()
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        fail(f"Critic verdict '{verdict}': '@' must be followed by a commit sha of 7 to 40 hex characters.", 1)
    note = check_reviewed(sha, head, test_dirs, critic_paths)
    print(f"Major change ({why}); critic verdict: {kind}; {note}.")


if __name__ == "__main__":
    main()
