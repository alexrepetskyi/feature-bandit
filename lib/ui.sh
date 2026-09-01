#!/usr/bin/env bash
# Presentation only. Gum styles and asks; this file decides what to render.
# Nothing here touches pipeline state, git or exit codes.
# shellcheck disable=SC2034
#   The FB_* variables set here are read by the other lib/*.sh files and by
#   featurebandit, which shellcheck cannot follow across the runtime `source`.

# --- capability detection ----------------------------------------------------

# FEATUREBANDIT_TTY forces interactive rendering on (1) or off (0).
if [ -n "${FEATUREBANDIT_TTY:-}" ]; then
  FB_TTY=$FEATUREBANDIT_TTY
else
  case "${TERM:-dumb}" in
    dumb|"") FB_TTY=0 ;;
    *) { [ -t 1 ] && [ -t 2 ]; } && FB_TTY=1 || FB_TTY=0 ;;
  esac
  [ -n "${CI:-}" ] && FB_TTY=0
fi
[ -n "${NO_COLOR+x}" ] && FB_COLOR=0 || FB_COLOR=$FB_TTY

if [ "$FB_COLOR" = 1 ]; then
  FB_BOLD=$(printf '\033[1m'); FB_DIM=$(printf '\033[2m')
  FB_GRN=$(printf '\033[32m'); FB_YEL=$(printf '\033[33m')
  FB_RED=$(printf '\033[31m'); FB_CYA=$(printf '\033[36m')
  FB_OFF=$(printf '\033[0m')
else
  FB_BOLD=; FB_DIM=; FB_GRN=; FB_YEL=; FB_RED=; FB_CYA=; FB_OFF=
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}" in
  *[Uu][Tt][Ff]*) FB_S_STAGE='◆'; FB_S_RUN='→'; FB_S_OK='✓'; FB_S_NO='✗'
                  FB_S_WARN='!';  FB_S_ASK='?'; FB_S_DOT='•'; FB_S_TODO='○' ;;
  *)              FB_S_STAGE='#'; FB_S_RUN='>'; FB_S_OK='+'; FB_S_NO='x'
                  FB_S_WARN='!';  FB_S_ASK='?'; FB_S_DOT='-'; FB_S_TODO='.' ;;
esac

FB_RULE='────────────────────────────────────────────────────────────'
[ "$FB_TTY" = 1 ] || FB_RULE='------------------------------------------------------------'

# every status line goes to stderr; captured output is kept in its own log
ui_err() { printf '%s\n' "$*" >&2; }

ui_rule()    { ui_err "$FB_DIM$FB_RULE$FB_OFF"; }
ui_info()    { ui_err "$FB_CYA$FB_S_DOT$FB_OFF $*"; }
ui_warning() { ui_err "$FB_YEL$FB_S_WARN $*$FB_OFF"; }
ui_error()   { ui_err "$FB_RED$FB_S_NO $*$FB_OFF"; }
ui_command() { ui_err "$FB_DIM  \$ $*$FB_OFF"; }
ui_detail()  { ui_err "$FB_DIM  $*$FB_OFF"; }

ui_stage_start() { # N TOTAL NAME DESCRIPTION
  ui_err ""
  ui_err "$FB_CYA$FB_BOLD$FB_S_STAGE $1/$2 · $3$FB_OFF"
  [ -n "$4" ] && ui_detail "$4"
  ui_err ""
}

ui_stage_summary() { # NAME STATUS SECONDS  (then extra lines on stdin)
  local mark colour
  case "$2" in
    success) mark=$FB_S_OK;   colour=$FB_GRN ;;
    waiting) mark=$FB_S_ASK;  colour=$FB_YEL ;;
    *)       mark=$FB_S_NO;   colour=$FB_RED ;;
  esac
  ui_err ""
  ui_rule
  case "$2" in
    success) ui_err "$colour$mark $1 completed in $(ui_duration "$3")$FB_OFF" ;;
    waiting) ui_err "$colour$mark $1 is waiting for you$FB_OFF" ;;
    *)       ui_err "$colour$mark $1 stopped after $(ui_duration "$3")$FB_OFF" ;;
  esac
  while IFS= read -r line; do [ -n "$line" ] && ui_detail "$line"; done
  ui_rule
  ui_err ""
}

ui_duration() {
  local s=$1
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  else printf '%dm %02ds' $((s / 60)) $((s % 60)); fi
}

# --- pipeline overview -------------------------------------------------------

# Renders the stages from the real checkpoints; it stores nothing of its own.
# ui_pipeline ACTIVE_STAGE ACTIVE_STATE
ui_pipeline() {
  local s mark colour label
  ui_err ""
  for s in $FB_STAGES; do
    label=$(fb_ckpt_label "$s")
    if [ "$s" = "$1" ]; then
      case "$2" in
        running)  mark=$FB_S_RUN;  colour=$FB_CYA; label="$label  (running)" ;;
        waiting)  mark=$FB_S_ASK;  colour=$FB_YEL; label="$label  (awaiting approval)" ;;
        failed)   mark=$FB_S_NO;   colour=$FB_RED; label="$label  (stopped)" ;;
        *)        mark=$FB_S_RUN;  colour=$FB_CYA; label="$label  (next)" ;;
      esac
    elif [ "$(fb_state_get ".checkpoints.$s")" = true ]; then
      mark=$FB_S_OK; colour=$FB_GRN
      label="$label$(ui_stage_recorded "$s")"
    else
      mark=$FB_S_TODO; colour=$FB_DIM
    fi
    ui_err "$colour$mark $label$FB_OFF"
  done
  ui_err ""
}

ui_stage_recorded() {
  local d
  d=$(fb_state_get ".durations.$1 // empty")
  [ -n "$d" ] && printf '  (%s)' "$(ui_duration "$d")"
}

# --- long-running steps ------------------------------------------------------
# Gum's spinner shows a static title, so elapsed seconds come from this timer.
# It renders to stderr only, and is always torn down through ui_step_stop.

FB_TIMER_PID=""

ui_step_start() { # LABEL
  if [ "$FB_TTY" = 1 ]; then
    ui_timer_tty "$1" &
  else
    ui_err "$FB_CYA$FB_S_RUN $1$FB_OFF"
    ui_timer_plain "$1" &
  fi
  FB_TIMER_PID=$!
}

ui_timer_tty() {
  local frames='|/-' i=0 t0=$SECONDS e
  while :; do
    e=$((SECONDS - t0))
    printf '\r%s%s %s · %ss%s\033[K' \
      "$FB_CYA" "${frames:$((i % 3)):1}" "$1" "$e" "$FB_OFF" >&2
    i=$((i + 1))
    sleep 1
  done
}

# no cursor movement anywhere off a terminal: one plain line now and then.
# One-second sleeps so that killing this loop can never orphan a long sleep.
ui_timer_plain() {
  local t0=$SECONDS n=0
  while :; do
    sleep 1
    n=$((n + 1))
    [ $((n % 15)) -eq 0 ] &&
      printf '%s %s · still running, %ss\n' "$FB_S_RUN" "$1" "$((SECONDS - t0))" >&2
  done
}

ui_timer_stop() {
  [ -n "$FB_TIMER_PID" ] || return 0
  kill "$FB_TIMER_PID" 2>/dev/null
  wait "$FB_TIMER_PID" 2>/dev/null
  FB_TIMER_PID=""
  [ "$FB_TTY" = 1 ] && printf '\r\033[K' >&2
  return 0
}

ui_step_success() { # LABEL SECONDS
  ui_timer_stop
  ui_err "$FB_GRN$FB_S_OK $1 completed in $(ui_duration "$2")$FB_OFF"
}

ui_step_failure() { # LABEL SECONDS EXITCODE
  ui_timer_stop
  ui_err "$FB_RED$FB_S_NO $1 failed after $(ui_duration "$2") · exit $3$FB_OFF"
}

# --- captured output ---------------------------------------------------------

FB_PREVIEW_LINES=30

# a bounded preview of one file; the file itself is never truncated
ui_preview() {
  local file="$1" total hidden
  total=$(wc -l < "$file" | tr -d ' ')
  if [ "$total" -le "$FB_PREVIEW_LINES" ]; then
    sed 's/^/  /' "$file" >&2
  else
    hidden=$((total - FB_PREVIEW_LINES))
    ui_detail "... $hidden earlier line(s) not shown, the log keeps all of them"
    tail -n "$FB_PREVIEW_LINES" "$file" | sed 's/^/  /' >&2
  fi
}

# ui_output LOGFILE — preview stdout, then stderr if there was any
ui_output() {
  local file="$1"
  ui_err ""
  if [ -s "$file" ]; then
    ui_preview "$file"
  else
    ui_detail "(no output)"
  fi
  if [ -s "$file.err" ]; then
    ui_err ""
    ui_detail "stderr:"
    ui_preview "$file.err"
  fi
  ui_err ""
  ui_detail "Full output: $(fb_rel "$file")"
  [ -s "$file.err" ] && ui_detail "             $(fb_rel "$file").err"
  return 0
}

# ui_block LABEL STATUS SECONDS COMMAND LOGFILE — the frame after a finished block
ui_block() {
  local mark colour
  if [ "$2" = success ]; then mark=$FB_S_OK; colour=$FB_GRN
  else mark=$FB_S_NO; colour=$FB_RED; fi
  ui_rule
  ui_err "$colour$mark $1$FB_OFF"
  ui_detail "Status:   $2"
  ui_detail "Duration: $(ui_duration "$3")"
  [ -n "$4" ] && ui_detail "Command:  $4"
  [ -n "$5" ] && ui_detail "Output:   $(fb_rel "$5")"
  ui_rule
}

# --- asking the user ---------------------------------------------------------
# Gum owns the interaction; the shell owns what the answer means.
# Off a terminal there is no interaction at all: the decision must have been
# passed in FEATUREBANDIT_CHOICES, or the run stops rather than guessing.

FB_CHOICES_LEFT="${FEATUREBANDIT_CHOICES:-}"

# ui_gate "prompt" "a:Label" "b:Label" ... -> FB_CHOICE; non-zero if cancelled
ui_gate() {
  local prompt="$1" o letters="" labels=() picked
  shift
  for o in "$@"; do letters="$letters${o%%:*}"; labels+=("${o#*:}"); done

  if [ "$FB_TTY" != 1 ]; then
    ui_gate_preset "$prompt" "$letters" "$@"
    return $?
  fi

  ui_err ""
  if ! picked=$(gum choose --header "$FB_S_ASK $prompt" --height $(( ${#labels[@]} + 2 )) \
    --selected "${labels[0]}" "${labels[@]}") || [ -z "$picked" ]; then
    ui_warning "selection cancelled"
    return 1
  fi
  for o in "$@"; do
    if [ "${o#*:}" = "$picked" ]; then
      FB_CHOICE="${o%%:*}"
      ui_err "$FB_YEL$FB_S_ASK $prompt$FB_OFF $picked"
      return 0
    fi
  done
  ui_error "gum returned an option that was not offered: $picked"
  return 1
}

# fail closed: an approval that was never given is not an approval
ui_gate_preset() {
  local prompt="$1" letters="$2" next rest o
  shift 2
  ui_err ""
  ui_err "$FB_YEL$FB_S_ASK $prompt$FB_OFF"
  for o in "$@"; do ui_detail "[${o%%:*}] ${o#*:}"; done
  if [ -z "$FB_CHOICES_LEFT" ]; then
    ui_error "no terminal and no decision left in FEATUREBANDIT_CHOICES"
    ui_detail "pass the answers up front, for example:"
    ui_detail "  FEATUREBANDIT_CHOICES=${letters:0:1},... featurebandit \"...\""
    return 1
  fi
  case "$FB_CHOICES_LEFT" in
    *,*) next=${FB_CHOICES_LEFT%%,*}; rest=${FB_CHOICES_LEFT#*,} ;;
    *)   next=$FB_CHOICES_LEFT; rest="" ;;
  esac
  FB_CHOICES_LEFT="$rest"
  next=$(printf '%s' "$next" | tr '[:upper:]' '[:lower:]')
  case "$letters" in
    *"$next"*) FB_CHOICE="$next"; ui_detail "chose [$next] (FEATUREBANDIT_CHOICES)"; return 0 ;;
  esac
  ui_error "FEATUREBANDIT_CHOICES gave \"$next\", which is not one of [$letters]"
  return 1
}

# ui_confirm "question" -> 0 yes, 1 no; same fail-closed rule off a terminal.
# gum confirm answers 0 for yes and 1 for no; anything else is gum failing, not
# the user saying no, and is reported as the error it is.
ui_confirm() {
  local rc
  if [ "$FB_TTY" != 1 ]; then
    ui_gate_preset "$1" "yn" "n:No" "y:Yes" || return 1
    [ "$FB_CHOICE" = y ]
    return $?
  fi
  gum confirm "$1" --default=false --affirmative "Yes" --negative "No"
  rc=$?
  case $rc in
    0) return 0 ;;
    1) return 1 ;;
    *) ui_error "gum confirm failed (exit $rc) — treating it as no"; return 1 ;;
  esac
}

# ui_answer "question" "A:text" "B:text" ... -> FB_ANSWER
# When the tool offered its own options, they are drawn as a menu and the answer
# is the option's own key — the labels and the keys are the tool's, not ours.
# No options, no terminal, or "type my own" all fall back to free text.
ui_answer() {
  local header="$1" o labels=() picked
  shift
  if [ "$FB_TTY" != 1 ] || [ $# -eq 0 ]; then
    ui_prompt "$header"
    return 0
  fi
  for o in "$@"; do labels+=("${o%%:*} — ${o#*:}"); done
  labels+=("Type my own answer")
  ui_err ""
  if ! picked=$(gum choose --header "$FB_S_ASK $header" \
      --height $(( ${#labels[@]} + 2 )) "${labels[@]}") || [ -z "$picked" ]; then
    FB_ANSWER=""
    return 0
  fi
  if [ "$picked" = "Type my own answer" ]; then
    ui_prompt "$header"
    return 0
  fi
  FB_ANSWER=${picked%% — *}
  ui_err "$FB_YEL$FB_S_ASK $header$FB_OFF $picked"
  return 0
}

# ui_prompt "question" -> FB_ANSWER; free text, never an approval
ui_prompt() {
  ui_err ""
  if [ "$FB_TTY" = 1 ]; then
    FB_ANSWER=$(gum input --header "$FB_S_ASK $1" --placeholder "leave empty when you are done") ||
      FB_ANSWER=""
  else
    ui_err "$FB_YEL$FB_S_ASK $1$FB_OFF"
    printf '> ' >&2
    IFS= read -r FB_ANSWER || FB_ANSWER=""
  fi
}
