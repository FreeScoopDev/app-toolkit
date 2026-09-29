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

# Session-start hook: silent when current, loud when behind, harmless elsewhere.
git init -q -b main "$T/hook-origin" 2>/dev/null || { git init -q "$T/hook-origin"; git -C "$T/hook-origin" checkout -q -b main; }
( cd "$T/hook-origin" && printf 'rules v1\n' > CLAUDE.md && git add CLAUDE.md && git commit -qm one )
git clone -q "$T/hook-origin" "$T/hook-joe"
out=$(printf '{"cwd":"%s","session_start_reason":"startup"}' "$T/hook-joe" | "$K/bin/session-start.sh")
[[ -z "$out" ]] && ok "session-start is silent when the checkout is current" || bad "session-start spoke when current: $out"
( cd "$T/hook-origin" && printf 'rules v2\n' > CLAUDE.md && git commit -qam two )
out=$(printf '{"cwd":"%s","session_start_reason":"startup"}' "$T/hook-joe" | "$K/bin/session-start.sh")
if grep -q '^STALE CHECKOUT: .* 1 commit(s) behind' <<<"$out" && grep -qx 'rules v2' <<<"$out"; then ok "session-start prints origin/main's CLAUDE.md when behind"
else bad "session-start missed a stale checkout: $out"; fi
( cd "$T/hook-origin" && printf 'rules v2\n' > CLAUDE.md && printf 'x\n' > other && git add other && git commit -qm three )
git -C "$T/hook-joe" -c advice.detachedHead=false pull -q --ff-only origin main 2>/dev/null; ( cd "$T/hook-joe" && git reset -q --hard HEAD~1 )
out=$(printf '{"cwd":"%s"}' "$T/hook-joe" | "$K/bin/session-start.sh")
if grep -q 'STALE CHECKOUT' <<<"$out" && grep -q 'matches origin/main' <<<"$out" && ! grep -q 'end of CLAUDE.md' <<<"$out"; then ok "session-start does not reprint an unchanged CLAUDE.md"
else bad "session-start on a behind checkout with the same CLAUDE.md: $out"; fi
out=$(printf '{"cwd":"%s"}' "$T" | "$K/bin/session-start.sh"); [[ -z "$out" ]] && ok "session-start is silent outside a repo" || bad "session-start spoke outside a repo: $out"
if printf 'not json' | "$K/bin/session-start.sh" >/dev/null; then ok "session-start exits 0 on bad input"; else bad "session-start failed on bad input"; fi

# Session-start deletes leftover test clones: shut down and over two hours
# old only, silently. A fake xcrun lists four devices and logs deletes.
H="$T/clone-home"; D="$H/Library/Developer/XCTestDevices"; mkdir -p "$T/fakebin" "$D"
for u in OLD NEW BOOTED SRC; do mkdir -p "$D/$u"; done
python3 -c 'import os, sys, time
t = time.time() - 3 * 3600
for u in ("OLD", "BOOTED", "SRC"): os.utime(os.path.join(sys.argv[1], u), (t, t))' "$D"
cat > "$T/fakebin/xcrun" <<FAKE
#!/usr/bin/env bash
if [[ "\$*" == "simctl --set testing list devices -j" ]]; then
  echo '{"devices":{"iOS-26-5":[{"udid":"OLD","name":"Clone 2 of iPhone 17","state":"Shutdown"},{"udid":"NEW","name":"Clone 2 of iPhone 17","state":"Shutdown"},{"udid":"BOOTED","name":"Clone 1 of iPhone 17","state":"Booted"},{"udid":"SRC","name":"iPhone 17","state":"Shutdown"}]}}'
elif [[ "\$1 \$2 \$3 \$4" == "simctl --set testing delete" ]]; then
  echo "\$5" >> "$T/deleted.log"
fi
FAKE
chmod +x "$T/fakebin/xcrun"
out=$(printf '{"cwd":"%s"}' "$T" | HOME="$H" PATH="$T/fakebin:$PATH" "$K/bin/session-start.sh")
if [[ -z "$out" && "$(cat "$T/deleted.log" 2>/dev/null)" == "OLD" ]]; then ok "session-start deletes only old, shut-down test clones, silently"
else bad "session-start clone clean-up: output '$out', deleted '$(cat "$T/deleted.log" 2>/dev/null | tr '\n' ' ')'"; fi

# install-hooks: one entry, idempotent, nothing else touched.
printf '{"permissions":{"allow":["Read(x)"]}}\n' > "$T/settings.json"
CLAUDE_SETTINGS_FILE="$T/settings.json" TOOLKIT_HOME="$K" "$K/bin/install-hooks.sh" >/dev/null
CLAUDE_SETTINGS_FILE="$T/settings.json" TOOLKIT_HOME="$K" "$K/bin/install-hooks.sh" >/dev/null
if python3 - "$T/settings.json" "$K" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for e in d["hooks"]["SessionStart"] for h in e["hooks"]]
assert cmds == [sys.argv[2] + "/bin/session-start.sh"], cmds
assert d["permissions"] == {"allow": ["Read(x)"]}, d
PY
then ok "install-hooks adds one SessionStart hook and keeps the rest"; else bad "install-hooks: wrong result in $T/settings.json"; fi

# release-build-check: match, a build past the release, a build behind it, one off the line.
git init -q -b main "$T/rel-origin" 2>/dev/null || { git init -q "$T/rel-origin"; git -C "$T/rel-origin" checkout -q -b main; }
( cd "$T/rel-origin" && printf 'a\n' > f && git add f && git commit -qm "feature" )
FEATURE=$(git -C "$T/rel-origin" rev-parse HEAD)
( cd "$T/rel-origin" && printf 'r\n' > f && git commit -qam "Release 1.0 (#9)" )
REL=$(git -C "$T/rel-origin" rev-parse HEAD)
( cd "$T/rel-origin" && printf 'b\n' > f && git commit -qam "after the cut (#10)" )
LATER=$(git -C "$T/rel-origin" rev-parse HEAD)
# A branch cut BEFORE the release: neither commit is an ancestor of the other.
( cd "$T/rel-origin" && git checkout -q -b side "$FEATURE" && printf 's\n' > f && git commit -qam "side" && git checkout -q main )
SIDE=$(git -C "$T/rel-origin" rev-parse side)
git clone -q "$T/rel-origin" "$T/rel-joe"
if out=$("$K/bin/release-build-check.sh" "$T/rel-joe" "${REL:0:7}" --merge-commit "$REL") && grep -q '^OK:' <<<"$out"; then ok "release-build-check accepts the release commit (short sha)"; else bad "release-build-check rejected the release commit: $out"; fi
if out=$("$K/bin/release-build-check.sh" "$T/rel-joe" "$LATER" --merge-commit "$REL"); then bad "release-build-check accepted a build past the release"; else
  if grep -q '^MISMATCH' <<<"$out" && grep -q '1 commit(s) after' <<<"$out" && grep -q 'after the cut (#10)' <<<"$out"; then ok "release-build-check names the commits a later build carries"; else bad "release-build-check mismatch output: $out"; fi; fi
if out=$("$K/bin/release-build-check.sh" "$T/rel-joe" "$REL" --merge-commit "$LATER"); then bad "release-build-check accepted a build older than the release"; else
  grep -q 'OLDER' <<<"$out" && ok "release-build-check says when the build is older than the release" || bad "release-build-check older-build output: $out"; fi
git -C "$T/rel-joe" fetch -q origin side; if out=$("$K/bin/release-build-check.sh" "$T/rel-joe" "$SIDE" --merge-commit "$REL"); then bad "release-build-check accepted a build off the line"; else
  grep -q 'not on the release commit' <<<"$out" && ok "release-build-check says when the build is off the line" || bad "release-build-check off-line output: $out"; fi
code=0; "$K/bin/release-build-check.sh" "$T/rel-joe" "$REL" --bogus >/dev/null 2>&1 || code=$?; [[ $code -eq 2 ]] && ok "release-build-check refuses an unknown option" || bad "release-build-check unknown option exit $code"

echo
if [[ $FAILS -gt 0 ]]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "All checks passed."
