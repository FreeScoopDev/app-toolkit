#!/usr/bin/env bash
#
# The toolkit's own check, run on every PR by .github/workflows/selftest.yml
# and required on main. Needs only bash, python3 and git, so it runs on Linux.
# Every "must refuse" case asserts the exact exit code AND that nothing was
# written, so a script that silently does nothing cannot pass.
set -euo pipefail
K="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.com
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.com
FAILS=0
ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
fake() { # fake <dir> <name> [noscheme]
  mkdir -p "$1/$2.xcodeproj" "$1/$2Tests" "$1/$2"
  if [[ "${3:-}" != noscheme ]]; then
    mkdir -p "$1/$2.xcodeproj/xcshareddata/xcschemes"; touch "$1/$2.xcodeproj/xcshareddata/xcschemes/$2.xcscheme"
  fi
}
snapshot() { # every path with its size, modification time and content hash
  python3 - "$1" <<'PY'
import hashlib, os, sys
for dp, dns, fns in sorted(os.walk(sys.argv[1])):
    dns.sort()
    for n in sorted(fns):
        p = os.path.join(dp, n); st = os.lstat(p)
        h = hashlib.sha1(open(p, "rb").read()).hexdigest() if os.path.isfile(p) and not os.path.islink(p) else "-"
        print(p, st.st_size, st.st_mtime_ns, h)
    print(dp, "dir")
PY
}
refuses() { # refuses <label> <dir> <cmd...>: exit 2 and the folder untouched (names, contents, times)
  local label=$1 dir=$2; shift 2
  local before after code=0
  before=$(snapshot "$dir")
  "$@" >/dev/null 2>&1 || code=$?
  after=$(snapshot "$dir")
  if [[ $code -eq 2 && "$before" == "$after" ]]; then ok "$label"; else bad "$label (exit $code, changed: $([[ $before == "$after" ]] && echo no || echo yes))"; fi
}

# Syntax.
for f in "$K"/bin/*.sh "$K"/templates/app/scripts/*.sh "$K"/tests/*.sh; do
  bash -n "$f" || bad "bash syntax: $f"
done
python3 -m py_compile "$K"/lib/*.py && ok "python compiles"

# new-app on a well-formed project.
fake "$T/Kiln" Kiln
if "$K/bin/new-app.sh" "$T/Kiln" FreeScoopDev/Kiln --local-only >/dev/null; then ok "new-app accepts a well-formed project"
else bad "new-app on a well-formed project (the checks that need its output are skipped)"; echo; echo "$FAILS check(s) failed"; exit 1; fi
COMMITTED=$(git -C "$T/Kiln" show --name-only --format= HEAD 2>/dev/null || true)
MISSING=0; N=0
while IFS= read -r f; do
  N=$((N + 1)); d=$(dirname "$f"); b=$(basename "$f")
  case "$b" in gitignore) b=.gitignore ;; swiftlint.yml) b=.swiftlint.yml ;; esac
  [[ "$d" == . ]] && want="$b" || want="$d/$b"
  grep -qxF "$want" <<<"$COMMITTED" || { MISSING=$((MISSING + 1)); echo "      not committed: $want"; }
done < <(cd "$K/templates/app" && find . -type f | sed 's#^\./##')
[[ $MISSING -eq 0 && $N -gt 0 ]] && ok "commit has all $N template files" || bad "$MISSING of $N template files not committed"
if grep -rnE "__[A-Z_]+__" "$T/Kiln" --exclude-dir=.git; then bad "placeholders left in generated files"; else ok "no placeholders left"; fi
python3 "$K/lib/app_config.py" "$T/Kiln" >/dev/null && ok "generated app.json reads" || bad "generated app.json rejected"
ACTUAL=$(awk '/^excluded:/{f=1;next} /^[^ -]/{f=0} f&&/^ *- /{gsub(/^ *- */,"");print}' "$T/Kiln/.swiftlint.yml" | sort | tr '\n' ' ')
EXPECTED=$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["lintExcluded"]))+" ")' "$T/Kiln/.claude/app.json")
[[ "$ACTUAL" == "$EXPECTED" ]] && ok "lint exclusions agree ($ACTUAL)" || bad "lint exclusions differ: yml '$ACTUAL' vs app.json '$EXPECTED'"
for s in test lint ci_pick_simulator; do [[ -x "$T/Kiln/scripts/$s.sh" ]] || bad "scripts/$s.sh not executable"; done

# new-app must refuse, writing nothing.
refuses "new-app refuses a second run" "$T/Kiln" "$K/bin/new-app.sh" "$T/Kiln" FreeScoopDev/Kiln --local-only
fake "$T/Brine" Brine noscheme
refuses "new-app refuses a project with no shared scheme" "$T/Brine" "$K/bin/new-app.sh" "$T/Brine" FreeScoopDev/Brine --local-only
mkdir -p "$T/Nope/Nope.xcodeproj/xcshareddata/xcschemes"; touch "$T/Nope/Nope.xcodeproj/xcshareddata/xcschemes/Nope.xcscheme"
refuses "new-app refuses a project with no tests" "$T/Nope" "$K/bin/new-app.sh" "$T/Nope" FreeScoopDev/Nope --local-only

# Config validation (no network needed: these fail before any gh call).
mkdir -p "$T/cfg/.claude"
echo '{}' > "$T/cfg/.claude/app.json"
refuses "repo-check refuses a config with no github/requiredChecks" "$T/cfg" "$K/bin/repo-check.sh" "$T/cfg"
refuses "app_config refuses missing required keys" "$T/cfg" python3 "$K/lib/app_config.py" "$T/cfg"
python3 - "$T/Kiln/.claude/app.json" "$T/cfg/.claude/app.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["requiredCheck"] = ["typo"]; json.dump(d, open(sys.argv[2], "w"))
PY
refuses "app_config refuses an unknown key" "$T/cfg" python3 "$K/lib/app_config.py" "$T/cfg"

# Agents: each file must parse as an agent Claude Code will load, with its
# name matching the file (a mismatch or missing field loses the agent silently).
if out=$(python3 - "$K/agents" <<'PY'
import pathlib, sys
bad = []
files = sorted(pathlib.Path(sys.argv[1]).glob("*.md"))
if not files:
    bad.append("no agents found")
for f in files:
    text = f.read_text()
    if not text.startswith("---\n") or "\n---\n" not in text[4:]:
        bad.append(f"{f.name}: no frontmatter"); continue
    head, body = text[4:].split("\n---\n", 1)
    meta = dict(line.split(":", 1) for line in head.splitlines() if ":" in line and not line.startswith(" "))
    meta = {k.strip(): v.strip() for k, v in meta.items()}
    if meta.get("name") != f.stem:
        bad.append(f"{f.name}: name is {meta.get('name')!r}, should be {f.stem!r}")
    for key in ("description", "tools"):
        if not meta.get(key):
            bad.append(f"{f.name}: no {key}")
    if len(body.strip()) < 200:
        bad.append(f"{f.name}: body is nearly empty")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
); then ok "agents: $(ls "$K"/agents/*.md | wc -l | tr -d ' ') files, each loadable"; else bad "agents: $out"; fi

echo
if [[ $FAILS -gt 0 ]]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "All checks passed."
