#!/usr/bin/env bash
# Checks the real integration points against the installed tools, not the stub.
#
#   test/e2e.sh              free checks: plugins, agent files, the Spec Kit layout
#   test/e2e.sh --dispatch   plus three real `claude -p` calls: one agent dispatch
#                            and the two Superpowers skills the pipeline invokes
#   test/e2e.sh --full       plus one complete real pipeline — every Spec Kit
#                            command, the review agents, Code Simplifier and
#                            /security-review — in a throwaway repository
#
# --dispatch and --full make real Claude Code calls and cost real money; --full
# takes as long as building a small feature actually takes. Both need the three
# plugins installed and the Spec Kit CLI on PATH (`specify`).

fails=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
  else printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

FB_SRC=$(cd -- "$(dirname -- "$0")/.." && pwd)
SPECKIT_INIT="specify init --here --force --non-interactive --integration claude"

echo "plugins installed and enabled"
list=$(claude plugin list --json 2>/dev/null) || list='[]'
for p in superpowers pr-review-toolkit code-simplifier; do
  check "$p" "true" "$(printf '%s' "$list" |
    jq -r --arg n "$p" 'map(select((.id|split("@")[0]) == $n and .enabled)) | length > 0')"
done

echo "agent files the pipeline names"
root=$(printf '%s' "$list" | jq -r 'map(select((.id|split("@")[0]) == "pr-review-toolkit"))[0].installPath // empty')
for a in code-reviewer pr-test-analyzer silent-failure-hunter type-design-analyzer comment-analyzer; do
  check "pr-review-toolkit:$a" "1" "$([ -n "$root" ] && [ -f "$root/agents/$a.md" ] && echo 1 || echo 0)"
done
sroot=$(printf '%s' "$list" | jq -r 'map(select((.id|split("@")[0]) == "code-simplifier"))[0].installPath // empty')
check "code-simplifier:code-simplifier" "1" "$([ -n "$sroot" ] && [ -f "$sroot/agents/code-simplifier.md" ] && echo 1 || echo 0)"

# a repository Spec Kit has really initialised: this one if it is, otherwise a
# throwaway one, so the layout check is about Spec Kit and not about this clone
scratch_repo() { # DIRECTORY
  mkdir -p "$1" && cd "$1" || return 1
  git init -q -b main .
  git config user.email e2e@featurebandit && git config user.name e2e
  printf 'test:\n\t@sh ./greet_test.sh\n' > Makefile
  printf 'placeholder\n' > README.md
  git add -A && git commit -qm init
  command -v specify >/dev/null 2>&1 || return 1
  $SPECKIT_INIT >/dev/null 2>&1 || return 1
  git add -A && git commit -qm "Initialise GitHub Spec Kit" >/dev/null 2>&1
  return 0
}

speckit_layout() { # DIRECTORY
  if [ -f "$1/.claude/skills/speckit-specify/SKILL.md" ]; then printf '/speckit-'
  elif [ -f "$1/.claude/commands/speckit.specify.md" ]; then printf '/speckit.'
  fi
}

WORK=""
REPO=$(pwd)
sk=$(speckit_layout "$REPO")
if [ -z "$sk" ]; then
  if command -v specify >/dev/null 2>&1; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbe2e.XXXXXX")
    echo "this repository has no Spec Kit layout — initialising one in $WORK/repo"
    scratch_repo "$WORK/repo" && REPO="$WORK/repo"
    sk=$(speckit_layout "$REPO")
  else
    echo "the Spec Kit CLI is not installed: $SPECKIT_INIT needs it"
    echo "  uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
  fi
fi

echo "spec kit layout in $REPO"
check "a spec kit layout is present" "1" "$([ -n "$sk" ] && echo 1 || echo 0)"
if [ -n "$sk" ]; then
  for c in specify clarify checklist plan tasks analyze implement converge; do
    if [ "$sk" = "/speckit-" ]; then f="$REPO/.claude/skills/speckit-$c/SKILL.md"
    else f="$REPO/.claude/commands/speckit.$c.md"; fi
    check "$sk$c" "1" "$([ -f "$f" ] && echo 1 || echo 0)"
  done
fi

case "$1" in --dispatch|--full)
  echo "real claude calls"
  ask() { claude -p "$1" --output-format json --allowedTools "$2" 2>/dev/null | jq -r '.result // ""'; }

  out=$(ask 'Dispatch the Agent tool exactly once with subagent_type "pr-review-toolkit:code-reviewer" and ask it only whether this repository has a README. Then reply with exactly DISPATCH-OK, or DISPATCH-FAIL and the error.' "Agent Read Glob Grep")
  check "pr-review-toolkit:code-reviewer dispatches" "1" "$(printf '%s' "$out" | grep -c 'DISPATCH-OK' || true)"

  out=$(ask '/superpowers:test-driven-development Reply with exactly TDD-LOADED and nothing else. Write no code.' "Read Skill")
  check "/superpowers:test-driven-development loads" "1" "$(printf '%s' "$out" | grep -c 'TDD-LOADED' || true)"

  out=$(ask '/superpowers:systematic-debugging Reply with exactly DEBUG-LOADED and nothing else. Investigate nothing.' "Read Skill")
  check "/superpowers:systematic-debugging loads" "1" "$(printf '%s' "$out" | grep -c 'DEBUG-LOADED' || true)"
  ;;
*)
  echo "real claude calls: skipped (pass --dispatch to run them)"
  ;;
esac

# --- the whole pipeline, for real --------------------------------------------
# One feature, small enough to be cheap and real enough to exercise every stage.
# It runs off a terminal, so the approvals are passed up front and the run stops
# rather than guessing: a,a,c,a,a,a is accept the detected verification command,
# approve the specification, send nothing back from analyze, approve the plan,
# accept the review findings, accept the security findings.
if [ "$1" = --full ]; then
  echo
  echo "full pipeline against the real tools"
  if [ -z "$sk" ]; then
    check "a repository to run in" "1" "0"
  else
    [ -n "$WORK" ] || WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbe2e.XXXXXX")
    if [ ! -d "$WORK/repo" ]; then
      scratch_repo "$WORK/repo" || { echo "  could not prepare $WORK/repo"; fails=$((fails + 1)); }
    fi
    cd "$WORK/repo" || exit 1
    echo "  repository: $WORK/repo"
    printf 'no\nno\nno\nno\nno\n' |
      FEATUREBANDIT_INSTALL=1 FEATUREBANDIT_CHOICES='a,a,c,a,a,a' \
      "$FB_SRC/featurebandit" \
      "Add greet.sh with a greet function that prints \"hello <name>\", and greet_test.sh that checks it. make test must run greet_test.sh."
    rc=$?
    check "the pipeline finished"  "0" "$rc"
    check "reached the last stage" "1" "$("$FB_SRC/featurebandit" status 2>&1 | grep -c 'Continues at: finished')"
    check "on a feature branch"    "1" "$(git rev-parse --abbrev-ref HEAD | grep -c '^featurebandit/')"
    check "working tree clean"     ""  "$(git status --porcelain)"
    check "a specification is committed" "1" "$(git ls-files 'specs/*/spec.md' | wc -l | tr -d ' ' | grep -c '^[1-9]')"
    check "every task is done"     "0" "$(cat specs/*/tasks.md 2>/dev/null | grep -c '^- \[ \] T' || true)"
    check "make test passes"       "0" "$(make test >/dev/null 2>&1; echo $?)"
    check "commits on the branch"  "1" "$(git log --oneline main..HEAD | grep -c featurebandit | grep -c '^[1-9]')"
    check "main is untouched"      "0" "$(git log --oneline main | grep -c featurebandit || true)"
  fi
fi

[ -n "$WORK" ] && echo && echo "the throwaway repository is kept at $WORK — remove it when you are done"

echo
if [ $fails -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
