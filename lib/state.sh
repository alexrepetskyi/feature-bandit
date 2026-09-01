#!/usr/bin/env bash
# state.json read/write — the only workflow state

FB_STAGES="requirements spec plan implementation compliance code_review simplification security final"

fb_ckpt_key() {
  case "$1" in
    requirements)   echo requirements_approved ;;
    spec)           echo spec_approved ;;
    plan)           echo plan_approved ;;
    implementation) echo implementation_complete ;;
    compliance)     echo compliance_review_complete ;;
    code_review)    echo code_review_complete ;;
    simplification) echo simplification_complete ;;
    security)       echo security_review_complete ;;
    final)          echo final_acceptance_complete ;;
  esac
}

fb_ckpt_label() {
  case "$1" in
    requirements)   echo "Requirements" ;;
    spec)           echo "Specification" ;;
    plan)           echo "Plan" ;;
    implementation) echo "Implementation" ;;
    compliance)     echo "Spec Compliance" ;;
    code_review)    echo "Code Review" ;;
    simplification) echo "Simplification" ;;
    security)       echo "Security" ;;
    final)          echo "Final" ;;
  esac
}

fb_state_exists() { [ -f "$FB_DIR/state.json" ]; }

fb_state_write() {
  jq "$@" "$FB_DIR/state.json" > "$FB_DIR/state.json.tmp" &&
    mv "$FB_DIR/state.json.tmp" "$FB_DIR/state.json"
}

fb_state_get() { jq -r "$1" "$FB_DIR/state.json"; }

fb_state_new() {
  jq -n --arg f "$1" --arg t "$2" --arg s "$3" --arg b "$4" '
    {feature: $f, title: $t, stage: "requirements",
     startCommit: $s, originalBranch: $b,
     checkpoints: {
       requirements_approved: false, spec_approved: false, plan_approved: false,
       implementation_complete: false, compliance_review_complete: false,
       code_review_complete: false, simplification_complete: false,
       security_review_complete: false, final_acceptance_complete: false
     },
     acceptedRisks: []}' > "$FB_DIR/state.json.tmp" &&
    mv "$FB_DIR/state.json.tmp" "$FB_DIR/state.json"
}

fb_checkpoint() {
  local key
  key=$(fb_ckpt_key "$1")
  fb_state_write --arg k "$key" --arg s "$(fb_next_after "$1")" \
    '.checkpoints[$k] = true | .stage = $s'
  say "$FB_OK $(fb_ckpt_label "$1")"
}

# clear a checkpoint (used when implementation exposes a spec problem)
fb_uncheckpoint() {
  local key
  key=$(fb_ckpt_key "$1")
  fb_state_write --arg k "$key" '.checkpoints[$k] = false'
}

fb_next_after() {
  local s seen=0
  for s in $FB_STAGES; do
    [ $seen -eq 1 ] && { echo "$s"; return; }
    [ "$s" = "$1" ] && seen=1
  done
  echo done
}

# first stage whose checkpoint is false; empty when the feature is finished
fb_next_stage() {
  local s
  for s in $FB_STAGES; do
    if [ "$(fb_state_get ".checkpoints.$(fb_ckpt_key "$s")")" != true ]; then
      echo "$s"
      return
    fi
  done
}

fb_status() {
  local s next
  next=$(fb_next_stage)
  say ""
  say "$FB_B$(fb_state_get .title)$FB_R"
  for s in $FB_STAGES; do
    if [ "$(fb_state_get ".checkpoints.$(fb_ckpt_key "$s")")" = true ]; then
      say "$FB_OK $(fb_ckpt_label "$s")"
    elif [ "$s" = "$next" ]; then
      say "$FB_CUR $(fb_ckpt_label "$s")"
    else
      say "$FB_TODO $(fb_ckpt_label "$s")"
    fi
  done
  say ""
}

fb_add_risk() {
  fb_state_write --arg r "$1" '.acceptedRisks += [$r]'
}
