#!/usr/bin/env bash
# the command runner, the claude wrapper, git helpers and the verification gate
# shellcheck disable=SC2034
#   The FB_* variables set here are read by the other lib/*.sh files and by
#   featurebandit, which shellcheck cannot follow across the runtime `source`.

FB_STAGE_TIMEOUT="${FEATUREBANDIT_TIMEOUT:-3600}"

# the process group of the command running right now, so the traps can end it
FB_RUN_PID=""

die() { ui_error "$*"; exit 1; }

# an unrecoverable git/jq/state/log/commit error: stop now, the checkpoint stands
fb_fail() {
  ui_error "$*"
  ui_detail "rerun featurebandit to resume from the last checkpoint"
  exit 1
}

fb_rel() { printf '%s' "${1#"$FB_ROOT"/}"; }

# --- logs --------------------------------------------------------------------
# .featurebandit/logs/<slug>/<stage>/<block>-<attempt>.log — deterministic, one
# file per attempt, never overwritten.

fb_log_path() { # STAGE_DIR BLOCK
  local dir="$FB_LOGS/$1" p n=1
  mkdir -p "$dir" || fb_fail "could not create $dir"
  while :; do
    p=$(printf '%s/%s-%02d.log' "$dir" "$2" "$n")
    [ -e "$p" ] || break
    n=$((n + 1))
  done
  printf '%s' "$p"
}

# --- the command runner ------------------------------------------------------
# One place where a command is run, timed, logged and its exit code returned.
# stdout and stderr both go to the log; nothing is piped, so the exit code is
# the command's own. A background watchdog bounds the run (GNU timeout is not
# available everywhere) and is always reaped.

# Sleeps one second at a time and exits as soon as the target does, so killing
# it can never orphan a long sleep. It signals the whole process group of the
# pid it was given — a claude session is a tree, and terminating only its shell
# would leave the tree running.
fb_watchdog() {
  local target="$1" left="$2"
  while [ "$left" -gt 0 ]; do
    kill -0 "$target" 2>/dev/null || return 0
    sleep 1
    left=$((left - 1))
  done
  fb_kill_group "$target"
  return 0
}

# TERM the group, give it a second, then KILL whatever is left.
fb_kill_group() { # PGID
  kill -TERM -"$1" 2>/dev/null || return 0
  kill -0 -"$1" 2>/dev/null || return 0
  sleep 1
  kill -KILL -"$1" 2>/dev/null
  return 0
}

# Called from the EXIT, INT and TERM traps: nothing FeatureBandit started may
# outlive it. Safe to call when nothing is running.
fb_kill_run() {
  [ -n "$FB_RUN_PID" ] || return 0
  fb_kill_group "$FB_RUN_PID"
  FB_RUN_PID=""
  return 0
}

fb_run() { # LABEL LOGFILE DISPLAY_COMMAND -- argv...
  local label="$1" log="$2" display="$3" t0 rc pid guard
  shift 3
  [ "$1" = -- ] && shift

  mkdir -p "$(dirname "$log")" || fb_fail "could not create $(dirname "$log")"
  : > "$log.partial" || fb_fail "could not open the log at $log.partial"
  : > "$log.err.partial" || fb_fail "could not open the log at $log.err.partial"

  t0=$SECONDS
  ui_step_start "$label"
  # stdout and stderr are kept apart so a machine-readable stdout stays
  # parseable; both are preserved verbatim, neither is piped, so $? is the
  # command's own exit code.
  # `set -m` puts the command in its own process group, so the whole tree it
  # spawns can be terminated as one — on Ctrl-C, on the timeout, or on any
  # other exit. stdin is /dev/null: a background group must never read the
  # terminal, and the answers typed here belong to FeatureBandit.
  set -m
  ( cd "$FB_ROOT" && "$@" ) >"$log.partial" 2>"$log.err.partial" </dev/null &
  pid=$!
  set +m
  FB_RUN_PID=$pid
  fb_watchdog "$pid" "$FB_STAGE_TIMEOUT" &
  guard=$!
  wait "$pid"; rc=$?
  FB_RUN_PID=""
  kill "$guard" 2>/dev/null
  wait "$guard" 2>/dev/null

  FB_RUN_SECONDS=$((SECONDS - t0))
  FB_RUN_CMD="$display"
  FB_RUN_LOG="$log"
  FB_RUN_ERR="$log.err"
  mv "$log.partial" "$log" || fb_fail "could not finish the log at $log"
  mv "$log.err.partial" "$log.err" || fb_fail "could not finish the log at $log.err"

  if [ $rc -eq 0 ]; then
    ui_step_success "$label" "$FB_RUN_SECONDS"
  else
    ui_step_failure "$label" "$FB_RUN_SECONDS" "$rc"
  fi
  return $rc
}

# --- git ---------------------------------------------------------------------

fb_git() { git -C "$FB_ROOT" "$@"; }

fb_tree_clean() { [ -z "$(fb_git status --porcelain)" ]; }

# a plugin, hook or extension must never move us off the feature branch:
# state and commits would then describe different branches
fb_assert_branch() {
  local now
  now=$(fb_git rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$now" ] || fb_fail "git rev-parse failed while checking the branch"
  [ "$now" = "$FB_BRANCH" ] ||
    fb_fail "branch changed underneath FeatureBandit: expected $FB_BRANCH, now on $now"
}

# commit everything; a failed commit is fatal, never silently skipped
fb_commit() {
  fb_git add -A || fb_fail "git add failed"
  if fb_git diff --cached --quiet; then
    FB_LAST_COMMIT=""
    return 1
  fi
  fb_git commit -q -m "$1" || fb_fail "git commit failed: $1"
  FB_LAST_COMMIT=$(fb_git rev-parse --short HEAD) || fb_fail "git rev-parse failed"
  ui_info "commit $FB_LAST_COMMIT  $1"
  FB_STAGE_COMMITS="$FB_STAGE_COMMITS $FB_LAST_COMMIT"
  return 0
}

# discard the interrupted block: tracked edits and the files it created
fb_rollback() {
  fb_git checkout -- . || fb_fail "git checkout -- . failed"
  fb_git clean -fdq || fb_fail "git clean failed"
}

fb_write_diff() {
  fb_git diff "$FB_START...HEAD" > "$FB_DIR/diff.patch" ||
    fb_fail "could not write the feature diff"
}

# --- claude ------------------------------------------------------------------

# fb_claude LABEL LOGBASE MODE(read|write) PROMPT [RESUME_SESSION]
# sets FB_OUT to the session's text result and FB_SESSION to its id
fb_claude() {
  local label="$1" logbase="$2" mode="$3" prompt="$4" resume="$5"
  local rc attempt=0 tools log args first

  [ "$mode" = write ] && tools="$FB_TOOLS_WRITE" || tools="$FB_TOOLS_READ"
  first=$(printf '%s' "$prompt" | head -1 | awk '{print substr($0, 1, 60)}')

  while :; do
    args=(-p "$prompt" --output-format json --allowedTools "$tools")
    [ "$mode" = write ] && args=("${args[@]}" --permission-mode acceptEdits)
    [ -n "$resume" ] && args=("${args[@]}" --resume "$resume")

    log=$(fb_log_path "$FB_LOG_STAGE" "$logbase")
    fb_run "$label" "$log" "claude -p \"$first...\"" -- claude "${args[@]}"
    rc=$?

    if [ $rc -eq 0 ] && fb_parse_envelope "$log"; then
      ui_block "$label" success "$FB_RUN_SECONDS" "$FB_RUN_CMD" "$log"
      return 0
    fi
    [ $rc -eq 0 ] && ui_error "the claude result envelope was missing or reported an error"
    ui_block "$label" failure "$FB_RUN_SECONDS" "$FB_RUN_CMD" "$log"
    ui_output "$log"

    # A write session may have edited files, run scripts or half-finished a
    # Spec Kit command before it failed. Rerunning it on our own could duplicate
    # or continue that work, so a write call is never retried automatically:
    # the user decides, and stopping is the default.
    if [ "$mode" = write ]; then
      ui_warning "that call could write files, and it may have written some before it failed"
      ui_gate "The \"$label\" call failed. What now?" \
        "q:Stop here — resume redoes this block from the last checkpoint" \
        "d:Discard every uncommitted change and retry the call" \
        "r:Retry the call and keep what it already wrote" || return 1
      case "$FB_CHOICE" in
        q) return 1 ;;
        d) fb_rollback ;;
      esac
      continue
    fi

    attempt=$((attempt + 1))
    if [ $attempt -ge 2 ]; then
      ui_gate "That call keeps failing. What now?" "r:Retry it" "q:Stop here" || return 1
      [ "$FB_CHOICE" = q ] && return 1
      attempt=0
    else
      ui_info "retrying"
    fi
  done
}

fb_parse_envelope() {
  jq -e '.type == "result" and (.is_error | not)' "$1" >/dev/null 2>&1 || return 1
  FB_SESSION=$(jq -r '.session_id // empty' "$1") || return 1
  FB_OUT=$(jq -r '.result // empty' "$1") || return 1
  return 0
}

# the tools own the findings; FeatureBandit shows them and keeps a copy
fb_report() {
  printf '%s\n' "$FB_OUT" > "$1" || fb_fail "could not write $1"
  ui_output "$1"
}

# --- config ------------------------------------------------------------------

fb_config_get() {
  [ -f "$FB_DIR/config" ] || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$1="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$FB_DIR/config"
  return 1
}

# --- verification gate -------------------------------------------------------

# Each configured command is a user-supplied shell expression, so it runs under
# one documented contract: `sh -c "<the line>"` in the repository root, as its
# own process. Never eval'd into this shell. Each gets its own log.
fb_verify() { # STAGE
  local i=1 cmd rc log passed=0
  FB_VERIFY_LOGS=""
  while :; do
    cmd=$(fb_config_get "VERIFY_COMMAND_$i") || break
    log=$(fb_log_path verification "$1")
    fb_run "Verification: $cmd" "$log" "$cmd" -- sh -c "$cmd"
    rc=$?
    FB_VERIFY_LOGS="$FB_VERIFY_LOGS $log"
    if [ $rc -ne 0 ]; then
      FB_FAIL_CMD="$cmd"
      FB_FAIL_LOG="$log"
      ui_block "Verification: $cmd" failure "$FB_RUN_SECONDS" "$cmd" "$log"
      ui_output "$log"
      FB_VERIFY_PASSED="$passed/$((passed + 1))"
      return 1
    fi
    ui_block "Verification: $cmd" success "$FB_RUN_SECONDS" "$cmd" "$log"
    ui_output "$log"
    passed=$((passed + 1))
    i=$((i + 1))
  done
  [ $i -eq 1 ] && fb_fail "no verification commands configured"
  FB_VERIFY_PASSED="$passed/$passed"
  return 0
}

# fb_verify_gate STAGE [FAILED_ALREADY] — verify, and on failure hand the
# failure to the superpowers debugging skill, invoked as a slash command so it
# really loads. With a second argument the caller has just run fb_verify itself
# and it failed, so the first run here is skipped.
fb_verify_gate() {
  local attempt=0 prefailed="${2:-}"
  while :; do
    if [ -n "$prefailed" ]; then
      prefailed=""
    else
      fb_verify "$1" && return 0
    fi
    attempt=$((attempt + 1))
    if [ $attempt -gt 3 ]; then
      ui_gate "Verification is still failing after three attempts." \
        "r:Retry verification" "s:Shell out and fix it myself" "q:Stop here" || return 1
      case "$FB_CHOICE" in
        r) attempt=0; continue ;;
        s) ui_info "exit the shell to return"; ( cd "$FB_ROOT" && "${SHELL:-/bin/sh}" ); attempt=0; continue ;;
        q) return 1 ;;
      esac
    fi
    fb_claude "Debugging the failing check (attempt $attempt)" "debug" write \
"/superpowers:systematic-debugging The command \`$FB_FAIL_CMD\` fails in $FB_ROOT during the $1 stage.

Output:
---
$(tail -60 "$FB_FAIL_LOG")
---

The specification this code must satisfy is $FB_SPEC. Fix the real defect so the
command passes. Never weaken, skip or delete a test. Do not commit." || return 1
    fb_assert_branch
  done
  return 0
}
