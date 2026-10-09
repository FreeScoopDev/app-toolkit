#!/usr/bin/env python3
"""Compare an app's GitHub repo with the standard every app uses, and
optionally apply it.

Usage: repo_settings.py <repo root> [--apply]

The standard (agreed 2026-09-27, the setup Wockett and PlowR share):
  - public repo (a free plan enforces rulesets only on public repos, and
    without a required check auto-merge would merge untested code)
  - squash merge only, auto-merge allowed, branch deleted after merge
  - on a public repo, secret scanning and push protection enabled (free on
    public repos; added 2026-10-09). A public repo publishes every commit, so
    a pushed key is leaked the moment it lands: push protection refuses the
    push, and scanning flags what is already there.
  - a ruleset on the default branch, active, with no bypass: no deletion,
    no force-push, changes only by pull request (squash, no approvals needed),
    and exactly the required checks listed in .claude/app.json

The repo and the checks come from <repo>/.claude/app.json ("github",
"requiredChecks"). The expectation is that file, not what GitHub currently
has, so the comparison can fail: it is a check, not a mirror.

Exit 0 when everything matches, 1 on any difference (after --apply: when
anything could not be fixed), 2 on a usage or config problem.
"""
import json
import subprocess
import sys
from pathlib import Path

RULESET_NAME = "Protect main"
REPO_SETTINGS = {
    "allow_auto_merge": True,
    "delete_branch_on_merge": True,
    "allow_squash_merge": True,
    "allow_merge_commit": False,
    "allow_rebase_merge": False,
}

SECURITY = ("secret_scanning", "secret_scanning_push_protection")


def security_patch(info: dict) -> tuple[list[str], dict]:
    """Differences from the security standard, and the PATCH body that fixes
    them. Private repos are exempt: there, these need a paid plan."""
    if info.get("visibility") != "public":
        return [], {}
    have = info.get("security_and_analysis") or {}
    off = [k for k in SECURITY if (have.get(k) or {}).get("status") != "enabled"]
    problems = [f"{k} is {(have.get(k) or {}).get('status', 'not reported')}, should be enabled" for k in off]
    return problems, ({"security_and_analysis": {k: {"status": "enabled"} for k in off}} if off else {})


def fail(msg: str) -> None:
    sys.stderr.write(f"repo_settings: {msg}\n")
    sys.exit(2)


def gh(*args: str, body: dict | None = None) -> object:
    cmd = ["gh", "api", *args]
    if body is not None:
        cmd += ["--input", "-"]
    res = subprocess.run(cmd, input=json.dumps(body) if body is not None else None,
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"gh api {' '.join(args)}: {res.stderr.strip() or res.stdout.strip()}")
    return json.loads(res.stdout) if res.stdout.strip() else None


def ruleset_body(checks: list[str], pins: dict[str, int] | None = None) -> dict:
    """pins keeps the app each existing check is pinned to (integration_id)."""
    pins = pins or {}
    return {
        "name": RULESET_NAME,
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {
                "allowed_merge_methods": ["squash"],
                "required_approving_review_count": 0,
                "dismiss_stale_reviews_on_push": False,
                "require_code_owner_review": False,
                "require_last_push_approval": False,
                "required_review_thread_resolution": False,
            }},
            {"type": "required_status_checks", "parameters": {
                "strict_required_status_checks_policy": False,
                "do_not_enforce_on_create": False,
                "required_status_checks": [{"context": c, **({"integration_id": pins[c]} if c in pins else {})}
                                           for c in checks],
            }},
        ],
    }


def main() -> None:
    args = sys.argv[1:]
    apply = "--apply" in args
    args = [a for a in args if a != "--apply"]
    if len(args) != 1:
        fail("usage: repo_settings.py <repo root> [--apply]")
    path = Path(args[0]) / ".claude" / "app.json"
    try:
        cfg = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read {path}: {e}")
    repo = cfg.get("github")
    checks = cfg.get("requiredChecks")
    if not isinstance(repo, str) or "/" not in repo:
        fail(f'{path} needs "github": "owner/name"')
    if not isinstance(checks, list) or not checks or not all(isinstance(c, str) for c in checks):
        fail(f'{path} needs "requiredChecks": a non-empty list of check names')

    problems: list[str] = []
    warnings: list[str] = []
    fixed: list[str] = []

    info = gh(f"repos/{repo}")
    if info["visibility"] != "public":
        problems.append(f"visibility is {info['visibility']}; the standard is public "
                        "(not changed by --apply: making a repo public is Joe's call)")
    patch = {k: v for k, v in REPO_SETTINGS.items() if info.get(k) != v}
    for k, v in patch.items():
        problems.append(f"{k} is {info.get(k)}, should be {v}")
    if apply and patch:
        gh("-X", "PATCH", f"repos/{repo}", body=patch)
        fixed += [f"set {k} = {v}" for k, v in patch.items()]

    sec_problems, sec_patch = security_patch(info)
    problems += sec_problems
    if apply and sec_patch:
        gh("-X", "PATCH", f"repos/{repo}", body=sec_patch)
        fixed += [f"enabled {k}" for k in sec_patch["security_and_analysis"]]

    try:
        summaries = gh(f"repos/{repo}/rulesets") or []
    except RuntimeError as e:
        if info["visibility"] == "public":
            raise
        # A free plan has no rulesets on a private repo, so main cannot be
        # protected at all. Report that rather than GitHub's upgrade message.
        problems.append(f"no protected main: GitHub offers rulesets on a private repo only on a paid plan ({e})")
        summaries = None
    if summaries is not None:
        check_ruleset(repo, checks, summaries, apply, problems, warnings, fixed)

    report(repo, problems, warnings, fixed, apply)


def check_ruleset(repo: str, checks: list[str], summaries: list, apply: bool,
                  problems: list[str], warnings: list[str], fixed: list[str]) -> None:
    named = [r for r in summaries if r["name"] == RULESET_NAME]
    if not named:
        problems.append(f'no ruleset named "{RULESET_NAME}"')
        if apply:
            gh("-X", "POST", f"repos/{repo}/rulesets", body=ruleset_body(checks))
            fixed.append(f'created ruleset "{RULESET_NAME}" requiring {", ".join(checks)}')
    else:
        rs = gh(f"repos/{repo}/rulesets/{named[0]['id']}")
        rs_problems: list[str] = []
        if rs["enforcement"] != "active":
            rs_problems.append(f"ruleset enforcement is {rs['enforcement']}, should be active")
        if rs.get("bypass_actors"):
            rs_problems.append(f"ruleset has bypass actors: {rs['bypass_actors']}")
        if rs["conditions"]["ref_name"]["include"] != ["~DEFAULT_BRANCH"]:
            rs_problems.append(f"ruleset targets {rs['conditions']['ref_name']['include']}, "
                               "should be the default branch")
        rules = {r["type"]: r.get("parameters") for r in rs["rules"]}
        for t in ("deletion", "non_fast_forward", "pull_request", "required_status_checks"):
            if t not in rules:
                rs_problems.append(f"ruleset is missing the {t} rule")
        pr = rules.get("pull_request") or {}
        if pr and pr.get("allowed_merge_methods") != ["squash"]:
            rs_problems.append(f"pull requests may merge by {pr.get('allowed_merge_methods')}, should be squash only")
        if pr and pr.get("required_approving_review_count", 0) != 0:
            rs_problems.append("pull requests need approving reviews, which would stop auto-merge")
        status = rules.get("required_status_checks") or {}
        have = [c["context"] for c in status.get("required_status_checks", [])]
        if sorted(have) != sorted(checks):
            missing = sorted(set(checks) - set(have))
            extra = sorted(set(have) - set(checks))
            if missing:
                rs_problems.append(f"required checks missing: {', '.join(missing)}")
            if extra:
                rs_problems.append(f"required checks not in app.json: {', '.join(extra)}")
        unpinned = [c["context"] for c in status.get("required_status_checks", [])
                    if "integration_id" not in c]
        if unpinned:
            warnings.append("any app may report these checks (no source pinned): "
                            + ", ".join(unpinned))
        problems += rs_problems
        if apply and rs_problems:
            pins = {c["context"]: c["integration_id"] for c in status.get("required_status_checks", [])
                    if "integration_id" in c}
            gh("-X", "PUT", f"repos/{repo}/rulesets/{rs['id']}", body=ruleset_body(checks, pins))
            fixed.append(f'rewrote ruleset "{RULESET_NAME}" to the standard')



def report(repo: str, problems: list[str], warnings: list[str], fixed: list[str], apply: bool) -> None:
    print(f"{repo}: {'matches the standard' if not problems else f'{len(problems)} difference(s)'}")
    for p in problems:
        print(f"  DIFF  {p}")
    for w in warnings:
        print(f"  WARN  {w}")
    for f in fixed:
        print(f"  FIXED {f}")
    unfixed = [p for p in problems if "not changed by --apply" in p or "no protected main" in p] if apply else problems
    sys.exit(1 if unfixed else 0)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        fail(str(e))
