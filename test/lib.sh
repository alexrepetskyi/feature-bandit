#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2012
#   HAPPY, CLARIFY and GUM_HAPPY are read by the suites that source this file.
# Shared scaffolding for the FeatureBandit tests: a stubbed claude on PATH and
# throwaway git repositories that look like Spec Kit projects.

FB_SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbtest.XXXXXX")
BIN="$WORK/bin"
mkdir -p "$BIN" && cp "$FB_SRC/test/fake-claude" "$BIN/claude"
cp "$FB_SRC/test/fake-gum" "$BIN/gum"
export PATH="$BIN:$PATH"
export FAKE_LOG="$WORK/calls.log"

FB=$FB_SRC/featurebandit
fails=0

check() { # check "name" "expected" "actual"
  if [ "$2" = "$3" ]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# a repository with a test runner and Spec Kit initialised for claude
new_repo() {
  rm -rf "${WORK:?}/$1" && mkdir -p "$WORK/$1" && cd "$WORK/$1" || exit 1
  : > "$FAKE_LOG"
  unset FAKE_EXIT_ON FAKE_CONVERGE_ADD FAKE_NO_PLUGIN FAKE_UNTRACKED
  unset FAKE_CLARIFY_NONE FAKE_CHECKLIST_OPEN FAKE_HIJACK_ON FAKE_CLARIFY_TABLE
  unset FAKE_SLOW FAKE_EXIT_CODE FAKE_NOISY FAKE_INSTALL_EXIT
  export FAKE_INSTALL_DIR="$WORK/installed"; rm -rf "$FAKE_INSTALL_DIR"; mkdir -p "$FAKE_INSTALL_DIR"
  export FAKE_GUM_QUEUE="$WORK/gum.queue"; : > "$FAKE_GUM_QUEUE"
  export FAKE_GUM_LOG="$WORK/gum.log"; : > "$FAKE_GUM_LOG"
  unset FEATUREBANDIT_TTY
  git init -q -b main .
  git config user.email test@test && git config user.name test
  printf 'test:\n\t@echo tests pass\n' > Makefile
  # spec kit's claude integration installs skills, not slash-command files
  mkdir -p .specify
  printf '{"integration":"claude"}\n' > .specify/integration.json
  for c in specify clarify checklist plan tasks analyze implement converge; do
    mkdir -p ".claude/skills/speckit-$c"
    printf -- '---\nname: "speckit-%s"\n---\n' "$c" > ".claude/skills/speckit-$c/SKILL.md"
  done
  git add -A && git commit -qm init
}

# Off a terminal, gates are answered up front and only free text comes from
# stdin. HAPPY is: accept the detected verify commands, approve the spec,
# nothing to send back from analyze, approve the plan, accept the review
# findings, accept the security findings.
HAPPY='a,a,c,a,a,a'
CLARIFY='no localisation
'

# fb_run_happy [extra,choices] — run the pipeline with the standard answers
fb_run_happy() {
  local choices="$HAPPY${1:+,$1}"
  printf '%s' "$CLARIFY" | FEATUREBANDIT_CHOICES="$choices" "$FB" "${2:-Add greeting}"
}

finish() {
  cd / && rm -rf "$WORK"
  echo
  if [ $fails -eq 0 ]; then
    echo "all checks passed"
  else
    echo "$fails check(s) failed"
    exit 1
  fi
}

# queue answers for the fake gum, one per line
gum_queue() { printf '%s\n' "$@" > "$FAKE_GUM_QUEUE"; }

# run the pipeline through the interactive (gum) path
fb_run_tty() {
  gum_queue "$@"
  FEATUREBANDIT_TTY=1 "$FB" "Add greeting" < /dev/null
}

# the answers the interactive path needs for a clean run, in order
GUM_HAPPY=("Accept them" "no localisation" "Approve it" "Nothing to send back"
           "Approve it" "Accept the open findings" "Accept the open findings")

# PATH with every directory that holds a gum binary removed
nogum_path() {
  local d out="" oldifs="$IFS"
  IFS=:
  for d in $PATH; do [ -x "$d/gum" ] || out="$out:$d"; done
  IFS="$oldifs"
  printf '%s' "${out#:}"
}

# how many `sleep` helpers this machine is running right now
sleepers() { pgrep -f '^sleep 1$' 2>/dev/null | wc -l | tr -d ' '; }

# Start a run in the background and set RUNNER to featurebandit's own pid — not
# a wrapper subshell's, or a Ctrl-C would never reach the thing being tested.
# No pipeline, so `$!` is the process itself.
fb_start_bg() { # [extra,choices]
  FEATUREBANDIT_CHOICES="$HAPPY${1:+,$1}" "$FB" "Add greeting" > "$WORK/o" 2>&1 < /dev/null &
  RUNNER=$!
}

# interrupt that run the way a terminal would, and wait for it to be gone
fb_interrupt_bg() {
  kill -INT "$RUNNER" 2>/dev/null
  wait "$RUNNER" 2>/dev/null
}

count()   { grep -c -- "$1" "$2" 2>/dev/null || true; }
nonzero() { [ "${1:-0}" -gt 0 ] && echo 1 || echo 0; }
