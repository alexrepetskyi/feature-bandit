#!/usr/bin/env bash
# state.json — the only workflow state FeatureBandit owns.
# shellcheck disable=SC2034,SC2153,SC2016
#   SC2034/SC2153: the FB_* variables here are shared with the other lib/*.sh
#   files and with featurebandit, across a runtime `source` shellcheck cannot
#   follow. SC2016: a jq program is single-quoted on purpose — $k, $s and $d are
#   jq's own variables, bound with --arg, not the shell's.
# Everything about the feature itself lives in the Spec Kit artifacts under
# specs/<feature>/, and everything about the code lives in git.

FB_STAGES="specify plan implement review simplify security converge done"

fb_ckpt_label() {
  case "$1" in
    specify)   echo "Specification" ;;
    plan)      echo "Plan" ;;
    implement) echo "Implementation" ;;
    review)    echo "Review" ;;
    simplify)  echo "Simplification" ;;
    security)  echo "Security" ;;
    converge)  echo "Compliance" ;;
    done)      echo "Done" ;;
  esac
}

fb_state_exists() { [ -f "$FB_DIR/state.json" ]; }

# fail closed: called from the parent shell before anything reads state
fb_state_ok() {
  jq -e 'has("checkpoints") and has("branch")' "$FB_DIR/state.json" >/dev/null 2>&1 ||
    fb_fail "$FB_DIR/state.json is missing or unreadable"
}

# every write is atomic, and a failed write stops the run
fb_state_write() {
  jq "$@" "$FB_DIR/state.json" > "$FB_DIR/state.json.tmp" ||
    fb_fail "could not write $FB_DIR/state.json"
  mv "$FB_DIR/state.json.tmp" "$FB_DIR/state.json" ||
    fb_fail "could not replace $FB_DIR/state.json"
}

fb_state_get() { jq -r "$1" "$FB_DIR/state.json" 2>/dev/null; }

# Read every field once, in the parent shell, so a jq failure can actually stop
# the run — inside $(...) an exit would only kill the subshell.
fb_load_state() {
  local line rc
  line=$(jq -r '[.title,.slug,.branch,.startCommit,.originalBranch,.featureDir] | @tsv' \
    "$FB_DIR/state.json" 2>/dev/null)
  rc=$?
  [ $rc -eq 0 ] && [ -n "$line" ] || fb_fail "could not read $FB_DIR/state.json"
  IFS=$'\t' read -r FB_TITLE FB_SLUG FB_BRANCH FB_START FB_ORIG FB_FDIR <<EOF
$line
EOF
  [ -n "$FB_BRANCH" ] && [ -n "$FB_START" ] || fb_fail "$FB_DIR/state.json is incomplete"
  if [ -n "$FB_FDIR" ]; then
    FB_FEATURE_DIR="$FB_ROOT/$FB_FDIR"
    FB_SPEC="$FB_FEATURE_DIR/spec.md"
    FB_PLAN="$FB_FEATURE_DIR/plan.md"
    FB_TASKS="$FB_FEATURE_DIR/tasks.md"
    export SPECIFY_FEATURE_DIRECTORY="$FB_FEATURE_DIR"
  fi
}

fb_state_new() {
  jq -n --arg t "$1" --arg s "$2" --arg b "$3" --arg c "$4" --arg o "$5" '
    {title: $t, slug: $s, branch: $b, startCommit: $c, originalBranch: $o,
     featureDir: "", stage: "specify", durations: {},
     checkpoints: {specify: false, plan: false, implement: false, review: false,
                   simplify: false, security: false, converge: false, done: false}}' \
    > "$FB_DIR/state.json.tmp" || fb_fail "could not write $FB_DIR/state.json"
  mv "$FB_DIR/state.json.tmp" "$FB_DIR/state.json" ||
    fb_fail "could not replace $FB_DIR/state.json"
  fb_load_state
}

fb_set_feature_dir() {
  fb_state_write --arg d "$1" '.featureDir = $d'
  fb_load_state
}

# the checkpoint and the stage's measured duration are one atomic write
fb_checkpoint() {
  fb_state_write --arg k "$1" --arg s "$(fb_next_after "$1")" --argjson d "${2:-0}" \
    '.checkpoints[$k] = true | .stage = $s | .durations[$k] = $d'
}

fb_next_after() {
  local s seen=0
  for s in $FB_STAGES; do
    [ $seen -eq 1 ] && { echo "$s"; return; }
    [ "$s" = "$1" ] && seen=1
  done
  echo finished
}

# first stage whose checkpoint is false; empty when the feature is finished
fb_next_stage() {
  local s
  for s in $FB_STAGES; do
    [ "$(fb_state_get ".checkpoints.$s")" != true ] && { echo "$s"; return; }
  done
}

# what a resume needs to know, rendered from the one atomic state
fb_status() {
  local next last
  next=$(fb_next_stage)
  last=$(fb_last_done)
  ui_err ""
  ui_err "$FB_BOLD$FB_TITLE$FB_OFF"
  ui_detail "Branch:       $FB_BRANCH"
  ui_detail "Start commit: $FB_START"
  [ -n "$FB_FDIR" ] && ui_detail "Feature:      $FB_FDIR"
  ui_detail "Last done:    ${last:-nothing yet}"
  ui_detail "Continues at: $([ -n "$next" ] && fb_ckpt_label "$next" || echo finished)"
  ui_pipeline "$next" "${1:-next}"
}

fb_last_done() {
  local s out=""
  for s in $FB_STAGES; do
    [ "$(fb_state_get ".checkpoints.$s")" = true ] && out=$(fb_ckpt_label "$s")
  done
  printf '%s' "$out"
}

fb_stage_index() {
  local s n=0
  for s in $FB_STAGES; do
    n=$((n + 1))
    [ "$s" = "$1" ] && { printf '%s' "$n"; return; }
  done
}

fb_stage_count() {
  local s n=0
  for s in $FB_STAGES; do n=$((n + 1)); done
  printf '%s' "$n"
}
