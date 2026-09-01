#!/usr/bin/env bash
# End-to-end check of the workflow against a stubbed claude: no API calls, no cost.
# Usage: test/smoke.sh

FB_SRC=$(cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbsmoke.XXXXXX")
BIN="$WORK/bin"
export FAKE_LOG="$WORK/calls.log"
mkdir -p "$BIN" && cp "$FB_SRC/test/fake-claude" "$BIN/claude"
export PATH="$BIN:$PATH"

fails=0
check() { # check "name" "expected" "actual"
  if [ "$2" = "$3" ]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

new_repo() {
  rm -rf "$WORK/$1" && mkdir -p "$WORK/$1" && cd "$WORK/$1" || exit 1
  git init -q .
  git config user.email smoke@test && git config user.name smoke
  printf 'test:\n\t@echo tests pass\n' > Makefile
  git add -A && git commit -qm init
}

echo "1. full pipeline"
new_repo happy
# verify-accept, gap answer, approve requirements, approve spec, approve plan
printf 'a\nno localization\na\na\na\n' | "$FB_SRC/featurebandit" "Add greeting" > "$WORK/out.txt" 2>&1
check "exit code" "0" "$?"
check "feature branch" "featurebandit/add-greeting" "$(git rev-parse --abbrev-ref HEAD)"
check "working tree clean" "" "$(git status --porcelain)"
check "task committed" "1" "$(git log --oneline | grep -c 'implementation: TASK-001')"
check "spec archived" "1" "$([ -f docs/specs/add-greeting.md ] && echo 1 || echo 0)"
check "claude calls" "12" "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
check "CLAUDE.md rules" "1" "$(grep -c 'featurebandit:rules:start' CLAUDE.md)"
check "state excluded from git" "1" "$(grep -c '.featurebandit/' .git/info/exclude)"

echo "2. dirty tree blocks a new feature"
new_repo dirty
echo junk > junk.txt
printf 'a\n' | "$FB_SRC/featurebandit" "Add greeting" > "$WORK/dirty.txt" 2>&1
check "refused" "1" "$?"
check "said why" "1" "$(grep -c 'working tree is not clean' "$WORK/dirty.txt")"

echo "3. interrupt, then resume"
new_repo resume
printf 'a\nno localization\na\n' | "$FB_SRC/featurebandit" "Add greeting" > /dev/null 2>&1
check "stopped mid-pipeline" "1" "$("$FB_SRC/featurebandit" status | grep -c '^→ Specification')"
echo stray > stray.txt
printf 'd\na\na\n' | "$FB_SRC/featurebandit" resume > /dev/null 2>&1
check "resumed to done" "1" "$("$FB_SRC/featurebandit" status | grep -c '^✓ Final')"
check "stray file discarded" "0" "$([ -f stray.txt ] && echo 1 || echo 0)"

echo "4. failing tests block the checkpoint until fixed"
new_repo gate
printf 'test:\n\t@test -f fixed && echo ok\n' > Makefile
git add -A && git commit -qm makefile
printf 'a\nno localization\na\na\na\n' | "$FB_SRC/featurebandit" "Add greeting" > "$WORK/gate.txt" 2>&1
check "fix session ran" "1" "$(grep -c 'Fixing failing checks' "$WORK/gate.txt")"
check "finished green" "1" "$("$FB_SRC/featurebandit" status | grep -c '^✓ Final')"

echo "5. review findings resolved interactively"
new_repo review
export FAKE_SPEC_FAIL=1
printf 'a\nno localization\na\nf\na\na\n' | "$FB_SRC/featurebandit" "Add greeting" > "$WORK/review.txt" 2>&1
check "review failed first" "1" "$(grep -c 'Specification review: FAIL' "$WORK/review.txt")"
check "passed after fix" "1" "$(grep -c 'Specification review: PASS' "$WORK/review.txt")"
unset FAKE_SPEC_FAIL

echo "6. abort restores the original branch"
new_repo abort
printf 'a\nno localization\na\na\na\n' | "$FB_SRC/featurebandit" "Add greeting" > /dev/null 2>&1
printf 'y\ny\n' | "$FB_SRC/featurebandit" abort > /dev/null 2>&1
check "back on original branch" "main" "$(git rev-parse --abbrev-ref HEAD)"
check "feature branch deleted" "0" "$(git branch --list 'featurebandit/*' | wc -l | tr -d ' ')"
check "state removed" "0" "$([ -d .featurebandit ] && echo 1 || echo 0)"

cd / && rm -rf "$WORK"
echo
if [ $fails -eq 0 ]; then
  echo "all checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
