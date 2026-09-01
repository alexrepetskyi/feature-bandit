#!/usr/bin/env bash
# Regression suite for the command runner, the logs and the terminal interface.
# Usage: test/ui.sh
# shellcheck disable=SC2119,SC2012,SC2016
#   fb_run_happy takes optional arguments; `ls` is fine on paths this suite
#   creates itself; and the single-quoted Makefile bodies use make's $$, not the
#   shell's.

# shellcheck source=test/lib.sh
. "$(dirname -- "$0")/lib.sh"

esc=$(printf '\033')

echo "1. interactive choice through gum"
new_repo tty
fb_run_tty "${GUM_HAPPY[@]}" > "$WORK/o" 2>&1
check "finished"        "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"
check "gum drew the menus" "1" "$(nonzero "$(count '^choose' "$FAKE_GUM_LOG")")"
check "gum asked for the text" "1" "$(nonzero "$(count '^input' "$FAKE_GUM_LOG")")"

echo "2. the choices spec kit offers become a menu"
new_repo clarifymenu
FAKE_CLARIFY_TABLE=1 fb_run_tty "Accept them" "B —" "Approve it" "Nothing to send back" \
  "Approve it" "Accept the open findings" "Accept the open findings" > "$WORK/o" 2>&1
check "answered with the key"  "1" "$(count '^B$' "$FAKE_LOG")"
check "the table became a menu" "1" "$(nonzero "$(count 'Look the greeting up per locale' "$FAKE_GUM_LOG")")"
check "typing is still offered" "1" "$(nonzero "$(count 'Type my own answer' "$FAKE_GUM_LOG")")"
check "finished"               "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "3. cancelling a choice stops the run"
new_repo cancel
fb_run_tty "Accept them" "no localisation" "__CANCEL__" > "$WORK/o" 2>&1
check "stopped"          "1" "$?"
check "said so"          "1" "$(nonzero "$(count 'selection cancelled' "$WORK/o")")"
check "spec not approved" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Specification')"

echo "4. a failing gum call stops the run"
new_repo gumfail
fb_run_tty "Accept them" "no localisation" "__FAIL__" > "$WORK/o" 2>&1
check "stopped"           "1" "$?"
check "spec not approved" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Specification')"

echo "5. gum missing while a terminal is in use"
new_repo nogum
rm -f "$BIN/gum"
PATH="$(nogum_path)" FEATUREBANDIT_TTY=1 "$FB" "Add greeting" > "$WORK/o" 2>&1 < /dev/null
check "refused"          "1" "$?"
check "named gum"        "1" "$(nonzero "$(count 'gum draws the interactive menus' "$WORK/o")")"
check "gave the command" "1" "$(nonzero "$(count 'brew install gum' "$WORK/o")")"
check "no branch made"   "main" "$(git rev-parse --abbrev-ref HEAD)"
cp "$FB_SRC/test/fake-gum" "$BIN/gum"

echo "6. gum is not needed without a terminal"
new_repo nogum2
rm -f "$BIN/gum"
saved_path=$PATH
PATH="$(nogum_path)"
fb_run_happy > "$WORK/o" 2>&1
PATH=$saved_path
check "finished"   "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"
check "said so"    "1" "$(nonzero "$(count 'not needed without a terminal' "$WORK/o")")"
cp "$FB_SRC/test/fake-gum" "$BIN/gum"

echo "7. an approval that was never given is not an approval"
new_repo failclosed
FEATUREBANDIT_CHOICES='a' "$FB" "Add greeting" > "$WORK/o" 2>&1 < /dev/null
check "stopped"     "1" "$?"
check "said why"    "1" "$(nonzero "$(count 'no decision left in FEATUREBANDIT_CHOICES' "$WORK/o")")"
check "named the variable" "1" "$(nonzero "$(count 'FEATUREBANDIT_CHOICES=' "$WORK/o")")"

echo "8. an answer that is not on offer is refused"
new_repo badchoice
FEATUREBANDIT_CHOICES='a,zz' "$FB" "Add greeting" > "$WORK/o" 2>&1 < /dev/null
check "stopped"  "1" "$?"
check "said why" "1" "$(nonzero "$(count 'which is not one of' "$WORK/o")")"

echo "9. NO_COLOR drops colour, TERM=dumb drops every escape"
new_repo nocolor
gum_queue "${GUM_HAPPY[@]}"
NO_COLOR=1 FEATUREBANDIT_TTY=1 "$FB" "Add greeting" < /dev/null > "$WORK/o" 2>&1
check "no colour under NO_COLOR" "0" "$(grep -cE "$esc\\[[0-9;]*m" "$WORK/o" || true)"
check "finished"                 "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"
new_repo dumbterm
TERM=dumb fb_run_happy > "$WORK/o" 2>&1
check "no escapes at all under TERM=dumb" "0" "$(grep -c "$esc" "$WORK/o" || true)"
check "finished anyway"          "1" "$("$FB" status 2>&1 | grep -c 'Continues at: finished')"

echo "10. no invented percentage anywhere"
new_repo nopct
fb_run_happy > "$WORK/o" 2>&1
check "no percentages" "0" "$(grep -cE '[0-9]+%' "$WORK/o" || true)"
check "real elapsed time" "1" "$(nonzero "$(grep -cE 'completed in [0-9]+' "$WORK/o" || true)")"

echo "11. the timer leaves nothing behind"
new_repo timers
before=$(sleepers)
fb_run_happy > "$WORK/o" 2>&1
sleep 2
check "clean after success" "1" "$([ "$(sleepers)" -le "$before" ] && echo 1 || echo 0)"
new_repo timers2
before=$(sleepers)
FAKE_EXIT_ON='/speckit-plan' fb_run_happy q > "$WORK/o" 2>&1
sleep 2
check "clean after failure" "1" "$([ "$(sleepers)" -le "$before" ] && echo 1 || echo 0)"
new_repo timers3
before=$(sleepers)
FAKE_SLOW=3 fb_start_bg
sleep 2
fb_interrupt_bg
sleep 3
check "clean after interruption" "1" "$([ "$(sleepers)" -le "$before" ] && echo 1 || echo 0)"

echo "12. Ctrl-C ends the running command, not just the runner"
new_repo interrupt
FAKE_SLOW=12 fb_start_bg
sleep 3
check "the command is running" "1" "$(nonzero "$(pgrep -f '^sleep 12$' | wc -l | tr -d ' ')")"
fb_interrupt_bg
check "nothing left behind"   "0" "$(pgrep -f '^sleep 12$' | wc -l | tr -d ' ')"

echo "13. the command's own exit code survives"
new_repo exitcode
rm Makefile && git add -A && git commit -qm drop
# no runner to detect, so the verification command is typed in: it exits 3
printf 'sh -c "exit 3"\n\nno localisation\n' |
  FAKE_EXIT_ON='systematic-debugging' FEATUREBANDIT_CHOICES='a,c,a,q' \
  "$FB" "Add greeting" > "$WORK/o" 2>&1
check "reported exit 3"    "1" "$(nonzero "$(grep -cE 'failed after [0-9]+m? ?[0-9]*s? · exit 3' "$WORK/o" || true)")"
check "did not commit"     "0" "$(git log --oneline | grep -c 'implement T001' || true)"
check "elapsed on success" "1" "$(nonzero "$(grep -cE 'completed in [0-9]+' "$WORK/o" || true)")"

echo "14. every block keeps its own complete log"
new_repo logs
printf 'test:\n\t@i=1; while [ $$i -le 60 ]; do echo "test output line $$i"; i=$$((i+1)); done\n' > Makefile
git add -A && git commit -qm makefile
FAKE_NOISY=1 fb_run_happy > "$WORK/o" 2>&1
logdir=.featurebandit/logs/add-greeting
check "per-stage directories" "1" "$([ -d $logdir/specification ] && [ -d $logdir/plan ] &&
                                     [ -d $logdir/implementation ] && [ -d $logdir/verification ] && echo 1 || echo 0)"
check "verification stdout kept whole" "1" "$(nonzero "$(count 'test output line 60' $logdir/verification/implementation-01.log)")"
check "claude stderr kept too" "1" "$(nonzero "$(count 'stderr diagnostic line 8' $logdir/plan/plan-01.log.err)")"
check "plugin report kept whole" "1" "$(nonzero "$(count 'report line 60' .featurebandit/analyze.md)")"
check "preview was trimmed"   "1" "$(nonzero "$(count 'earlier line(s) not shown' "$WORK/o")")"
check "pointed at the log"    "1" "$(nonzero "$(count 'Full output:' "$WORK/o")")"

echo "15. verification logs never overwrite each other"
new_repo verlogs
printf 'test:\n\t@echo tests pass\nlint:\n\t@echo no errors\n' > Makefile
git add -A && git commit -qm makefile
fb_run_happy > "$WORK/o" 2>&1
vlogs=$(ls .featurebandit/logs/add-greeting/verification/*.log 2>/dev/null | wc -l | tr -d ' ')
check "two commands, many logs" "1" "$([ "$vlogs" -ge 4 ] && echo 1 || echo 0)"
check "distinct attempts"       "1" "$([ -f .featurebandit/logs/add-greeting/verification/implementation-01.log ] &&
                                        [ -f .featurebandit/logs/add-greeting/verification/implementation-02.log ] && echo 1 || echo 0)"
check "both commands recorded"  "2" "$(count 'Verification:' "$WORK/o" | head -1 > /dev/null; grep -c 'no errors\|tests pass' .featurebandit/logs/add-greeting/verification/implementation-01.log .featurebandit/logs/add-greeting/verification/implementation-02.log 2>/dev/null | grep -c ':1$')"

echo "16. a log that cannot be written stops the stage"
new_repo logfail
FAKE_EXIT_ON='/speckit-plan' fb_run_happy q > /dev/null 2>&1
chmod 500 .featurebandit/logs/add-greeting/plan
FEATUREBANDIT_CHOICES='c,a,a,a' "$FB" resume > "$WORK/o" 2>&1
rc=$?
chmod 700 .featurebandit/logs/add-greeting/plan
check "stopped"  "1" "$rc"
check "said why" "1" "$(nonzero "$(count 'could not open the log' "$WORK/o")")"
check "plan still open" "1" "$("$FB" status 2>&1 | grep -c 'Continues at: Plan')"

echo "17. resume reports where it is"
new_repo resumeinfo
FAKE_EXIT_ON='/speckit-implement' fb_run_happy q > /dev/null 2>&1
out=$("$FB" status 2>&1)
check "names the feature" "1" "$(printf '%s' "$out" | grep -c 'Add greeting')"
check "names the branch"  "1" "$(printf '%s' "$out" | grep -c 'featurebandit/add-greeting')"
check "names the commit"  "1" "$(printf '%s' "$out" | grep -c 'Start commit:')"
check "last completed"    "1" "$(printf '%s' "$out" | grep -c 'Last done:    Plan')"
check "continues at"      "1" "$(printf '%s' "$out" | grep -c 'Continues at: Implementation')"
check "keeps durations"   "1" "$(nonzero "$(printf '%s' "$out" | grep -cE '(0s|[0-9]+s)\)' || true)")"

finish
