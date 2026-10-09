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
# Templates: compiled in memory, since a __pycache__ there would be copied into every new app.
for f in "$K"/templates/app/scripts/*.py; do
  python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$f" || bad "python syntax: $f"
done

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
for v in '"40"' -1 true; do
  python3 - "$T/Kiln/.claude/app.json" "$T/cfg/.claude/app.json" "$v" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["criticMinLines"] = json.loads(sys.argv[3]); json.dump(d, open(sys.argv[2], "w"))
PY
  refuses "app_config refuses criticMinLines $v" "$T/cfg" python3 "$K/lib/app_config.py" "$T/cfg"
done

# Critic verdict check (templates/app/scripts/critic_verdict.py), run as CI
# runs it: from the generated repo's root, against a base and head commit.
# Kiln's app.json has criticMinLines 40 and unit test target KilnTests.
CV_BASE=$(git -C "$T/Kiln" rev-parse HEAD)
cv() { # cv <label> <want exit> <file> <lines> <branch> [body]
  local label=$1 want=$2 file=$3 n=$4 branch=$5 body=${6:-} code=0 head out
  git -C "$T/Kiln" checkout -q --detach "$CV_BASE"
  mkdir -p "$T/Kiln/$(dirname "$file")"; seq "$n" | sed 's/^/let x = /' > "$T/Kiln/$file"
  git -C "$T/Kiln" add -A && git -C "$T/Kiln" commit -qm cv
  head=$(git -C "$T/Kiln" rev-parse HEAD)
  out=$(cd "$T/Kiln" && PR_BODY=$body python3 scripts/critic_verdict.py "$CV_BASE" "$head" "$branch" 2>&1) || code=$?
  if [[ $code -eq $want ]]; then ok "critic verdict: $label"; else bad "critic verdict: $label (exit $code, wanted $want): $out"; fi
}
TEMPLATE_BODY=$(cat "$T/Kiln/.github/pull_request_template.md")
cv "small fix/ change needs no verdict" 0 Kiln/A.swift 40 fix/small
cv "41 lines of Swift is major" 1 Kiln/A.swift 41 fix/big
cv "Swift in the test target does not count" 0 KilnTests/ATests.swift 200 test/more
cv "a feat/ branch is major with one line" 1 Kiln/A.swift 1 feat/x "No verdict here."
cv "the template's hint text is not a verdict" 1 Kiln/A.swift 1 feat/x "$TEMPLATE_BODY"
FILLED_BODY=$(sed 's/^\*\*Critic verdict:\*\* /&APPROVE WITH FINDINGS /' <<<"$TEMPLATE_BODY")
[[ "$FILLED_BODY" != "$TEMPLATE_BODY" ]] || bad "the PR template has no '**Critic verdict:** ' line to fill"
cv "APPROVE WITH FINDINGS on the template's line passes" 0 Kiln/A.swift 99 feat/x "$FILLED_BODY"
cv "a verdict inside an HTML comment does not count" 1 Kiln/A.swift 99 feat/x $'<!--\nCritic verdict: APPROVE\n-->'
cv "BLOCK fails" 1 Kiln/A.swift 99 feat/x "**Critic verdict:** BLOCK"
cv "a verdict that is not one of the three fails" 1 Kiln/A.swift 99 feat/x "Critic verdict: looks fine"
cv "the last verdict line counts" 0 Kiln/A.swift 99 feat/x $'Critic verdict: BLOCK\nCritic verdict: **APPROVE**'
git -C "$T/Kiln" checkout -q --detach "$CV_BASE"
python3 - "$T/Kiln/.claude/app.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d["criticMinLines"]; json.dump(d, open(sys.argv[1], "w"))
PY
cv "no criticMinLines in app.json is a config error" 2 Kiln/A.swift 1 fix/x
git -C "$T/Kiln" checkout -q -- .claude/app.json 2>/dev/null || true
git -C "$T/Kiln" checkout -q --detach "$CV_BASE"

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

# Session-start empties the simulators' Dead folders of what is over two
# hours old, and nothing else, silently.
DD="$H/Library/Developer/CoreSimulator/Devices/SIM1/data/Library/Caches/com.apple.containermanagerd/Dead"
mkdir -p "$DD/temp.OLD/X/App.app" "$DD/temp.NEW/X/App.app" "$DD/keep"
python3 -c 'import os, sys, time
t = time.time() - 3 * 3600
for u in ("temp.OLD", "keep"): os.utime(os.path.join(sys.argv[1], u), (t, t))' "$DD"
out=$(printf '{"cwd":"%s"}' "$T" | HOME="$H" PATH="$T/fakebin:$PATH" "$K/bin/session-start.sh")
if [[ -z "$out" && ! -e "$DD/temp.OLD" && -d "$DD/temp.NEW" && -d "$DD/keep" ]]; then ok "session-start empties only old entries of the simulators' Dead folders, silently"
else bad "session-start Dead clean-up: output '$out', left: $(ls "$DD" | tr '\n' ' ')"; fi

# install-hooks: one entry, idempotent, nothing else touched.
printf '{"permissions":{"allow":["Read(x)"]}}\n' > "$T/settings.json"
CLAUDE_SETTINGS_FILE="$T/settings.json" TOOLKIT_HOME="$K" "$K/bin/install-hooks.sh" >/dev/null
CLAUDE_SETTINGS_FILE="$T/settings.json" TOOLKIT_HOME="$K" "$K/bin/install-hooks.sh" >/dev/null
if python3 - "$T/settings.json" "$K" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for e in d["hooks"]["SessionStart"] for h in e["hooks"]]
assert cmds == [sys.argv[2] + "/bin/session-start.sh"], cmds
post = d["hooks"]["PostToolUse"]
assert [(e["matcher"], [h["command"] for h in e["hooks"]]) for e in post] == \
    [("Edit|Write", [sys.argv[2] + "/bin/lint-hook.sh"])], post
assert d["permissions"] == {"allow": ["Read(x)"]}, d
PY
then ok "install-hooks adds one SessionStart and one PostToolUse hook and keeps the rest"; else bad "install-hooks: wrong result in $T/settings.json"; fi
# A settings file from before the lint hook (SessionStart only) gains the lint hook, once.
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/bin/session-start.sh","timeout":30}]}]}}\n' "$K" > "$T/settings-old.json"
CLAUDE_SETTINGS_FILE="$T/settings-old.json" TOOLKIT_HOME="$K" "$K/bin/install-hooks.sh" >/dev/null
CLAUDE_SETTINGS_FILE="$T/settings-old.json" TOOLKIT_HOME="$K" "$K/bin/install-hooks.sh" >/dev/null
if python3 - "$T/settings-old.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["hooks"]
assert len(d["SessionStart"]) == 1 and len(d["PostToolUse"]) == 1, d
PY
then ok "install-hooks upgrades a SessionStart-only file without duplicating"; else bad "install-hooks upgrade: $(cat "$T/settings-old.json")"; fi

# lint-hook: a fake swiftlint records where and how it was called, so this
# runs on Linux. The hook must lint only .swift files in a repo with a
# .swiftlint.yml, from the repo root, with --force-exclude and never --fix,
# hand violations over as additionalContext, and exit 0 on every path.
mkdir -p "$T/fakebin" "$T/nolint"
cat > "$T/fakebin/swiftlint" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_SWIFTLINT_LOG"
[[ -n "${FAKE_SWIFTLINT_CRASH:-}" ]] && { echo "Fatal error: boom" >&2; exit 3; }
[[ -n "${FAKE_SWIFTLINT_CLEAN:-}" ]] && exit 0
echo "${@: -1}:3:9: error: Force Unwrapping Violation: Force unwrapping should be avoided (force_unwrapping)"
exit 2
SH
chmod +x "$T/fakebin/swiftlint"
mkdir -p "$T/Kiln/Kiln" && echo 'let a = b!' > "$T/Kiln/Kiln/Lint.swift" && echo 'x' > "$T/Kiln/notes.md"
git init -q "$T/nolint" && echo 'let a = b!' > "$T/nolint/A.swift" && mkdir -p "$T/outside" && echo 'let a = b!' > "$T/outside/A.swift"
export FAKE_SWIFTLINT_LOG="$T/swiftlint.log"
lh() { # lh <file> [env...]: runs the hook from $T with an Edit event for <file>; sets LH_OUT, LH_CODE
  local f=$1; shift; LH_CODE=0; : > "$FAKE_SWIFTLINT_LOG"
  LH_OUT=$(cd "$T" && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$f" "$T" \
    | env PATH="$T/fakebin:$PATH" "$@" "$K/bin/lint-hook.sh" 2>&1) || LH_CODE=$?
}
lh "$T/Kiln/Kiln/Lint.swift"
if [[ $LH_CODE -eq 0 ]] && python3 - "$LH_OUT" <<'PY'
import json, sys
o = json.loads(sys.argv[1])["hookSpecificOutput"]
assert o["hookEventName"] == "PostToolUse", o
assert "Kiln/Lint.swift:3:9: error: Force Unwrapping Violation" in o["additionalContext"], o
assert "decision" not in json.loads(sys.argv[1])
PY
then ok "lint-hook hands a violation to Claude as context"; else bad "lint-hook on a violation (exit $LH_CODE): $LH_OUT"; fi
CALL=$(cat "$FAKE_SWIFTLINT_LOG")
if [[ "$CALL" == "$(cd "$T/Kiln" && pwd -P)|lint --quiet --force-exclude -- Kiln/Lint.swift" || "$CALL" == "$T/Kiln|lint --quiet --force-exclude -- Kiln/Lint.swift" ]]; then
  ok "lint-hook runs from the repo root, on the one file, with --force-exclude"
else bad "lint-hook called swiftlint as: $CALL"; fi
grep -q -- '--fix' "$FAKE_SWIFTLINT_LOG" && bad "lint-hook passed --fix" || true
quiet_hook() { # quiet_hook <label> <file> [env...]: exit 0, no output
  local label=$1; shift; lh "$@"
  if [[ $LH_CODE -eq 0 && -z "$LH_OUT" ]]; then ok "lint-hook: $label"; else bad "lint-hook: $label (exit $LH_CODE): $LH_OUT"; fi
}
quiet_hook "silent for a file that is not Swift" "$T/Kiln/notes.md"
[[ -s "$FAKE_SWIFTLINT_LOG" ]] && bad "lint-hook ran swiftlint on a non-Swift file"
quiet_hook "silent in a repo with no .swiftlint.yml" "$T/nolint/A.swift"
quiet_hook "silent outside a repo" "$T/outside/A.swift"
quiet_hook "silent for a clean file" "$T/Kiln/Kiln/Lint.swift" FAKE_SWIFTLINT_CLEAN=1
quiet_hook "exit 0 when swiftlint crashes" "$T/Kiln/Kiln/Lint.swift" FAKE_SWIFTLINT_CRASH=1
mkdir -p "$T/emptybin"; LH_CODE=0
LH_OUT=$(printf '{"tool_input":{"file_path":"%s"}}' "$T/Kiln/Kiln/Lint.swift" | env PATH="$T/emptybin:/usr/bin:/bin" "$K/bin/lint-hook.sh" 2>&1) || LH_CODE=$?
[[ $LH_CODE -eq 0 && -z "$LH_OUT" ]] && ok "lint-hook: exit 0 when swiftlint is not installed" || bad "lint-hook without swiftlint (exit $LH_CODE): $LH_OUT"
if printf 'not json' | "$K/bin/lint-hook.sh" >/dev/null 2>&1; then ok "lint-hook exits 0 on bad input"; else bad "lint-hook failed on bad input"; fi

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

# cloudkit-schema-check: the fields a SwiftData model needs in CloudKit, and a
# schema export compared with them. The model mixes every case: an optional,
# an array, Data (with its large-value field), relationships both ways, and
# things that are not stored (@Transient, computed, static, a nested enum).
CK="$T/ck-app"; mkdir -p "$CK/App/Models" "$CK/AppTests"
cat > "$CK/App/Models/Trip.swift" <<'SWIFT'
import SwiftData
@Model
final class Trip {
    var id: UUID = UUID()
    var name: String = "" // a comment with a { brace
    var startDate: Date?
    var tags: [String] = []
    @Attribute(.externalStorage)
    var photo: Data?
    var rating: Int = 0
    var score: Double = 0
    var isFavorite: Bool = false
    @Relationship(deleteRule: .cascade,
                  inverse: \Stop.trip)
    var stops: [Stop]? = []
    @Transient var cached: String = ""
    var summary: String { "\(name) {" }
    static let kind = "trip"
    enum Mode: String { case a, b }
    init() {}
    func rename(to newName: String) { let n = newName; name = n }
}
SWIFT
cat > "$CK/App/Models/Stop.swift" <<'SWIFT'
import SwiftData
@Model final class Stop {
    var id: UUID = UUID()
    private(set) var title: String = ""
    var trip: Trip?
    init() {}
}
SWIFT
printf 'import SwiftData\n@Model final class OnlyInTests { var x: Int = 0\n init() {} }\n' > "$CK/AppTests/Fake.swift"
ck_record() { # ck_record <name> <field lines...>: one record type of an export
  local name=$1; shift
  printf '    RECORD TYPE %s (\n        "___createTime" TIMESTAMP,\n        "___createdBy"  REFERENCE,\n        "___etag"       STRING,\n        "___modTime"    TIMESTAMP,\n        "___modifiedBy" REFERENCE,\n        "___recordID"   REFERENCE QUERYABLE,\n' "$name"
  printf '%s\n' "$@"
  printf '        GRANT WRITE TO "_creator",\n        GRANT CREATE TO "_icloud",\n        GRANT READ TO "_world"\n    );\n\n'; }
TRIP=('        CD_entityName   STRING QUERYABLE SEARCHABLE SORTABLE,' '        CD_id           STRING QUERYABLE SEARCHABLE SORTABLE,'
      '        CD_isFavorite   INT64 QUERYABLE SORTABLE,' '        CD_name         STRING QUERYABLE SEARCHABLE SORTABLE,'
      '        CD_photo        BYTES,' '        CD_photo_ckAsset ASSET,' '        CD_rating       INT64 QUERYABLE SORTABLE,'
      '        CD_score        DOUBLE QUERYABLE SORTABLE,' '        CD_startDate    TIMESTAMP QUERYABLE SORTABLE,'
      '        CD_tags         BYTES QUERYABLE,')
STOP=('        CD_entityName   STRING QUERYABLE SEARCHABLE SORTABLE,' '        CD_id           STRING QUERYABLE SEARCHABLE SORTABLE,'
      '        "CD_title"      STRING QUERYABLE SEARCHABLE SORTABLE,' '        CD_trip         STRING QUERYABLE SEARCHABLE SORTABLE,')
{ printf 'DEFINE SCHEMA\n\n'; ck_record CD_Trip "${TRIP[@]}" '        CD_oldField     STRING,'; ck_record CD_Stop "${STOP[@]}"
  ck_record Users '        roles           LIST<INT64>,'; } > "$T/ck-full.ckdb"
{ printf 'DEFINE SCHEMA\n\n'
  ck_record CD_Trip "${TRIP[0]}" "${TRIP[1]}" "${TRIP[2]}" "${TRIP[3]}" "${TRIP[4]}" \
    '        CD_rating       STRING QUERYABLE SEARCHABLE SORTABLE,' "${TRIP[7]}" "${TRIP[9]}"; } > "$T/ck-gaps.ckdb"
out=$("$K/bin/cloudkit-schema-check.sh" "$CK" 2>&1) || true
if grep -q '^CD_Trip: 10 fields, 16 in CloudKit Console$' <<<"$out" && grep -q '^CD_Stop: 4 fields, 10 in CloudKit Console$' <<<"$out" \
   && grep -qE '^  CD_trip +String +to-one relationship$' <<<"$out" && grep -qE '^  CD_photo_ckAsset +Asset' <<<"$out" \
   && grep -qE '^  CD_startDate +Date/Time +optional$' <<<"$out" && grep -qE '^  CD_tags +Bytes$' <<<"$out" \
   && ! grep -qE 'CD_(stops|cached|summary|kind|Mode|OnlyInTests|rename|n)\b' <<<"$out"; then
  ok "cloudkit-schema-check lists the fields a model needs, and nothing that isn't stored"
else bad "cloudkit-schema-check model fields: $out"; fi
code=0; out=$("$K/bin/cloudkit-schema-check.sh" "$CK" "$T/ck-full.ckdb" 2>&1) || code=$?
if [[ $code -eq 0 ]] && grep -q '^OK: ck-full.ckdb has every field the models need (2 record types)' <<<"$out" \
   && grep -q 'CD_Trip: in the schema but not in the models.*CD_oldField' <<<"$out"; then
  ok "cloudkit-schema-check accepts a complete schema, and notes a field no model has"
else bad "cloudkit-schema-check complete schema (exit $code): $out"; fi
code=0; out=$("$K/bin/cloudkit-schema-check.sh" "$CK" "$T/ck-gaps.ckdb" 2>&1) || code=$?
if [[ $code -eq 1 ]] && grep -q 'CD_Stop: the whole record type' <<<"$out" \
   && grep -q "CD_Trip: CD_startDate (Date/Time): a record that sets it can't sync" <<<"$out" \
   && grep -q "CD_Trip: CD_photo_ckAsset (Asset): a large value can't sync" <<<"$out" \
   && grep -q 'CD_Trip: CD_rating is STRING in the schema, but the model needs INT64' <<<"$out" \
   && ! grep -q 'CD_score' <<<"$out"; then
  ok "cloudkit-schema-check names each missing record type, field and wrong type"
else bad "cloudkit-schema-check gaps (exit $code): $out"; fi
cp "$T/ck-full.ckdb" "$T/ck-nonopt.ckdb"; sed -i.bak '/CD_name /d' "$T/ck-nonopt.ckdb"
code=0; out=$("$K/bin/cloudkit-schema-check.sh" "$CK" "$T/ck-nonopt.ckdb" 2>&1) || code=$?
[[ $code -eq 1 ]] && grep -q "CD_Trip: CD_name (String): no record of this type can sync" <<<"$out" \
  && ok "cloudkit-schema-check says a missing always-set field stops every record" || bad "cloudkit-schema-check non-optional (exit $code): $out"
code=0; printf 'not a schema\n' > "$T/ck-bogus.ckdb"; "$K/bin/cloudkit-schema-check.sh" "$CK" "$T/ck-bogus.ckdb" >/dev/null 2>&1 || code=$?
code2=0; "$K/bin/cloudkit-schema-check.sh" >/dev/null 2>&1 || code2=$?
[[ $code -eq 2 && $code2 -eq 2 ]] && ok "cloudkit-schema-check refuses a file that isn't a schema, and no arguments" || bad "cloudkit-schema-check refusals: exit $code, $code2"
# Rarer ways to write a model, each of which an earlier parse got wrong without
# saying so: @SwiftData.Model, and @ Model with a space; a doc comment that
# mentions @Model; attributes, nonisolated or package between it and class;
# between two models, a one-line raw string that starts with three quotes and
# regex literals holding /*, an escaped delimiter, or spanning lines after
# trailing spaces; types inferred from Date.now and UUID().uuidString, and ones
# that can't be (Date().formatted() isn't a Date); two
# bindings on a line, also after a multi-line array or a range; a stored
# optional with didSet; nested parentheses in an attribute; Optional<T>; module
# prefixes; a backquoted name; types inferred from the default; package and
# private(set) with no space; a raw string with a quote and a parenthesis; one
# property in both #if branches; TimeInterval; a Codable value; an interpolation
# holding a quoted brace; and what isn't stored: @Attribute(.ephemeral), a
# getter, a computed property whose brace is on its own line, and a property in
# nested block comments.
CK2="$T/ck-app2"; mkdir -p "$CK2/App"
cat > "$CK2/App/Models.swift" <<'SWIFT'
import SwiftData
/** The @Model everything else hangs off. */
@ Model
@MainActor
final class Alpha {
    var a = 0, b: Int = 1
    var watched: String? { didSet { print("changed") } }
    @Attribute(.transformable(by: Box(rawValue: "")))
    var blob: Colour?
    var beta: Optional<Beta>
    var betas: Swift.Array<Beta> = []
    var `default`: Bool = false
    var id = UUID()
    var logo = Data()
    package var secret: String = ""
    private(set)var tight: Int = 0
    var pattern: String = #"a"(b"#
    var span: Range<Int> = 0..<5, count: Int = 0
#if DEBUG
    var mode: String = "debug"
#else
    var mode: String = "release"
#endif
    @Attribute(.ephemeral) var scratch: String = ""
    var getter: Int { get { a } }
    /* outer /* inner */ var hidden: Int = 0 */
    init() {}
}
let quote = #"""#
let trailingSlashes = #/\/*$/#
let escaped = #/a\/#\{/#
SWIFT
printf 'let multiLine = #/  \n  """\n/#\n' >> "$CK2/App/Models.swift"
cat >> "$CK2/App/Models.swift" <<'SWIFT'
@SwiftData.Model nonisolated package final class Beta {
    var alphas: [Alpha] = []
    var name = "x"
    var icon: Foundation.Data?
    var codes: [Int] = [
        1,
        2
    ], flag = true
    var elapsed: TimeInterval = 0
    var label: String = "\(String(describing: "}"))"
    var createdAt = Date.now
    var key = UUID().uuidString
    var status = Status.active
    var dayKey = Date().formatted(date: .numeric, time: .omitted)
    var summary: String
    {
        name
    }
    init() {}
}
SWIFT
out=$("$K/bin/cloudkit-schema-check.sh" "$CK2" 2>&1) || true
if grep -q '^CD_Alpha: 16 fields, 22 in CloudKit Console$' <<<"$out" && grep -q '^CD_Beta: 12 fields, 18 in CloudKit Console$' <<<"$out" \
   && grep -qE '^  CD_a +Int\(64\)$' <<<"$out" && grep -qE '^  CD_b +Int\(64\)$' <<<"$out" && grep -qE '^  CD_default +Int\(64\)$' <<<"$out" \
   && grep -qE '^  CD_watched +String +optional$' <<<"$out" && grep -qE '^  CD_blob +Bytes +optional, a Codable value: one field assumed, check by hand$' <<<"$out" \
   && grep -qE '^  CD_beta +String +to-one relationship$' <<<"$out" && grep -qE '^  CD_id +String$' <<<"$out" \
   && grep -qE '^  CD_logo_ckAsset +Asset' <<<"$out" && grep -qE '^  CD_name +String$' <<<"$out" \
   && grep -qE '^  CD_icon_ckAsset +Asset' <<<"$out" && grep -qE '^  CD_flag +Int\(64\)$' <<<"$out" \
   && grep -qE '^  CD_secret +String$' <<<"$out" && grep -qE '^  CD_tight +Int\(64\)$' <<<"$out" && grep -qE '^  CD_pattern +String$' <<<"$out" \
   && grep -qE '^  CD_span +Bytes +a Codable value' <<<"$out" && grep -qE '^  CD_count +Int\(64\)$' <<<"$out" \
   && [[ $(grep -cE '^  CD_mode +String$' <<<"$out") -eq 1 ]] && grep -qE '^  CD_elapsed +Double$' <<<"$out" \
   && grep -qE '^  CD_label +String$' <<<"$out" && grep -qE '^  CD_createdAt +Date/Time$' <<<"$out" && grep -qE '^  CD_key +String$' <<<"$out" \
   && grep -qE '^  CD_status +unknown +type not inferred, not checked$' <<<"$out" && grep -qE '^  CD_dayKey +unknown +type not inferred, not checked$' <<<"$out" \
   && grep -q '^Type not checked (none written, none inferred): CD_Beta.CD_dayKey, CD_Beta.CD_status$' <<<"$out" \
   && grep -q 'many-to-many between Alpha and Beta' <<<"$out" && ! grep -qE 'CD_(scratch|getter|betas|alphas|summary|hidden)\b' <<<"$out"; then
  ok "cloudkit-schema-check reads the rarer ways to write a model, and notes a many-to-many relationship"
else bad "cloudkit-schema-check rarer model forms: $out"; fi
# What it can't read stops the check (exit 2, naming where) rather than drop a
# model or a field and report OK: two models with one name and no typealias to
# choose, or typealiases in #if branches that choose differently; inheritance; an @Model on something else, a declaration it can't
# parse or doesn't know, one declared with two types in #if branches, and what
# a bare regex literal (/.../, which the check doesn't read) can do: brackets
# that don't balance, statements run together, and a model swallowed.
mkdir -p "$T/ck-dup/V1" "$T/ck-dup/V2" "$T/ck-sub" "$T/ck-struct" "$T/ck-tuple" "$T/ck-word" "$T/ck-leak" "$T/ck-merged" "$T/ck-angle" "$T/ck-twice" "$T/ck-swallow" "$T/ck-ifalias"
printf 'enum V1 {\n@Model final class Item { var a: Int = 0\n init() {} }\n}\n' > "$T/ck-dup/V1/Item.swift"
printf 'enum V2 {\n@Model final class Item { var a: Int = 0\n var b: String = ""\n init() {} }\n}\n' > "$T/ck-dup/V2/Item.swift"
printf '@Model final class Other { var z: Int = 0\n init() {} }\n' > "$T/ck-dup/Other.swift"
cp -R "$T/ck-dup/." "$T/ck-ifalias/"
printf '#if LEGACY_STORE\ntypealias Item = V1.Item\n#else\ntypealias Item = V2.Item\n#endif\n' > "$T/ck-ifalias/Current.swift"
printf '@Model class Base { var a: Int = 0\n init() {} }\n@Model final class Sub: Base { var b: Int = 0 }\n' > "$T/ck-sub/M.swift"
printf '@Model final class Ok { var a: Int = 0\n init() {} }\n@Model\nstruct NotAClass { var a = 0 }\n' > "$T/ck-struct/M.swift"
printf '@Model final class E {\n var (x, y): (Int, Int) = (0, 0)\n init() {} }\n' > "$T/ck-tuple/M.swift"
printf '@Model final class W {\n    mystery var a: Int = 0\n    init() {}\n}\n' > "$T/ck-word/M.swift"
printf '@Model final class G {\n    var lo = a<b, hi: Int = 0\n    init() {}\n}\n' > "$T/ck-angle/M.swift"
printf '@Model final class D {\n#if DEBUG\n    var m: Int = 0\n#else\n    var m: String = ""\n#endif\n    init() {}\n}\n' > "$T/ck-twice/M.swift"
cat > "$T/ck-swallow/M.swift" <<'SWIFT'
@Model final class A { var a: Int = 0
  init() {} }
let r = /"""/
@Model final class B { var b: Int = 0
  init() {} }
SWIFT
cat > "$T/ck-leak/U.swift" <<'SWIFT'
@Model final class U {
    let re = /\}/
    var after: Int = 0
    init() {}
}
SWIFT
cat > "$T/ck-merged/U2.swift" <<'SWIFT'
@Model final class U2 {
    let re = /\(/
    var after: Int = 0
    let close = /\)/
    init() {}
}
SWIFT
refused=""
for c in "ck-dup:@Model classes named Item (V1 in V1/Item.swift, V2 in V2/Item.swift)" "ck-sub:Sub inherits from the model Base" \
         "ck-struct:M.swift:3: an @Model this check can't read" "ck-tuple:E: can't read the declaration: var (x, y)" \
         "ck-word:W: can't read the declaration: mystery var a" "ck-leak:U.swift: its brackets don't balance" \
         "ck-merged:U2: can't read the declaration: let re" "ck-angle:G: can't read the declaration: var lo = a<b, hi" \
         "ck-twice:D: m is declared twice, with different types" \
         "ck-swallow:M.swift: @Model appears 2 times but 1 outside comments and strings" \
         "ck-ifalias:@Model classes named Item (V1 in V1/Item.swift, V2 in V2/Item.swift)"; do
  code=0; out=$("$K/bin/cloudkit-schema-check.sh" "$T/${c%%:*}" 2>&1) || code=$?
  [[ $code -eq 2 ]] && grep -qF "${c#*:}" <<<"$out" || refused+=" ${c%%:*} (exit $code: $out)"
done
[[ -z $refused ]] && ok "cloudkit-schema-check stops on Swift it can't read, duplicate model names and inheritance" \
  || bad "cloudkit-schema-check didn't stop on:$refused"
# Schema versions: a top-level typealias names the one in use, directly or
# through an alias of its schema; with none, the one at top level is current
# (a typealias inside a type is local to it and doesn't count).
mkdir -p "$T/ck-ver" "$T/ck-ver2" "$T/ck-ver3"; cp -R "$T/ck-dup/." "$T/ck-ver/"; cp -R "$T/ck-dup/." "$T/ck-ver2/"
printf 'typealias Item = V2.Item\n' > "$T/ck-ver/Current.swift"
printf 'typealias CurrentSchema = V2\ntypealias Item = CurrentSchema.Item\n' > "$T/ck-ver2/Current.swift"
printf '@Model final class Item { var a: Int = 0\n var b: String = ""\n init() {} }\n' > "$T/ck-ver3/Item.swift"
printf 'enum V1 {\n@Model final class Item { var a: Int = 0\n init() {} }\n}\nenum Plan {\n typealias Item = V1.Item\n}\n' > "$T/ck-ver3/V1.swift"
versions=""
for v in ck-ver ck-ver2 ck-ver3; do
  code=0; out=$("$K/bin/cloudkit-schema-check.sh" "$T/$v" 2>&1) || code=$?
  [[ $code -eq 0 ]] && grep -q '^CD_Item: 3 fields, 9 in CloudKit Console$' <<<"$out" && grep -qE '^  CD_b +String$' <<<"$out" || versions+=" $v (exit $code: $out)"
done
[[ -z $versions ]] && ok "cloudkit-schema-check takes the schema version in use: named by a top-level typealias, or the one at top level" \
  || bad "cloudkit-schema-check schema versions:$versions"
# The export side: an encrypted field, a relationship stored as a REFERENCE, an
# assumed type that differs (a note, not a failure), a record type no model
# has, and the CDMR record type many-to-many links use.
{ printf 'DEFINE SCHEMA\n\n'
  ck_record CD_Alpha '        CD_a            INT64 QUERYABLE SORTABLE,' '        CD_b            INT64 QUERYABLE SORTABLE,' \
    '        CD_beta         REFERENCE QUERYABLE,' '        CD_blob         STRING,' '        CD_count        INT64 QUERYABLE SORTABLE,' \
    '        CD_default      INT64 QUERYABLE SORTABLE,' '        CD_entityName   STRING QUERYABLE SEARCHABLE SORTABLE,' \
    '        CD_id           ENCRYPTED STRING,' '        CD_logo         BYTES,' '        CD_logo_ckAsset ASSET,' \
    '        CD_mode         STRING QUERYABLE SEARCHABLE SORTABLE,' '        CD_pattern      STRING QUERYABLE SEARCHABLE SORTABLE,' \
    '        CD_secret       STRING QUERYABLE SEARCHABLE SORTABLE,' '        CD_span         BYTES,' \
    '        CD_tight        INT64 QUERYABLE SORTABLE,' '        CD_watched      STRING QUERYABLE SEARCHABLE SORTABLE,'
  ck_record CD_Beta '        CD_codes        BYTES,' '        CD_createdAt    TIMESTAMP QUERYABLE SORTABLE,' '        CD_dayKey       STRING QUERYABLE SEARCHABLE SORTABLE,' \
    '        CD_elapsed      DOUBLE QUERYABLE SORTABLE,' \
    '        CD_entityName   STRING QUERYABLE SEARCHABLE SORTABLE,' '        CD_flag         INT64 QUERYABLE SORTABLE,' \
    '        CD_icon         BYTES,' '        CD_icon_ckAsset ASSET,' '        CD_key          STRING QUERYABLE SEARCHABLE SORTABLE,' \
    '        CD_label        STRING QUERYABLE SEARCHABLE SORTABLE,' '        CD_name         STRING QUERYABLE SEARCHABLE SORTABLE,' \
    '        CD_status       BYTES,'
  ck_record CD_Gone '        CD_entityName   STRING QUERYABLE SEARCHABLE SORTABLE,'
  ck_record CDMR '        CD_entityNames  STRING QUERYABLE,' '        CD_recordNames  STRING QUERYABLE,'; } > "$T/ck-app2.ckdb"
code=0; out=$("$K/bin/cloudkit-schema-check.sh" "$CK2" "$T/ck-app2.ckdb" 2>&1) || code=$?
if [[ $code -eq 0 ]] && grep -q '^OK: ck-app2.ckdb has every field the models need (2 record types)' <<<"$out" \
   && grep -q 'CD_Alpha: CD_blob is STRING in the schema; the check assumed BYTES' <<<"$out" \
   && grep -q 'CD_Gone: no model matches it' <<<"$out" && grep -q 'the schema has a CDMR record type' <<<"$out"; then
  ok "cloudkit-schema-check reads encrypted fields and REFERENCE relationships, and only notes an assumed type"
else bad "cloudkit-schema-check export forms (exit $code): $out"; fi

echo
if [[ $FAILS -gt 0 ]]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "All checks passed."
