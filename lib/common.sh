#!/usr/bin/env bash
# ui helpers, claude call wrapper, git and verification helpers

FB_VERBOSE="${FEATUREBANDIT_VERBOSE:-0}"

if [ -t 1 ]; then
  FB_B=$(printf '\033[1m'); FB_D=$(printf '\033[2m'); FB_R=$(printf '\033[0m')
else
  FB_B=; FB_D=; FB_R=
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}" in
  *[Uu][Tt][Ff]*) FB_OK='✓'; FB_NO='✗'; FB_CUR='→'; FB_TODO='○'; FB_WARN='!' ;;
  *)              FB_OK='[x]'; FB_NO='[!]'; FB_CUR='[>]'; FB_TODO='[ ]'; FB_WARN='[!]' ;;
esac

# a stage that hangs is bounded where the utility exists (absent on stock macOS)
command -v timeout >/dev/null 2>&1 && FB_TIMEOUT="timeout 3600" || FB_TIMEOUT=""

FB_TOOLS_READ="Read Grep Glob Bash(git diff:*) Bash(git log:*) Bash(git status:*) Skill"
FB_TOOLS_WRITE="Read Write Edit Grep Glob Bash Skill"

say()  { printf '%s\n' "$*"; }
step() { printf '%s%s %s%s\n' "$FB_B" "$FB_CUR" "$*" "$FB_R"; }
info() { printf '%s  %s%s\n' "$FB_D" "$*" "$FB_R"; }
warn() { printf '%s %s\n' "$FB_WARN" "$*" >&2; }
die()  { printf '%s %s\n' "$FB_NO" "$*" >&2; exit 1; }

# fb_menu "prompt" "allowed letters" -> FB_CHOICE
fb_menu() {
  local ans
  while :; do
    printf '%s ' "$1"
    IFS= read -r ans || { ans=q; echo; }
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans" in
      ?) case "$2" in *"$ans"*) FB_CHOICE="$ans"; return 0 ;; esac ;;
    esac
    warn "choose one of: $2"
  done
}

# fb_ask "question" -> FB_ANSWER
fb_ask() {
  printf '%s\n> ' "$1"
  IFS= read -r FB_ANSWER || FB_ANSWER=""
}

fb_git() { git -C "$FB_ROOT" "$@"; }

fb_tree_clean() { [ -z "$(fb_git status --porcelain)" ]; }

fb_commit() {
  fb_git add -A
  if fb_git diff --cached --quiet; then
    info "nothing to commit"
    return 0
  fi
  fb_git commit -q -m "$1"
}

fb_diff() { fb_git diff "$(fb_state_get .startCommit)...HEAD"; }

# --- claude ------------------------------------------------------------------

# fb_claude LABEL MODE(read|write) TOOLS SCHEMA PROMPT_FILE [RESUME_SESSION]
# on success sets FB_OUT (structured output, or plain result when SCHEMA empty)
# and FB_SESSION
fb_claude() {
  local label="$1" mode="$2" tools="$3" schema="$4" pfile="$5" resume="$6"
  local raw rc attempt=0 args

  step "$label"
  while :; do
    args=(-p "$(cat "$pfile")" --output-format json)
    [ -n "$schema" ] && args=("${args[@]}" --json-schema "$schema")
    [ "$mode" = write ] && args=("${args[@]}" --permission-mode acceptEdits)
    [ -n "$tools" ] && args=("${args[@]}" --allowedTools "$tools")
    [ -n "$resume" ] && args=("${args[@]}" --resume "$resume")

    raw=$(cd "$FB_ROOT" && $FB_TIMEOUT claude "${args[@]}" 2>"$FB_TMP/claude.err")
    rc=$?

    if [ $rc -eq 0 ] && fb_parse_envelope "$raw" "$schema"; then
      [ "$FB_VERBOSE" = 1 ] && printf '%s' "$raw" | jq -r '.result // empty'
      return 0
    fi

    attempt=$((attempt + 1))
    if [ $attempt -ge 2 ]; then
      warn "claude call failed: $label"
      [ -s "$FB_TMP/claude.err" ] && tail -5 "$FB_TMP/claude.err" >&2
      fb_menu "[r] Retry  [q] Abort" "rq"
      [ "$FB_CHOICE" = q ] && return 1
      attempt=0
    else
      info "retrying"
    fi
  done
}

fb_parse_envelope() {
  local raw="$1" schema="$2"
  printf '%s' "$raw" | jq -e '.type == "result" and (.is_error | not)' >/dev/null 2>&1 || return 1
  FB_SESSION=$(printf '%s' "$raw" | jq -r '.session_id // empty')
  if [ -n "$schema" ]; then
    FB_OUT=$(printf '%s' "$raw" | jq -ce '.structured_output' 2>/dev/null) || return 1
    [ -n "$FB_OUT" ] && [ "$FB_OUT" != null ] || return 1
  else
    FB_OUT=$(printf '%s' "$raw" | jq -r '.result // empty')
  fi
  return 0
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

# runs every configured command in order; on failure sets FB_FAIL_CMD and
# leaves that command's output in verify.log
fb_verify() {
  local i=1 cmd rc
  while :; do
    cmd=$(fb_config_get "VERIFY_COMMAND_$i") || break
    [ -n "$cmd" ] || break
    step "Verify: $cmd"
    : > "$FB_DIR/verify.log"
    ( cd "$FB_ROOT" && eval "$cmd" ) >> "$FB_DIR/verify.log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      FB_FAIL_CMD="$cmd"
      warn "failed (exit $rc): $cmd"
      tail -20 "$FB_DIR/verify.log"
      return 1
    fi
    i=$((i + 1))
  done
  [ $i -eq 1 ] && info "no verification commands configured"
  return 0
}

# fb_verify_gate "stage label" — verify, and on failure run bounded fix sessions
fb_verify_gate() {
  local attempt=0
  while ! fb_verify; do
    attempt=$((attempt + 1))
    if [ $attempt -gt 3 ]; then
      fb_menu "[r] Retry verification  [s] Shell out and fix manually  [q] Abort" "rsq"
      case "$FB_CHOICE" in
        r) attempt=0; continue ;;
        s) info "exit the shell to return"; ( cd "$FB_ROOT" && "${SHELL:-/bin/sh}" ); attempt=0; continue ;;
        q) return 1 ;;
      esac
    fi
    cat > "$FB_TMP/fixverify" <<EOF
The verification gate for stage "$1" is failing in the repository at $FB_ROOT.

Command that failed:
  $FB_FAIL_CMD

Output:
---
$(cat "$FB_DIR/verify.log")
---

Specification (the behavior that must hold):
---
$(cat "$FB_DIR/spec.md" 2>/dev/null)
---

Fix the cause so the command passes. Rules:
- Fix the real defect. Never weaken, skip, or delete a test to make it pass.
- Do not change behavior that the specification requires.
- Follow the engineering guide at $FB_DIR/guide.md.
- Run the failing command yourself to confirm it passes before you finish.
EOF
    fb_claude "Fixing failing checks (attempt $attempt)" write "$FB_TOOLS_WRITE" "" "$FB_TMP/fixverify" || return 1
  done
  return 0
}
