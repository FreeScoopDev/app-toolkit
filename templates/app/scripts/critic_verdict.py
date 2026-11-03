#!/usr/bin/env python3
"""The "Critic verdict" check: a major PR must record the critic's verdict in
its description, and the verdict must not be BLOCK.

Usage: critic_verdict.py <base sha> <head sha> <head branch>
  The PR description comes from the PR_BODY environment variable (the workflow
  passes it through env, never by pasting it into a shell command).

Major, as defined once in .claude/app.json and read by PROCESS.md too: a
`feat/` branch, or more than `criticMinLines` changed lines (added plus
deleted) of Swift outside the test targets (`unitTestTarget`, `uiTestTarget`),
or any change under a `criticPaths` path or glob (consequence, not size).
Swift-only: it counts `*.swift` (plus criticPaths), so a repo with no Swift
relies on criticPaths and the manual verdict instead.
The limit, criticPaths and test targets are read from both the base and the
head of the PR and the stricter wins (lower limit, union of paths, and a test
directory is excluded only if both name it), so a PR cannot loosen its own
gate by editing app.json. The check cannot police an edit to this script
itself; the critic is the control for that (see PROCESS.md).

The verdict is a line such as `**Critic verdict:** APPROVE WITH FINDINGS @ 1a2b3c4`.
HTML comments are removed first, so the PR template's hint text never counts.
The `@ <sha>` must come directly after the verdict kind and names the commit
the critic reviewed (an unambiguous prefix of 7+ hex characters); an `@`
anywhere else in the line is prose. It must be an ancestor of, or equal to,
the PR head, and if code that counts (the Swift and criticPaths rule above)
changed in the PR's own commits after it (a merge of main adds nothing, only
its conflict resolutions do), the check fails: the verdict predates the code.
Docs, release notes and tests after it are fine. A verdict with no sha still passes, with a warning, so
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
MAX_COMMITS = 500  # the stale walk runs git per commit; a verdict this old is stale anyway
SHA = re.compile(r"^(?:APPROVE WITH FINDINGS|APPROVE|BLOCK)\s*@\s*`?([^\s`.,;:)]*)", re.IGNORECASE)


def fail(msg: str, code: int) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def git_ok(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], capture_output=True, text=True)


def parse_numstat(text: str, binary_weight: int) -> dict[str, int]:
    out = {}
    for line in text.splitlines():
        added, deleted, path = line.split("\t", 2)
        out[path] = binary_weight if added == "-" else int(added) + int(deleted)
    return out


def numstat(args: list[str], pathspecs: list[str], binary_weight: int = 1) -> dict[str, int]:
    """Changed lines (added plus deleted) per path from a git diff or show."""
    res = git_ok(*args, "--numstat", "--no-renames", "--format=", "--", *pathspecs)
    if res.returncode != 0:
        fail(f"git {' '.join(args)} failed: {res.stderr.strip()}", 2)
    return parse_numstat(res.stdout, binary_weight)


def valid_paths(paths) -> bool:
    # Plain paths or globs only: an exclude (":!") or other magic pathspec
    # would let a PR carve its own files out of the gate.
    return isinstance(paths, list) and all(isinstance(p, str) and p and not p.startswith(":") for p in paths)


def counted(rev_args: list[str], test_dirs: list[str], critic_paths: list[str],
            swift_binary: int) -> dict[str, int]:
    """The one rule for code that needs a review: Swift outside the test
    targets, plus anything under a criticPaths path. A binary .swift counts
    swift_binary lines (0 for the major test, 1 for the stale count)."""
    out = {p: n for p, n in numstat(rev_args, ["*.swift"], swift_binary).items()
           if not any(p.startswith(d + "/") for d in test_dirs)}
    if critic_paths:
        out.update(numstat(rev_args, critic_paths))
    return out


def own_changed_lines(reviewed: str, head: str, test_dirs: list[str], critic_paths: list[str]) -> int:
    """Counted lines in the PR's own commits after `reviewed`: each plain
    commit against its parent, each merge only by its conflict resolutions
    (--remerge-diff), so merging main in adds nothing of main's."""
    commits = git_ok("rev-list", "--first-parent", f"{reviewed}..{head}").stdout.split()
    if len(commits) > MAX_COMMITS:
        fail(f"The verdict names a commit more than {MAX_COMMITS} commits back; "
             "re-run the critic on the head and record its sha.", 1)
    total = 0
    for c in commits:
        parents = git_ok("rev-list", "--parents", "-n1", c).stdout.split()[1:]
        if len(parents) > 1:
            if git_ok("show", "--remerge-diff", "--format=", c).returncode != 0:
                fail(f"Cannot tell what merge commit {c[:9]} changed (needs git 2.36 or newer). "
                     "Re-run the critic on the current head and record its sha.", 1)
            rev_args = ["show", "--remerge-diff", c]
        else:
            rev_args = ["diff", f"{c}^", c]
        total += sum(counted(rev_args, test_dirs, critic_paths, 1).values())
    return total


def check_reviewed(sha: str, head: str, test_dirs: list[str], critic_paths: list[str]) -> str:
    """Fail unless the verdict's commit is the head or an ancestor with no
    counted code after it. Returns a short note for the pass message."""
    res = git_ok("rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}")
    reviewed = res.stdout.strip()
    # A tag or branch named like a hex prefix resolves too; only a real prefix counts.
    if res.returncode != 0 or not reviewed.startswith(sha):
        fail(f"Critic verdict names commit {sha}, which is not a single commit in this repo "
             "(unknown or ambiguous prefix). Record the sha the critic reported, "
             "e.g. `APPROVE @ 1a2b3c4`.", 1)
    if git_ok("merge-base", "--is-ancestor", reviewed, head).returncode != 0:
        fail(f"Critic verdict names commit {sha}, which is not an ancestor of this PR's head. "
             "Re-run the critic on the current head and record its sha.", 1)
    if reviewed == git_ok("rev-parse", "--verify", f"{head}^{{commit}}").stdout.strip():
        return f"reviewed commit {sha} is the head"
    n = own_changed_lines(reviewed, head, test_dirs, critic_paths)
    if n > 0:
        fail(f"Critic verdict predates {n} changed lines of code after {sha}. "
             "Re-run the critic on the new head and record its sha.", 1)
    return (f"reviewed commit {sha}; no counted code (Swift outside tests, or criticPaths files) "
            "changed since")


def base_config(base: str) -> dict:
    """The base branch's app.json, or {} if it has none or it is unreadable."""
    res = git_ok("show", f"{base}:.claude/app.json")
    try:
        cfg = json.loads(res.stdout) if res.returncode == 0 else {}
    except json.JSONDecodeError:
        return {}
    return cfg if isinstance(cfg, dict) else {}


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
    if not valid_paths(critic_paths):
        fail(".claude/app.json criticPaths must be a list of non-empty plain paths or globs "
             "(no ':' exclude or magic pathspecs)", 2)
    # The stricter of base and head wins, so a PR cannot loosen its own gate.
    old = base_config(base)
    if old:
        old_dirs = [t for t in (old.get("unitTestTarget"), old.get("uiTestTarget")) if isinstance(t, str) and t]
        test_dirs = [t for t in test_dirs if t in old_dirs]
    old_limit = old.get("criticMinLines")
    if isinstance(old_limit, int) and not isinstance(old_limit, bool) and 0 <= old_limit < limit:
        limit = old_limit
    old_paths = old.get("criticPaths", [])
    if valid_paths(old_paths):
        critic_paths = critic_paths + [p for p in old_paths if p not in critic_paths]

    span = f"{base}...{head}"
    lines = sum(counted(["diff", span], test_dirs, [], 0).values())
    reasons = []
    if branch.startswith("feat/"):
        reasons.append("a feat/ branch")
    if critic_paths and numstat(["diff", span], critic_paths):
        for spec in critic_paths:  # one decision above; the loop only names the match
            if numstat(["diff", span], [spec]):
                reasons.append(f"touches critic path {spec}")
    if lines > limit:
        reasons.append(f"{lines} changed lines of Swift outside the test targets (limit {limit})")
    if not reasons:
        print(f"Not major ({lines} changed lines of Swift outside the test targets, limit {limit}; "
              f"branch {branch}; no critic path touched): no critic verdict needed.")
        return

    body = re.sub(r"<!--.*?-->", "", os.environ.get("PR_BODY", ""), flags=re.DOTALL)
    found = [m.group(1).strip().strip("*_` ") for m in VERDICT.finditer(body)]
    found = [v for v in found if v]
    why = " and ".join(reasons)
    if not found:
        fail(f"Major change ({why}), and the PR description has no critic verdict.\n"
             "Run the critic (PROCESS.md, Every change), then add a line like\n"
             "  **Critic verdict:** APPROVE WITH FINDINGS @ <sha the critic reported>\n"
             "Editing the description re-runs this check.", 1)
    raw = found[-1]
    verdict = raw.upper()
    kind = next((k for k in KINDS if verdict.startswith(k)), None)
    if kind is None:
        fail(f"Critic verdict '{verdict}' is not one of {', '.join(KINDS)}.", 1)
    if kind == "BLOCK":
        fail(f"Critic verdict is BLOCK ({why}). Fix every BLOCK finding, re-run the critic, "
             "and record the new verdict.", 1)
    sha_match = SHA.match(raw)  # only an "@" right after the kind; elsewhere it is prose
    if sha_match is None:
        print(f"Major change ({why}); critic verdict: {kind}.\n"
              "::warning::The critic verdict is not tied to a commit, so it may predate the code. "
              f"Record it as `{kind} @ <sha>` using the sha the critic reported.")
        return
    sha = sha_match.group(1).lower()
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        fail(f"Critic verdict '{raw}': '@' must be followed by a commit sha of 7 to 40 hex characters.", 1)
    note = check_reviewed(sha, head, test_dirs, critic_paths)
    print(f"Major change ({why}); critic verdict: {kind}; {note}.")


if __name__ == "__main__":
    main()
