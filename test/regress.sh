#!/usr/bin/env bash
# Regression suite: the failure modes and resume paths the orchestrator owns.
# Usage: test/regress.sh
# shellcheck disable=SC2119,SC2012,SC2016
#   fb_run_happy takes optional arguments; `ls` is fine on paths this suite
#   creates itself; and the single-quoted Makefile bodies use make's $$, not the
#   shell's.

# shellcheck source=test/lib.sh
. "$(dirname -- "$0")/lib.sh"

echo "1. spec kit not initialised"
new_repo nospeckit
rm -rf .specify .claude && git add -A && git commit -qm drop
fb_run_happy > "$WORK/o" 2>&1
check "refused"          "1" "$?"
check "named spec kit"   "1" "$(nonzero "$(count 'spec-kit' "$WORK/o")")"
check "gave the command" "1" "$(nonzero "$(count 'specify init --here' "$WORK/o")")"
check "no branch made"   "main" "$(git rev-parse --abbrev-ref HEAD)"

echo "2. missing plugin"
new_repo noplugin
FAKE_NO_PLUGIN=pr-review-toolkit FEATUREBANDIT_CHOICES='q' "$FB" "Add greeting" > "$WORK/o" 2>&1 < /dev/null
check "refused"          "1" "$?"
check "named it"         "1" "$(nonzero "$(count 'pr-review-toolkit' "$WORK/o")")"
check "gave the command" "1" "$(nonzero "$(count 'claude plugin install pr-review-toolkit@claude-plugins-official' "$WORK/o")")"
check "said what stopped it" "1" "$(nonzero "$(count 'required plugins missing' "$WORK/o")")"
check "installed nothing" "0" "$([ -f "$FAKE_INSTALL_DIR/pr-review-toolkit" ] && echo 1 || echo 0)"
check "no branch made"   "main" "$(git rev-parse --abbrev-ref HEAD)"

echo "3. plugin command failure"
new_repo cmdfail
FAKE_EXIT_ON='/speckit-tasks' fb_run_happy q > "$WORK/o" 2>&1
check "stopped"       "1" "$?"
check "said which"    "1" "$(nonzero "$(count 'Spec Kit: tasks' "$WORK/o")")"
check "plan not done" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Plan')"

echo "4. dirty tree"
new_repo dirty
echo junk > junk.txt
fb_run_happy > "$WORK/o" 2>&1
check "refused"     "1" "$?"
check "said why"    "1" "$(nonzero "$(count 'working tree is not clean' "$WORK/o")")"
check "junk intact" "1" "$([ -f junk.txt ] && echo 1 || echo 0)"

echo "5. an existing feature branch is never reused"
new_repo existing
git branch featurebandit/add-greeting
before=$(git rev-parse featurebandit/add-greeting)
fb_run_happy > "$WORK/o" 2>&1
check "took a fresh branch" "featurebandit/add-greeting-2" "$(git rev-parse --abbrev-ref HEAD)"
check "old branch untouched" "$before" "$(git rev-parse featurebandit/add-greeting)"

echo "6. a cyrillic title still gets a unique branch"
new_repo cyrillic
fb_run_happy "" "Добавь красивый цветной вывод" > "$WORK/o" 2>&1
one=$(git rev-parse --abbrev-ref HEAD)
check "usable branch name" "1" "$(printf '%s' "$one" | grep -cE '^featurebandit/feature-[0-9]+$')"
new_repo cyrillic2
fb_run_happy "" "Добавь поддержку тёмной темы" > "$WORK/o" 2>&1
two=$(git rev-parse --abbrev-ref HEAD)
check "different title, different branch" "1" "$([ "$one" != "$two" ] && echo 1 || echo 0)"

echo "7. linked git worktree"
new_repo worktree
git worktree add -q "$WORK/wt" -b side
cd "$WORK/wt" || exit 1
fb_run_happy > "$WORK/o" 2>&1
check "finished"             "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"
check "branched from side"   "featurebandit/add-greeting" "$(git rev-parse --abbrev-ref HEAD)"
check "excluded in the common dir" "1" "$(count '.featurebandit/' "$WORK/worktree/.git/info/exclude")"

echo "8. a failing commit stops the stage"
new_repo commitfail
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
fb_run_happy > "$WORK/o" 2>&1
check "stopped"            "1" "$?"
check "said commit failed" "1" "$(nonzero "$(count 'git commit failed' "$WORK/o")")"
check "spec not approved"  "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Specification')"

echo "9. a failing state write stops the stage"
new_repo statefail
FAKE_EXIT_ON='/speckit-plan' fb_run_happy q > /dev/null 2>&1
mkdir .featurebandit/state.json.tmp
FEATUREBANDIT_CHOICES='c,a,a,a' "$FB" resume > "$WORK/o" 2>&1
check "stopped"           "1" "$?"
check "said state failed" "1" "$(nonzero "$(count 'could not write' "$WORK/o")")"
rmdir .featurebandit/state.json.tmp
check "plan still open"   "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Plan')"

echo "10. interrupted after a batch commit, never reimplemented"
new_repo batch
FAKE_EXIT_ON='stop: T004' fb_run_happy q > "$WORK/o" 2>&1
check "first batch committed" "1" "$(count 'implement T001 T002 T003' <(git log --oneline))"
check "markers committed"     "3" "$(git show HEAD:specs/001-feature/tasks.md | grep -c '^- \[X\]')"
FEATUREBANDIT_CHOICES='a,a' "$FB" resume > "$WORK/o2" 2>&1
check "finished"              "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"
check "T001 implemented once" "1" "$(count 'stop: T001' "$FAKE_LOG")"

echo "11. failing verification blocks the commit until it is fixed"
new_repo gate
printf 'test:\n\t@test -f fixed\n' > Makefile && git add -A && git commit -qm makefile
fb_run_happy > "$WORK/o" 2>&1
check "debugged it" "1" "$(nonzero "$(count 'Debugging the failing check' "$WORK/o")")"
check "finished"    "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "12. no continuing without a verification command"
new_repo noverify
rm Makefile && git add -A && git commit -qm drop
printf '\n' | "$FB" "Add greeting" > "$WORK/o" 2>&1
check "refused"  "1" "$?"
check "said why" "1" "$(nonzero "$(count 'at least one verification command is required' "$WORK/o")")"

echo "13. rollback removes untracked files too"
new_repo rollback
printf 'test:\n\t@test -f fixed\n' > Makefile && git add -A && git commit -qm makefile
FAKE_UNTRACKED=1 FAKE_EXIT_ON='systematic-debugging' fb_run_happy q > "$WORK/o" 2>&1
check "left work behind" "1" "$([ -f scratch.tmp ] && echo 1 || echo 0)"
FEATUREBANDIT_CHOICES='d,q' FAKE_EXIT_ON='/speckit-implement' "$FB" resume > "$WORK/o2" 2>&1
check "untracked discarded" "0" "$([ -f scratch.tmp ] && echo 1 || echo 0)"
check "tracked restored"    ""  "$(git status --porcelain)"

echo "14. converge appends tasks, they get implemented"
new_repo converge
FAKE_CONVERGE_ADD=1 fb_run_happy a,a > "$WORK/o" 2>&1
check "committed the new tasks" "1" "$(count 'converge appended tasks' <(git log --oneline))"
check "converge ran twice"      "2" "$(count '^/speckit-converge' "$FAKE_LOG")"
check "appended task done"      "1" "$(count '^- \[X\] T005' specs/001-feature/tasks.md)"
check "reviewed the new work"   "2" "$(count 'pr-review-toolkit:code-reviewer' "$FAKE_LOG")"
check "finished"                "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "15. abort keeps everything when the checkout fails"
new_repo abortfail
FAKE_EXIT_ON='/speckit-plan' fb_run_happy q > /dev/null 2>&1
git branch -D main >/dev/null
FEATUREBANDIT_CHOICES='y' "$FB" abort > "$WORK/o" 2>&1
check "refused"          "1" "$?"
check "said why"         "1" "$(nonzero "$(count 'could not check out main' "$WORK/o")")"
check "state kept"       "1" "$([ -f .featurebandit/state.json ] && echo 1 || echo 0)"
check "still on feature" "featurebandit/add-greeting" "$(git rev-parse --abbrev-ref HEAD)"

echo "16. resume after every stage"
resume_choices() {
  case "$1" in
    specify)   printf 'a,c,a,a,a' ;;
    plan)      printf 'c,a,a,a' ;;
    implement) printf 'a,a' ;;
    review)    printf 'a,a' ;;
    simplify)  printf 'a' ;;
    security)  printf 'a' ;;
    converge)  printf '' ;;
  esac
}
resume_text() { [ "$1" = specify ] && printf 'no localisation\n'; }
fb_label() {
  case "$1" in
    specify) printf 'Specification' ;; plan) printf 'Plan' ;;
    implement) printf 'Implementation' ;; converge) printf 'Compliance' ;;
    review) printf 'Review' ;; simplify) printf 'Simplification' ;;
    security) printf 'Security' ;;
  esac
}
stage_marker() {
  case "$1" in
    specify)   printf '/speckit-specify' ;;
    plan)      printf '/speckit-plan' ;;
    implement) printf '/speckit-implement' ;;
    review)    printf 'pr-review-toolkit:code-reviewer' ;;
    simplify)  printf 'code-simplifier:code-simplifier' ;;
    security)  printf '/security-review' ;;
    converge)  printf '/speckit-converge' ;;
  esac
}
for stage in specify plan implement review simplify security converge; do
  new_repo "r-$stage"
  FAKE_EXIT_ON="$(stage_marker "$stage")" fb_run_happy q > "$WORK/o" 2>&1
  check "stopped at $stage" "1" "$("$FB" status 2>&1 | grep -c "Continues at: $(fb_label "$stage")")"
  printf '%s' "$(resume_text "$stage")" | FEATUREBANDIT_CHOICES="$(resume_choices "$stage")" \
    "$FB" resume > "$WORK/o2" 2>&1
  check "resumed past $stage" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"
done

echo "17. an open checklist item is shown and can be closed before approval"
new_repo checklist
printf 'no localisation\nno localisation\n' | FAKE_CHECKLIST_OPEN=1 \
  FEATUREBANDIT_CHOICES='a,c,a,c,a,a,a' "$FB" "Add greeting" > "$WORK/o" 2>&1
check "reported the open item" "1" "$(nonzero "$(count '1 item(s) still open' "$WORK/o")")"
check "listed it"              "1" "$(nonzero "$(count 'CHK002' "$WORK/o")")"
check "clarified twice"        "2" "$(count '^/speckit-clarify' "$FAKE_LOG")"
check "finished"               "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "18. clarify with nothing to ask never prompts for an answer"
new_repo noclarify
FAKE_CLARIFY_NONE=1 FEATUREBANDIT_CHOICES='a,a,c,a,a,a' "$FB" "Add greeting" </dev/null > "$WORK/o" 2>&1
check "said so"           "1" "$(nonzero "$(count 'clarify: no open questions' "$WORK/o")")"
check "asked nothing"     "0" "$(count 'your answer' "$WORK/o")"
check "finished"          "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "19. an analyze finding never restarts specify"
new_repo analyze
printf 'no localisation\nno localisation\n' | \
  FEATUREBANDIT_CHOICES='a,a,l,c,a,a,a' "$FB" "Add greeting" > "$WORK/o" 2>&1
check "specify ran once"   "1" "$(count '^/speckit-specify' "$FAKE_LOG")"
check "clarified again"    "2" "$(count '^/speckit-clarify' "$FAKE_LOG")"
check "replanned"          "2" "$(count '^/speckit-plan' "$FAKE_LOG")"
check "one feature dir"    "1" "$(ls -d specs/*/ | wc -l | tr -d ' ')"
check "finished"           "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "20. a plugin that moves the branch stops the run"
new_repo hijack
FAKE_HIJACK_ON='/speckit-plan' fb_run_happy q > "$WORK/o" 2>&1
check "stopped"     "1" "$?"
check "said why"    "1" "$(nonzero "$(count 'branch changed underneath' "$WORK/o")")"
git checkout -q featurebandit/add-greeting 2>/dev/null
check "plan not approved" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Plan')"

echo "21. a missing plugin is installed on request"
new_repo installplugin
printf '%s' "$CLARIFY" | FAKE_NO_PLUGIN=code-simplifier \
  FEATUREBANDIT_CHOICES="i,$HAPPY" "$FB" "Add greeting" > "$WORK/o" 2>&1
check "ran the official command" "1" "$(nonzero "$(count 'claude plugin install code-simplifier@claude-plugins-official' "$WORK/o")")"
check "installed it"             "1" "$([ -f "$FAKE_INSTALL_DIR/code-simplifier" ] && echo 1 || echo 0)"
check "finished"                 "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "22. a failed write call is never retried on its own"
new_repo writeretry
printf '%s' "$CLARIFY" |
  FAKE_EXIT_ON='/speckit-plan' FEATUREBANDIT_CHOICES='a,a,q' "$FB" "Add greeting" > "$WORK/o" 2>&1
check "stopped"           "1" "$?"
check "called it once"    "1" "$(count '^/speckit-plan' "$FAKE_LOG")"
check "warned about writes" "1" "$(nonzero "$(count 'it may have written some before it failed' "$WORK/o")")"
check "plan still open"   "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Plan')"

echo "23. discarding before a retry removes what the failed block wrote"
new_repo writediscard
printf '%s' "$CLARIFY" | FAKE_EXIT_ON='/speckit-tasks' \
  FEATUREBANDIT_CHOICES='a,a,d,q' "$FB" "Add greeting" > "$WORK/o" 2>&1
check "stopped"            "1" "$?"
check "retried after the discard" "2" "$(count '^/speckit-tasks' "$FAKE_LOG")"
check "the partial plan is gone"  "0" "$([ -f specs/001-feature/plan.md ] && echo 1 || echo 0)"
check "the committed spec is not" "1" "$([ -f specs/001-feature/spec.md ] && echo 1 || echo 0)"

echo "24. a fix at the final verification goes back through review"
new_repo finalfix
printf 'test:\n\t@if [ -f .featurebandit/converge.md ] && [ ! -f fixed ]; then echo "spec gap"; exit 1; fi; echo ok\n' > Makefile
git add -A && git commit -qm makefile
fb_run_happy a,a > "$WORK/o" 2>&1
check "debugged the final failure" "1" "$(nonzero "$(count 'Debugging the failing check' "$WORK/o")")"
check "committed the fix"          "1" "$(count 'final fixes' <(git log --oneline))"
check "said what it was doing"     "1" "$(nonzero "$(count 'changed code after the last review' "$WORK/o")")"
check "reviewed the fix"           "2" "$(count 'pr-review-toolkit:code-reviewer' "$FAKE_LOG")"
check "security-checked it"        "2" "$(count '^/security-review' "$FAKE_LOG")"
check "converged again"            "2" "$(count '^/speckit-converge' "$FAKE_LOG")"
check "finished"                   "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "25. a new feature never inherits the last one's verification commands"
new_repo newfeature
fb_run_happy > "$WORK/o" 2>&1
check "first one finished" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"
printf '%s' "$CLARIFY" | FEATUREBANDIT_CHOICES="y,$HAPPY" "$FB" "Add farewell" > "$WORK/o2" 2>&1
check "asked again"        "1" "$(nonzero "$(count 'Detected verification commands' "$WORK/o2")")"
check "second one finished" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "26. the summary lists only the findings that were really accepted"
new_repo accepted
fb_run_happy > "$WORK/o" 2>&1
check "listed the accepted review report" "1" "$(nonzero "$(count 'review-code-reviewer.md' "$WORK/o")")"
new_repo accepted2
printf '%s' "$CLARIFY" | FEATUREBANDIT_CHOICES='a,a,c,a,f,n,n' "$FB" "Add greeting" > "$WORK/o" 2>&1
check "nothing accepted, nothing listed" "1" "$(nonzero "$(count 'accepted rather than fixed: none' "$WORK/o")")"
check "fixed instead"                    "1" "$(nonzero "$(count 'test-driven-development' "$FAKE_LOG")")"
check "finished"                         "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

finish
