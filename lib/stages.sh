#!/usr/bin/env bash
# one function per pipeline stage.
# shellcheck disable=SC2034,SC2153,SC2016
#   SC2034/SC2153: the FB_* variables here are shared with the other lib/*.sh
#   files and with featurebandit, across a runtime `source` shellcheck cannot
#   follow. SC2016: a jq program is single-quoted on purpose — $n and $d are
#   jq's own variables, bound with --arg, not the shell's.
# The shell owns transitions, git, approvals and exit codes. Spec Kit,
# Superpowers, the PR Review Toolkit, Code Simplifier and the built-in
# /security-review own every engineering decision and their own artifacts.

FB_BATCH=3
FB_MAX_CONVERGE=3

# --- stage framing -----------------------------------------------------------

fb_log_dir() {
  case "$1" in
    specify)   echo specification ;;
    plan)      echo plan ;;
    implement) echo implementation ;;
    review)    echo review ;;
    simplify)  echo simplification ;;
    security)  echo security ;;
    converge)  echo compliance ;;
    done)      echo compliance ;;
  esac
}

fb_stage_about() {
  case "$1" in
    specify)   echo "Specifying and clarifying with Spec Kit, then checking the result" ;;
    plan)      echo "Planning, breaking into tasks and cross-checking with Spec Kit" ;;
    implement) echo "Implementing tasks in batches, verifying each in a plain shell" ;;
    review)    echo "Reviewing the feature diff with the PR Review Toolkit agents" ;;
    simplify)  echo "Refining the changed code with Code Simplifier, behaviour unchanged" ;;
    security)  echo "Running the built-in /security-review over the branch" ;;
    converge)  echo "Checking the merged result against the specification with Spec Kit" ;;
    done)      echo "Final verification and the summary" ;;
  esac
}

fb_stage_begin() {
  FB_STAGE_T0=$SECONDS
  FB_STAGE_STATE=running
  FB_LOG_STAGE=$(fb_log_dir "$1")
  FB_STAGE_COMMITS=""
  FB_STAGE_TASKS=""
  FB_VERIFY_PASSED=""
  ui_stage_start "$(fb_stage_index "$1")" "$(fb_stage_count)" \
    "$(fb_ckpt_label "$1")" "$(fb_stage_about "$1")"
}

# a stage held at a gate is not a completed stage
fb_stage_waiting() { FB_STAGE_STATE=waiting; }

fb_stage_ok() {
  local secs=$((SECONDS - FB_STAGE_T0))
  FB_STAGE_STATE=success
  fb_checkpoint "$1" "$secs"
  {
    [ -n "$FB_STAGE_TASKS" ] && echo "Tasks:        $FB_STAGE_TASKS"
    case "$FB_VERIFY_PASSED" in
      "")      ;;
      skipped) echo "Verification: skipped" ;;
      *)       echo "Verification: $FB_VERIFY_PASSED passed" ;;
    esac
    [ -n "$FB_STAGE_COMMITS" ] && echo "Commits:      $FB_STAGE_COMMITS"
    echo "Logs:         $(fb_rel "$FB_LOGS/$(fb_log_dir "$1")")/"
    echo "Next:         $(fb_ckpt_label "$(fb_next_after "$1")")"
  } | ui_stage_summary "$(fb_ckpt_label "$1")" success "$secs"
}

# --- shared ------------------------------------------------------------------

fb_hash() { fb_git hash-object "$1" || fb_fail "git hash-object failed on $1"; }

# tasks.md is Spec Kit's own progress contract: "- [ ] T001" -> "- [X] T001"
fb_tasks_todo() {
  [ -f "$FB_TASKS" ] || { echo 0; return; }
  grep -cE '^[[:space:]]*- \[ \] T[0-9]' "$FB_TASKS" || true
}

fb_batch_ids() {
  grep -E '^[[:space:]]*- \[ \] T[0-9]+' "$FB_TASKS" |
    sed -E 's/^[[:space:]]*- \[ \] (T[0-9]+).*/\1/' |
    head -n "$FB_BATCH" | tr '\n' ' ' | sed 's/ $//'
}

# checklists are Spec Kit's own contract too: "- [ ] CHK001" is an open item
fb_checklist_open() {
  local f n total=0
  for f in "$FB_FEATURE_DIR"/checklists/*.md; do
    [ -f "$f" ] || continue
    n=$(grep -cE '^[[:space:]]*- \[ \]' "$f" || true)
    total=$((total + n))
  done
  echo "$total"
}

fb_checklist_open_items() {
  local f
  for f in "$FB_FEATURE_DIR"/checklists/*.md; do
    [ -f "$f" ] || continue
    grep -E '^[[:space:]]*- \[ \]' "$f" | sed "s|^[[:space:]]*|  ${f##*/}  |"
  done
}

# What the user chose to accept rather than fix, so the final summary reports
# the truth instead of listing every report that was ever written.
fb_accepted() {
  printf '%s\n' "$@" >> "$FB_DIR/accepted.txt" ||
    fb_fail "could not write $FB_DIR/accepted.txt"
}

# Apply a plugin's findings. The findings are the plugin's; the fix is the
# superpowers TDD skill, invoked as a slash command so it demonstrably loads.
fb_fix_from_reports() {
  local label="$1"
  shift
  fb_claude "Fixing $label findings" "fix" write \
"/superpowers:test-driven-development Fix the defects these review reports identify, in $FB_ROOT.

Reports:
---
$(cat "$@")
---

For every real defect add or update the test that fails without the fix. Do not
change behaviour that the specification at $FB_SPEC requires. Never weaken a
test. Do not commit; FeatureBandit commits." || return 1
  fb_assert_branch
  fb_verify_gate "$label" || return 1
  fb_commit "featurebandit: $label fixes" || ui_info "nothing to commit"
  return 0
}

# Bounded fix loop for a tool that reports findings as prose: the user decides,
# never a severity guessed out of the text.
# 0 = accepted, 1 = stop, 2 = fixed, review again
fb_findings_gate() {
  local label="$1" round="$2"
  shift 2
  ui_detail "$label findings are the plugin's own words; they carry no machine-readable"
  ui_detail "severity, so FeatureBandit neither ranks nor interprets them."
  # Enter takes the first option, so the first option never accepts findings:
  # accepting unfixed findings is a decision, not a default.
  ui_gate "What do you want to do with the $label findings?" \
    "f:Fix them and review again" "q:Stop here and look at them myself" \
    "n:Nothing to fix in this report — continue" \
    "a:Accept the open findings unfixed and continue" || return 1
  case "$FB_CHOICE" in
    n) return 0 ;;
    a) fb_accepted "$@"; return 0 ;;
    q) return 1 ;;
  esac
  fb_fix_from_reports "$label" "$@" || return 1
  if [ "$round" -ge 3 ]; then
    ui_warning "$label: three fix rounds done"
    ui_gate "Keep going?" "f:Keep fixing" "q:Stop here" \
      "a:Accept what is left unfixed and continue" || return 1
    case "$FB_CHOICE" in
      a) fb_accepted "$@"; return 0 ;;
      q) return 1 ;;
    esac
  fi
  return 2
}

# --- 1. specification --------------------------------------------------------

# Spec Kit's clarify asks one question per turn and marks each with its
# documented "**Question:**" prefix; no marker means it has nothing left to ask.
fb_clarify_loop() {
  local round=0 sid answer
  fb_claude "Spec Kit: clarify" "clarify" write "${FB_SK}clarify" || return 1
  while [ $round -lt 5 ]; do
    printf '%s' "$FB_OUT" | grep -q '^\*\*Question:\*\*' || break
    round=$((round + 1))
    fb_report "$FB_DIR/clarify.md"
    sid="$FB_SESSION"
    ui_prompt "your answer (empty = tell Spec Kit you are done)"
    answer="$FB_ANSWER"
    [ -n "$answer" ] || answer="done"
    fb_claude "Spec Kit: clarify ($round of at most 5)" "clarify-answer" write "$answer" "$sid" || return 1
    [ "$answer" = "done" ] && break
  done
  [ $round -eq 0 ] && ui_info "clarify: no open questions"
  fb_report "$FB_DIR/clarify.md"
  fb_assert_branch
}

fb_run_checklist() {
  fb_claude "Spec Kit: checklist" "checklist" write \
"${FB_SK}checklist completeness, unambiguous requirements, testable acceptance criteria, failure behaviour, permissions and validation" || return 1
  fb_report "$FB_DIR/checklist.md"
  fb_assert_branch
}

fb_stage_specify() {
  local fdir open

  fb_claude "Spec Kit: specify" "specify" write "${FB_SK}specify $(cat "$FB_DIR/requirements.md")" || return 1
  fb_report "$FB_DIR/specify.md"
  fb_assert_branch

  fdir=$(jq -r '.feature_directory // empty' "$FB_ROOT/.specify/feature.json" 2>/dev/null)
  [ -n "$fdir" ] || { ui_error "${FB_SK}specify did not record a feature in .specify/feature.json"; return 1; }
  fb_set_feature_dir "$fdir"
  [ -f "$FB_SPEC" ] || { ui_error "no specification at $(fb_rel "$FB_SPEC")"; return 1; }

  fb_clarify_loop || return 1
  fb_run_checklist || return 1

  while :; do
    open=$(fb_checklist_open)
    if [ "$open" -eq 0 ]; then
      ui_info "checklists: every item passes"
    else
      ui_warning "checklists: $open item(s) still open"
      fb_checklist_open_items >&2
    fi
    fb_stage_waiting
    ui_gate "Specification ready ($(fb_rel "$FB_SPEC")). Approve it?" \
      "v:View the specification" \
      "a:Approve it and continue" \
      "c:Clarify further, then recheck the checklists" \
      "q:Stop here" || return 1
    case "$FB_CHOICE" in
      a) break ;;
      v) ${PAGER:-cat} "$FB_SPEC" >&2 ;;
      c) fb_clarify_loop || return 1; fb_run_checklist || return 1 ;;
      q) return 1 ;;
    esac
  done

  fb_commit "featurebandit: specification for $FB_SLUG" || ui_info "nothing to commit"
  fb_stage_ok specify
}

# --- 2. plan -----------------------------------------------------------------

# Findings go back to the artefact that owns them. Nothing here re-runs
# specify: that would create a second feature directory instead of correcting
# the current specification.
fb_stage_plan() {
  local run_plan=1
  while :; do
    if [ $run_plan -eq 1 ]; then
      fb_claude "Spec Kit: plan" "plan" write "${FB_SK}plan" || return 1
      fb_report "$FB_DIR/plan-run.md"
      fb_assert_branch
      [ -f "$FB_PLAN" ] || { ui_error "no plan at $(fb_rel "$FB_PLAN")"; return 1; }
    fi
    run_plan=1

    fb_claude "Spec Kit: tasks" "tasks" write "${FB_SK}tasks" || return 1
    fb_report "$FB_DIR/tasks-run.md"
    fb_assert_branch
    [ -f "$FB_TASKS" ] || { ui_error "no tasks at $(fb_rel "$FB_TASKS")"; return 1; }

    fb_commit "featurebandit: plan and tasks for $FB_SLUG" || ui_info "nothing to commit"

    fb_claude "Spec Kit: analyze" "analyze" write "${FB_SK}analyze" || return 1
    fb_report "$FB_DIR/analyze.md"
    fb_assert_branch

    fb_stage_waiting
    ui_gate "Send each analyze finding back to the artefact that owns it." \
      "c:Nothing to send back — continue" \
      "l:Specification finding — clarify it, then replan" \
      "p:Plan finding — rerun plan and tasks" \
      "t:Task finding — rerun tasks only" \
      "q:Stop here" || return 1
    case "$FB_CHOICE" in
      c) break ;;
      l) fb_clarify_loop || return 1
         fb_commit "featurebandit: clarified specification for $FB_SLUG" || ui_info "nothing to commit" ;;
      p) ;;
      t) run_plan=0 ;;
      q) return 1 ;;
    esac
  done

  while :; do
    fb_stage_waiting
    ui_gate "Plan ready ($(fb_rel "$FB_PLAN")). Approve it?" \
      "v:View the plan" "a:Approve it and continue" "q:Stop here" || return 1
    case "$FB_CHOICE" in
      a) break ;;
      v) ${PAGER:-cat} "$FB_PLAN" >&2 ;;
      q) return 1 ;;
    esac
  done
  fb_stage_ok plan
}

# --- 3. implementation -------------------------------------------------------

# Each batch commits code and the [X] markers in tasks.md in one commit, so a
# Ctrl-C leaves no window: either the commit exists and the tasks are done, or
# neither is true and the batch simply runs again.
fb_run_batches() {
  local ids todo after
  while :; do
    todo=$(fb_tasks_todo)
    [ "$todo" -eq 0 ] && return 0
    ids=$(fb_batch_ids)

    FB_STAGE_TASKS="${FB_STAGE_TASKS:+$FB_STAGE_TASKS }$ids"
    fb_claude "Implementing $ids" "implement-${ids// /-}" write \
"${FB_SK}implement Implement only these tasks, in order, and then stop: $ids.
Mark each finished task [X] in tasks.md. Do not commit; FeatureBandit commits." || return 1
    fb_report "$FB_DIR/implement.md"
    fb_assert_branch

    fb_verify_gate "implementation" || return 1
    fb_commit "featurebandit: implement $ids" || ui_warning "batch $ids changed nothing"

    after=$(fb_tasks_todo)
    if [ "$after" -ge "$todo" ]; then
      ui_warning "no task was marked done — $todo still open in $(fb_rel "$FB_TASKS")"
      fb_stage_waiting
      ui_gate "Nothing moved in tasks.md." "r:Retry the batch" "q:Stop here" || return 1
      [ "$FB_CHOICE" = q ] && return 1
    fi
  done
}

fb_stage_implement() {
  [ -f "$FB_TASKS" ] || { ui_error "no tasks at $(fb_rel "$FB_TASKS")"; return 1; }
  fb_run_batches || return 1
  fb_verify_gate "implementation" || return 1
  fb_stage_ok implement
}

# --- 4. review ---------------------------------------------------------------

# type and comment analysis only when the diff actually calls for them
fb_review_agents() {
  local list="pr-review-toolkit:code-reviewer pr-review-toolkit:pr-test-analyzer pr-review-toolkit:silent-failure-hunter"
  grep -qE '^\+.*(\binterface\b|\btype\b|\bstruct\b|\bclass\b|\benum\b|\btrait\b|dataclass|TypedDict|Protocol)' "$FB_DIR/diff.patch" &&
    list="$list pr-review-toolkit:type-design-analyzer"
  grep -qE '^[+-][[:space:]]*(//|#|\*|/\*|"""|<!--)' "$FB_DIR/diff.patch" &&
    list="$list pr-review-toolkit:comment-analyzer"
  printf '%s' "$list"
}

fb_stage_review() {
  local agents a name round=0 rc
  while :; do
    rm -f "$FB_DIR"/review-*.md
    fb_write_diff
    agents=$(fb_review_agents)
    for a in $agents; do
      name=${a#*:}
      fb_claude "Review: $name" "$name" read "Dispatch the Agent tool exactly once with subagent_type \"$a\".

Tell that agent its review scope is the feature diff at $FB_DIR/diff.patch, that it may
read any file under $FB_ROOT for context, and that it must report only on what the diff
changes.

Reply with the agent's report verbatim. Add no judgement, no severity and no summary of
your own." || return 1
      fb_report "$FB_DIR/review-$name.md"
    done
    fb_assert_branch

    fb_findings_gate "Review" "$round" "$FB_DIR"/review-*.md
    rc=$?
    [ $rc -eq 0 ] && break
    [ $rc -eq 1 ] && return 1
    round=$((round + 1))
  done
  fb_stage_ok review
}

# --- 5. simplification -------------------------------------------------------

fb_stage_simplify() {
  fb_write_diff
  fb_claude "Simplifying" "simplify" write "Dispatch the Agent tool exactly once with subagent_type \"code-simplifier:code-simplifier\".

Scope it to the files the feature diff at $FB_DIR/diff.patch changes, and nothing else.
Then apply the refinements it returns.

Hard rule: no behaviour change. Skip any refinement that would change what the code does
or that reaches outside the diff, and say which ones you skipped.
Do not commit; FeatureBandit commits." || return 1
  fb_report "$FB_DIR/simplify.md"
  fb_assert_branch

  fb_verify_gate "simplification" || return 1
  fb_commit "featurebandit: simplify" || ui_info "nothing to simplify"
  fb_stage_ok simplify
}

# --- 6. security -------------------------------------------------------------

fb_stage_security() {
  local round=0 rc
  while :; do
    fb_claude "Security review" "security-review" read "/security-review" || return 1
    fb_report "$FB_DIR/security-review.md"
    fb_assert_branch

    fb_findings_gate "Security" "$round" "$FB_DIR/security-review.md"
    rc=$?
    [ $rc -eq 0 ] && break
    [ $rc -eq 1 ] && return 1
    round=$((round + 1))
  done
  fb_stage_ok security
}

# --- 7. compliance -----------------------------------------------------------

# Runs last, after review, simplification and security have had their say: those
# stages change code, so compliance with the specification has to be decided on
# what is actually going to be merged.
#
# converge is append-only, so its result is a file contract: an unchanged
# tasks.md means converged, a changed one means it appended a Convergence phase.
fb_stage_converge() {
  local before after rounds
  fb_verify_gate "converge" || return 1

  before=$(fb_hash "$FB_TASKS")
  fb_claude "Spec Kit: converge" "converge" write "${FB_SK}converge" || return 1
  fb_report "$FB_DIR/converge.md"
  fb_assert_branch
  after=$(fb_hash "$FB_TASKS")

  if [ "$before" = "$after" ]; then
    ui_info "converged — ${FB_SK}converge appended no tasks"
    fb_stage_ok converge
    return 0
  fi

  ui_info "${FB_SK}converge appended tasks — implementing them, then reviewing again"
  fb_commit "featurebandit: converge appended tasks" || ui_info "nothing to commit"
  fb_run_batches || return 1
  fb_verify_gate "converge" || return 1

  rounds=$(jq -r '.convergeRounds // 0' "$FB_DIR/state.json" 2>/dev/null)
  [ -n "$rounds" ] || fb_fail "could not read $FB_DIR/state.json"
  rounds=$((rounds + 1))
  fb_state_write --argjson n "$rounds" '.convergeRounds = $n'

  if [ "$rounds" -ge "$FB_MAX_CONVERGE" ]; then
    ui_warning "converge has appended tasks $rounds times running"
    fb_stage_waiting
    ui_gate "Keep converging?" \
      "q:Stop here" \
      "c:Review, simplify, secure and converge again" \
      "a:Accept the remaining gap and finish" || return 1
    case "$FB_CHOICE" in
      a) fb_accepted "$FB_DIR/converge.md"; fb_stage_ok converge; return 0 ;;
      q) return 1 ;;
    esac
    fb_state_write '.convergeRounds = 0'
  fi

  # new code needs the same review, simplification and security it would have
  # got the first time round
  fb_state_write '.checkpoints.review = false | .checkpoints.simplify = false | .checkpoints.security = false'
  return 2
}

# --- 8. done -----------------------------------------------------------------

# No self-written final acceptance: converge, the review agents, the security
# review and the tests already cover it.
#
# The final verification is the one gate that can still change code: if it
# fails, systematic-debugging fixes it. Code that was fixed here has never been
# reviewed, simplified, security-checked or converged, so it goes back through
# those stages instead of being declared finished.
fb_stage_done() {
  local i=1 cmd secs f
  if ! fb_verify "done"; then
    fb_verify_gate "done" failed || return 1
    fb_assert_branch
    if fb_commit "featurebandit: final fixes"; then
      ui_warning "the final fix changed code after the last review"
      ui_info "reviewing, simplifying, securing and converging it again"
      fb_state_write '.checkpoints.review = false | .checkpoints.simplify = false
                      | .checkpoints.security = false | .checkpoints.converge = false'
      return 2
    fi
    ui_info "the fix changed no tracked file — nothing to review again"
  fi
  fb_assert_branch
  secs=$((SECONDS - FB_STAGE_T0))
  FB_STAGE_STATE=success
  fb_checkpoint "done" "$secs"

  ui_err ""
  ui_rule
  ui_err "$FB_GRN$FB_S_OK FeatureBandit finished$FB_OFF"
  ui_detail "Branch:       $FB_BRANCH  (never merged, never pushed — that part is yours)"
  ui_detail "Spec:         $(fb_rel "$FB_SPEC")"
  ui_detail "Tasks:        $(fb_rel "$FB_TASKS")"
  ui_detail "Logs:         $(fb_rel "$FB_LOGS")/"
  ui_detail ""
  ui_detail "Commits:"
  fb_git log --oneline "$FB_START..HEAD" | while IFS= read -r l; do ui_detail "  $l"; done
  ui_detail ""
  if fb_config_get VERIFY_SKIPPED >/dev/null 2>&1; then
    ui_detail "Verification: skipped for this feature — no test or linter ran"
  else
    ui_detail "Verification commands that passed:"
    while cmd=$(fb_config_get "VERIFY_COMMAND_$i"); do
      ui_detail "  $cmd"
      i=$((i + 1))
    done
  fi
  ui_detail ""
  if [ -s "$FB_DIR/accepted.txt" ]; then
    ui_detail "Findings you accepted rather than fixed:"
    sort -u "$FB_DIR/accepted.txt" | while IFS= read -r f; do
      [ -f "$f" ] && ui_detail "  $(fb_rel "$f")"
    done
  else
    ui_detail "Findings you accepted rather than fixed: none"
  fi
  ui_rule
  ui_err ""
}
