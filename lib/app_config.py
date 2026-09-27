#!/usr/bin/env python3
"""Read <repo>/.claude/app.json and print it as shell assignments.

Usage: app_config.py <repo root>
Prints lines like  APP_NAME='PlowR'  that the toolkit scripts `eval`.
Every value is shell-quoted here, so a config can never inject a command.

Fails loudly (exit 2) on a missing file, bad JSON, a missing required key or
an unknown key. An unknown key is almost always a typo, and a typo in an
optional key would otherwise be silently ignored.
"""
import json
import shlex
import sys
from pathlib import Path

REQUIRED = {"app", "project", "scheme", "unitTestTarget", "lintExcluded"}
OPTIONAL = {"uiTestTarget", "xcodebuildExtraArgs", "versionSource", "reviewFocus", "notes",
            "github", "requiredChecks"}


def fail(msg: str) -> None:
    sys.stderr.write(f"app.json: {msg}\n")
    sys.exit(2)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: app_config.py <repo root>")
    path = Path(sys.argv[1]) / ".claude" / "app.json"
    if not path.is_file():
        fail(f"not found at {path}. Each repo using the toolkit needs one.")
    try:
        cfg = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        fail(f"invalid JSON in {path}: {e}")

    missing = REQUIRED - cfg.keys()
    if missing:
        fail(f"missing required keys: {', '.join(sorted(missing))}")
    unknown = cfg.keys() - REQUIRED - OPTIONAL
    if unknown:
        fail(f"unknown keys (typo?): {', '.join(sorted(unknown))}")

    extra = cfg.get("xcodebuildExtraArgs", [])
    excluded = cfg["lintExcluded"]
    if not isinstance(extra, list) or not isinstance(excluded, list):
        fail("xcodebuildExtraArgs and lintExcluded must be lists")

    q = shlex.quote
    print(f"APP_NAME={q(cfg['app'])}")
    print(f"APP_PROJECT={q(cfg['project'])}")
    print(f"APP_SCHEME={q(cfg['scheme'])}")
    print(f"APP_UNIT_TARGET={q(cfg['unitTestTarget'])}")
    print(f"APP_UI_TARGET={q(cfg.get('uiTestTarget') or '')}")
    # Bash arrays, so each extra argument stays one argument.
    print("APP_XCODEBUILD_EXTRA=(" + " ".join(q(a) for a in extra) + ")")
    print("APP_LINT_EXCLUDED=(" + " ".join(q(a) for a in excluded) + ")")


if __name__ == "__main__":
    main()
