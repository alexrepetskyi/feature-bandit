#!/usr/bin/env bash
# The whole pipeline against a stubbed claude: no API calls, no cost.
# Usage: test/smoke.sh
# shellcheck disable=SC2119,SC2012,SC2016
#   fb_run_happy takes optional arguments; `ls` is fine on paths this suite
#   creates itself; and the single-quoted Makefile bodies use make's $$, not the
#   shell's.

# shellcheck source=test/lib.sh
. "$(dirname -- "$0")/lib.sh"

echo "full pipeline"
new_repo happy
fb_run_happy > "$WORK/out.txt" 2>&1
rc=$?

check "exit code"            "0" "$rc"
check "feature branch"       "featurebandit/add-greeting" "$(git rev-parse --abbrev-ref HEAD)"
check "working tree clean"   ""  "$(git status --porcelain)"
check "spec committed"       "1" "$(git ls-files specs/001-feature/spec.md | wc -l | tr -d ' ')"
check "every task done"      "0" "$(count '^- \[ \] T' specs/001-feature/tasks.md)"
check "state excluded"       "1" "$(grep -c '.featurebandit/' .git/info/exclude)"
check "logs not committed"   "0" "$(git ls-files .featurebandit | wc -l | tr -d ' ')"
check "per-block logs"       "1" "$([ -d .featurebandit/logs/add-greeting/specification ] && echo 1 || echo 0)"
check "CLAUDE.md untouched"  "0" "$([ -f CLAUDE.md ] && echo 1 || echo 0)"
check "finished"             "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

for cmd in specify clarify checklist plan tasks analyze implement converge; do
  check "ran /speckit-$cmd" "1" "$(nonzero "$(count "^/speckit-$cmd" "$FAKE_LOG")")"
done
for agent in code-reviewer pr-test-analyzer silent-failure-hunter; do
  check "ran $agent" "1" "$([ -f .featurebandit/review-$agent.md ] && echo 1 || echo 0)"
done
check "ran code simplifier" "1" "$(nonzero "$(count 'code-simplifier:code-simplifier' "$FAKE_LOG")")"
check "ran /security-review" "1" "$(nonzero "$(count '^/security-review' "$FAKE_LOG")")"
check "task batches"         "2" "$(count '^/speckit-implement' "$FAKE_LOG")"
check "converge ran last"    "1" "$(nonzero "$(grep -n '^/speckit-converge' "$FAKE_LOG" | tail -1 | cut -d: -f1)")"
check "converge after security" "1" "$([ "$(grep -n '^/speckit-converge' "$FAKE_LOG" | tail -1 | cut -d: -f1)" -gt "$(grep -n '^/security-review' "$FAKE_LOG" | tail -1 | cut -d: -f1)" ] && echo 1 || echo 0)"
check "no merge to main"     "0" "$(git log --oneline main | grep -c featurebandit || true)"

finish
