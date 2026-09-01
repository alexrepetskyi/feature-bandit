#!/usr/bin/env bash
# one function per pipeline stage; the shell decides, claude engineers

FB_SCHEMA_REQ='{"type":"object","additionalProperties":false,"properties":{"context_summary":{"type":"string"},"gaps":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string"},"severity":{"type":"string","enum":["BLOCKING","IMPORTANT","OPTIONAL"]},"question":{"type":"string"}},"required":["id","severity","question"]}}},"required":["context_summary","gaps"]}'

FB_SCHEMA_VERDICT='{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["PASS","FAIL","NEEDS_USER_INPUT"]},"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string"},"severity":{"type":"string","enum":["BLOCKING","CRITICAL","HIGH","MEDIUM","LOW","NIT"]},"requirement":{"type":"string"},"type":{"type":"string"},"message":{"type":"string"}},"required":["id","severity","message"]}}},"required":["status","findings"]}'

FB_SCHEMA_PLAN='{"type":"object","additionalProperties":false,"properties":{"tasks":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string"},"title":{"type":"string"},"covers":{"type":"array","items":{"type":"string"}},"files":{"type":"array","items":{"type":"string"}},"steps":{"type":"array","items":{"type":"string"}},"status":{"type":"string","enum":["pending","done"]}},"required":["id","title","covers","files","steps","status"]}}},"required":["tasks"]}'

FB_SCHEMA_TASK='{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["DONE","SPEC_PROBLEM"]},"detail":{"type":"string"}},"required":["status","detail"]}'

FB_SCHEMA_COMPLIANCE='{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["PASS","FAIL"]},"requirements":{"type":"object","additionalProperties":{"type":"string"}},"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string"},"severity":{"type":"string","enum":["BLOCKING","HIGH","MEDIUM","LOW"]},"requirement":{"type":"string"},"message":{"type":"string"}},"required":["id","severity","requirement","message"]}}},"required":["status","requirements","findings"]}'

FB_SCHEMA_FINAL='{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["PASS","PASS_WITH_ACCEPTED_RISKS","FAIL"]},"summary":{"type":"string"}},"required":["status","summary"]}'

# --- shared pieces -----------------------------------------------------------

fb_prior_specs() {
  local f found=0
  for f in "$FB_ROOT"/docs/specs/*.md; do
    [ -f "$f" ] || continue
    [ $found -eq 0 ] && say "Previously approved specifications in this repository (already implemented behavior this feature builds on — read them):"
    found=1
    say "  ${f#$FB_ROOT/}"
  done
  [ $found -eq 1 ] && say "A change to any behavior they define must be stated explicitly in the new specification as superseding it."
}

fb_print_findings() {
  printf '%s' "$1" | jq -r '.findings[]? | "  [\(.severity)] \(.id // .requirement // "-"): \(.message)"'
}

fb_record_risks() {
  {
    printf '\n## Accepted risks — %s\n\n' "$1"
    printf '%s' "$2" | jq -r '.findings[]? | "- [\(.severity)] \(.message)"'
  } >> "$FB_DIR/decisions.md"
  printf '%s' "$2" | jq -r '.findings[]? | "\(.severity): \(.message)"' | while IFS= read -r r; do
    fb_add_risk "$1 — $r"
  done
}

fb_approve() {
  say ""
  say "$FB_B$1 ready$FB_R (${2#$FB_ROOT/})"
  while :; do
    fb_menu "[a] Approve and continue  [v] View it  [q] Stop here" "avq"
    case "$FB_CHOICE" in
      v) ${PAGER:-cat} "$2" ;;
      a) return 0 ;;
      q) return 1 ;;
    esac
  done
}

# fb_review_cycle LABEL REVIEW_FN FIX_FN OUTFILE — interactive, for spec and plan
fb_review_cycle() {
  local label="$1" review_fn="$2" fix_fn="$3" outfile="$4" status
  while :; do
    $review_fn || return 1
    printf '%s' "$FB_OUT" | jq . > "$outfile"
    status=$(printf '%s' "$FB_OUT" | jq -r '.status')
    if [ "$status" = PASS ]; then
      say "$FB_OK $label review: PASS"
      return 0
    fi
    say ""
    say "$FB_B$label review: $status$FB_R"
    fb_print_findings "$FB_OUT"
    fb_menu "[f] Fix findings  [a] Accept as risks  [c] Continue anyway  [q] Abort" "facq"
    case "$FB_CHOICE" in
      f) $fix_fn || return 1 ;;
      a|c) fb_record_risks "$label" "$FB_OUT"; return 0 ;;
      q) return 1 ;;
    esac
  done
}

# fb_blocking_cycle LABEL REVIEW_FN FIX_FN OUTFILE BLOCKING_JQ — automatic, bounded
fb_blocking_cycle() {
  local label="$1" review_fn="$2" fix_fn="$3" outfile="$4" filter="$5" iter=0 blocking
  while :; do
    $review_fn || return 1
    printf '%s' "$FB_OUT" | jq . > "$outfile"
    blocking=$(printf '%s' "$FB_OUT" | jq "$filter")
    if [ "$blocking" -eq 0 ]; then
      say "$FB_OK $label: no blocking findings"
      fb_print_findings "$FB_OUT"
      return 0
    fi
    say ""
    say "$FB_B$label: $blocking blocking finding(s)$FB_R"
    fb_print_findings "$FB_OUT"
    iter=$((iter + 1))
    if [ $iter -gt 3 ]; then
      warn "$label: still blocking after 3 automatic fix rounds"
      fb_menu "[f] Keep fixing  [a] Accept as risks  [q] Abort" "faq"
      case "$FB_CHOICE" in
        a) fb_record_risks "$label" "$FB_OUT"; return 0 ;;
        q) return 1 ;;
      esac
      iter=0
    fi
    $fix_fn || return 1
    fb_verify_gate "$label" || return 1
    fb_commit "featurebandit: $label: fix findings"
  done
}

fb_write_diff() { fb_diff > "$FB_DIR/diff.patch"; }

# --- 5.2 requirements --------------------------------------------------------

fb_stage_requirements() {
  local sid gaps n i sev q id qa="" round=0

  cat > "$FB_TMP/p" <<EOF
You are the requirements analyst for one feature in the repository at $FB_ROOT.

Raw requirements, verbatim:
---
$(cat "$FB_DIR/requirements.md")
---

$(fb_prior_specs)

Do this:
1. Explore the repository: the modules this feature touches, the conventions in
   use, how tests are written and run, what already exists that must be reused.
2. Read every specification listed above, if any.
3. Produce a short markdown context summary: what exists today, what this feature
   touches, which files matter, which existing behavior constrains it.
4. List the gaps that must be closed before a specification can be written.

Rules for gaps:
- Only real ambiguities whose answer changes the implementation.
- No filler questions, no questions the repository already answers.
- BLOCKING means the specification cannot be written without the answer.
- Each gap is one concrete question a developer can answer in one sentence.

Do not write code. Do not modify any file.
EOF

  fb_claude "Exploring repository and requirements" read "$FB_TOOLS_READ" "$FB_SCHEMA_REQ" "$FB_TMP/p" || return 1
  sid="$FB_SESSION"
  printf '%s' "$FB_OUT" | jq -r '.context_summary' > "$FB_DIR/context.md"
  printf '# Decisions\n\n' > "$FB_DIR/decisions.md"

  while :; do
    gaps=$(printf '%s' "$FB_OUT" | jq -c '[.gaps[]|select(.severity=="BLOCKING")]+[.gaps[]|select(.severity=="IMPORTANT")]+[.gaps[]|select(.severity=="OPTIONAL")]')
    n=$(printf '%s' "$gaps" | jq 'length')
    [ "$n" -eq 0 ] && break

    i=0
    while [ "$i" -lt "$n" ]; do
      sev=$(printf '%s' "$gaps" | jq -r ".[$i].severity")
      q=$(printf '%s' "$gaps" | jq -r ".[$i].question")
      id=$(printf '%s' "$gaps" | jq -r ".[$i].id")
      say ""
      say "$FB_B[$sev]$FB_R $q"
      fb_ask "your answer (empty = use your best judgment)"
      while [ "$sev" = BLOCKING ] && [ -z "$FB_ANSWER" ]; do
        warn "this gap is blocking — an answer is required"
        fb_ask "your answer"
      done
      if [ -z "$FB_ANSWER" ]; then
        printf -- '- **%s** %s\n  - _no answer given; model uses its best judgment_\n' "$id" "$q" >> "$FB_DIR/decisions.md"
        fb_add_risk "$id unanswered — model used its best judgment"
        qa="$qa$id: $q
  -> no answer, use your best judgment
"
      else
        printf -- '- **%s** %s\n  - %s\n' "$id" "$q" "$FB_ANSWER" >> "$FB_DIR/decisions.md"
        qa="$qa$id: $q
  -> $FB_ANSWER
"
      fi
      i=$((i + 1))
    done

    round=$((round + 1))
    [ $round -ge 2 ] && break

    cat > "$FB_TMP/p" <<EOF
The user answered your questions:

$qa

Update your understanding of the repository and the feature. Return an updated
context summary and ONLY the new gaps that these answers opened and that still
block writing a specification. If nothing is blocking, return an empty gap list.
EOF
    fb_claude "Clarifying (round $((round + 1)))" read "$FB_TOOLS_READ" "$FB_SCHEMA_REQ" "$FB_TMP/p" "$sid" || return 1
    printf '%s' "$FB_OUT" | jq -r '.context_summary' > "$FB_DIR/context.md"
    qa=""
  done

  fb_approve "Requirements" "$FB_DIR/decisions.md" || return 1
  fb_checkpoint requirements
}

# --- 5.3 specification -------------------------------------------------------

fb_stage_spec() {
  cat > "$FB_TMP/p" <<EOF
Write the specification for this feature in the repository at $FB_ROOT.
Use the superpowers brainstorming and design skills to think it through.

Raw requirements:
---
$(cat "$FB_DIR/requirements.md")
---

Repository context:
---
$(cat "$FB_DIR/context.md")
---

Decisions already made with the user (binding — never contradict or re-ask):
---
$(cat "$FB_DIR/decisions.md")
---

$(fb_prior_specs)

Write $FB_DIR/spec.md. Rules:
- Stable ids: FR-001.. for functional requirements, AC-001.. for acceptance criteria.
- Every requirement is testable and unambiguous: one behavior, stated so that two
  developers would implement it the same way.
- Include only sections that apply: functional requirements, acceptance criteria,
  failure behavior, permissions and validation, non-goals, explicit assumptions.
- State what the feature does, never how to code it. No implementation plan.
- Concise. No filler, no restating the requirements document.
- Follow the engineering guide at $FB_DIR/guide.md.

Write only that one file.
EOF
  fb_claude "Writing specification" write "$FB_TOOLS_WRITE" "" "$FB_TMP/p" || return 1
  [ -f "$FB_DIR/spec.md" ] || { warn "the session did not write spec.md"; return 1; }

  fb_review_cycle "Specification" fb_review_spec fb_fix_spec "$FB_DIR/spec-review.json" || return 1
  fb_approve "Specification" "$FB_DIR/spec.md" || return 1
  fb_checkpoint spec
}

fb_review_spec() {
  cat > "$FB_TMP/p" <<EOF
You are an independent reviewer. You did not write this specification and you owe
its author nothing. Find what is wrong with it.

Specification under review:
---
$(cat "$FB_DIR/spec.md")
---

Raw requirements it must satisfy:
---
$(cat "$FB_DIR/requirements.md")
---

Decisions made with the user (binding):
---
$(cat "$FB_DIR/decisions.md")
---

$(fb_prior_specs)

Check: completeness against the requirements, ambiguity, internal contradictions,
untestable requirements, missing edge cases, missing failure behavior, missing
authorization and validation expectations, data consistency, security concerns,
backward compatibility, scope ambiguity, and contradiction with the previously
approved specifications listed above (silent conflict is a finding; explicit
supersession stated in the spec is not).

Report only findings that would change the implementation or let a defect ship.
Style opinions are not findings. If the specification is sound, return PASS with
an empty findings list. Use NEEDS_USER_INPUT when a finding can only be resolved
by a product decision the user must make.

Do not modify any file.
EOF
  fb_claude "Reviewing specification" read "$FB_TOOLS_READ" "$FB_SCHEMA_VERDICT" "$FB_TMP/p"
}

fb_fix_spec() {
  cat > "$FB_TMP/p" <<EOF
Fix the specification at $FB_DIR/spec.md.

Review findings to resolve:
---
$(cat "$FB_DIR/spec-review.json")
---

Decisions made with the user (binding — never contradict them):
---
$(cat "$FB_DIR/decisions.md")
---

Resolve every finding by making the specification precise. Keep the existing
FR/AC ids stable; add new ids for genuinely new requirements. Do not expand the
scope of the feature. Rewrite only $FB_DIR/spec.md.
EOF
  fb_claude "Fixing specification" write "$FB_TOOLS_WRITE" "" "$FB_TMP/p"
}

# --- 5.4 plan ----------------------------------------------------------------

fb_stage_plan() {
  cat > "$FB_TMP/p" <<EOF
Write the implementation plan for this feature in the repository at $FB_ROOT.
Use the superpowers writing-plans skill.

Approved specification (the source of truth):
---
$(cat "$FB_DIR/spec.md")
---

Repository context:
---
$(cat "$FB_DIR/context.md")
---

Decisions made with the user (binding):
---
$(cat "$FB_DIR/decisions.md")
---

Do two things:
1. Write $FB_DIR/plan.md: the ordered plan in prose, including how the feature
   will be tested and which existing code is reused.
2. Return the same plan as structured tasks.

Task rules:
- Each task is one coherent, independently verifiable change, small enough to
  implement in a single focused session.
- "covers" lists the FR/AC ids the task implements. Every requirement in the
  specification must be covered by at least one task.
- "files" lists the files the task creates or modifies, as far as they are known.
- "steps" are concrete instructions, test first, then implementation.
- "status" is always "pending".
- Order tasks so that each one leaves the repository in a working, testable state.
- Follow the engineering guide at $FB_DIR/guide.md. Reuse what exists. No
  speculative structure.
EOF
  fb_claude "Writing implementation plan" write "$FB_TOOLS_WRITE" "$FB_SCHEMA_PLAN" "$FB_TMP/p" || return 1
  printf '%s' "$FB_OUT" | jq . > "$FB_DIR/tasks.json"
  [ -f "$FB_DIR/plan.md" ] || { warn "the session did not write plan.md"; return 1; }

  fb_review_cycle "Plan" fb_review_plan fb_fix_plan "$FB_DIR/plan-review.json" || return 1
  fb_approve "Plan" "$FB_DIR/plan.md" || return 1
  fb_checkpoint plan
}

fb_review_plan() {
  cat > "$FB_TMP/p" <<EOF
You are an independent reviewer of an implementation plan. You did not write it.

The question you must answer: if this plan is executed exactly as written,
will the approved specification be fully implemented?

Specification:
---
$(cat "$FB_DIR/spec.md")
---

Plan:
---
$(cat "$FB_DIR/plan.md")
---

Tasks:
---
$(cat "$FB_DIR/tasks.json")
---

Build the traceability map yourself: every FR and AC id in the specification to
the task that implements it. Any requirement with no task is a BLOCKING finding.
Also report: tasks that implement behavior the specification does not ask for,
wrong ordering that leaves the repository broken between tasks, missing tests,
and tasks too large to verify.

Judge the plan against the specification, not against your own design taste.
Do not modify any file.
EOF
  fb_claude "Reviewing plan" read "$FB_TOOLS_READ" "$FB_SCHEMA_VERDICT" "$FB_TMP/p"
}

fb_fix_plan() {
  cat > "$FB_TMP/p" <<EOF
Fix the implementation plan.

Review findings to resolve:
---
$(cat "$FB_DIR/plan-review.json")
---

Specification (unchanged, still the source of truth):
---
$(cat "$FB_DIR/spec.md")
---

Current tasks:
---
$(cat "$FB_DIR/tasks.json")
---

Rewrite $FB_DIR/plan.md and return the corrected full task list. Keep task ids
stable where the task is unchanged. Do not change the specification.
EOF
  fb_claude "Fixing plan" write "$FB_TOOLS_WRITE" "$FB_SCHEMA_PLAN" "$FB_TMP/p" || return 1
  printf '%s' "$FB_OUT" | jq . > "$FB_DIR/tasks.json"
}

# --- 5.5 implementation ------------------------------------------------------

fb_stage_implementation() {
  local n i id title task
  n=$(jq '.tasks | length' "$FB_DIR/tasks.json")
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$(jq -r ".tasks[$i].status" "$FB_DIR/tasks.json")" = done ]; then
      i=$((i + 1)); continue
    fi
    id=$(jq -r ".tasks[$i].id" "$FB_DIR/tasks.json")
    title=$(jq -r ".tasks[$i].title" "$FB_DIR/tasks.json")
    task=$(jq ".tasks[$i]" "$FB_DIR/tasks.json")

    cat > "$FB_TMP/p" <<EOF
Implement one task in the repository at $FB_ROOT. Use the superpowers
test-driven-development skill.

Task:
---
$task
---

Approved specification (the source of truth for behavior):
---
$(cat "$FB_DIR/spec.md")
---

Decisions made with the user (binding):
---
$(cat "$FB_DIR/decisions.md")
---

How to work:
1. Read the code you are about to change and the tests around it.
2. Write or update the test first. Run it. Watch it fail for the right reason.
3. Implement the smallest change that makes it pass.
4. Run the test again, and the surrounding test suite, until green.

Rules:
- Implement this task only. Not the next one, not anything the specification does
  not ask for.
- Follow the engineering guide at $FB_DIR/guide.md and the conventions already in
  this repository.
- Never weaken or skip a test to make it pass.
- Do not commit; FeatureBandit commits.
- If the specification is genuinely wrong or contradictory and this task cannot be
  implemented without inventing behavior, stop and return SPEC_PROBLEM with the
  detail. Do not invent behavior. Otherwise return DONE with one line on what
  changed.
EOF
    fb_claude "Implementing $id: $title" write "$FB_TOOLS_WRITE" "$FB_SCHEMA_TASK" "$FB_TMP/p" || return 1

    if [ "$(printf '%s' "$FB_OUT" | jq -r '.status')" = SPEC_PROBLEM ]; then
      say ""
      warn "specification problem reported during $id:"
      printf '%s' "$FB_OUT" | jq -r '.detail'
      {
        printf '\n## Specification problem found during %s\n\n' "$id"
        printf '%s' "$FB_OUT" | jq -r '.detail'
      } >> "$FB_DIR/decisions.md"
      fb_menu "[s] Return to the specification stage  [q] Abort" "sq"
      [ "$FB_CHOICE" = q ] && return 1
      fb_git checkout -- . 2>/dev/null
      fb_uncheckpoint spec
      fb_uncheckpoint plan
      return 2
    fi

    fb_verify_gate "implementation" || return 1
    fb_commit "featurebandit: implementation: $id $title"
    jq ".tasks[$i].status = \"done\"" "$FB_DIR/tasks.json" > "$FB_DIR/tasks.json.tmp" &&
      mv "$FB_DIR/tasks.json.tmp" "$FB_DIR/tasks.json"
    say "$FB_OK $id done"
    i=$((i + 1))
  done

  fb_verify_gate "implementation" || return 1
  fb_checkpoint implementation
}

# --- 5.6 spec compliance -----------------------------------------------------

fb_stage_compliance() {
  fb_blocking_cycle "Spec Compliance" fb_review_compliance fb_fix_compliance \
    "$FB_DIR/compliance-review.json" 'if .status == "PASS" then 0 else 1 end' || return 1
  fb_checkpoint compliance
}

fb_review_compliance() {
  fb_write_diff
  cat > "$FB_TMP/p" <<EOF
You are an independent reviewer. Decide whether the implemented change actually
satisfies the approved specification. You did not write this code.

Specification:
---
$(cat "$FB_DIR/spec.md")
---

Plan:
---
$(cat "$FB_DIR/plan.md")
---

The complete change under review is the diff at $FB_DIR/diff.patch. Read it, and
read the affected files in the repository for context.

Verification commands passed in a clean shell before this review.

Judge every FR and AC id in the specification: PASS if the code implements it,
FAIL if it does not. Verify by reading the code, not by trusting the plan or the
commit messages. A requirement implemented but untested is a FAIL. Report a
finding for each FAIL. Status is PASS only when every requirement passes.

Do not modify any file.
EOF
  fb_claude "Checking specification compliance" read "$FB_TOOLS_READ" "$FB_SCHEMA_COMPLIANCE" "$FB_TMP/p"
}

fb_fix_compliance() {
  cat > "$FB_TMP/p" <<EOF
The implementation does not satisfy the approved specification. Fix the code.

Failing requirements and findings:
---
$(cat "$FB_DIR/compliance-review.json")
---

Specification (the source of truth — do not change it):
---
$(cat "$FB_DIR/spec.md")
---

Implement what each failing requirement asks for, test first. Change only what is
needed to make those requirements hold. Follow the engineering guide at
$FB_DIR/guide.md. Do not commit.
EOF
  fb_claude "Fixing compliance findings" write "$FB_TOOLS_WRITE" "" "$FB_TMP/p"
}

# --- 5.7 code review ---------------------------------------------------------

fb_stage_code_review() {
  fb_blocking_cycle "Code Review" fb_review_code fb_fix_code \
    "$FB_DIR/code-review.json" '[.findings[]?|select(.severity=="CRITICAL" or .severity=="HIGH")]|length' || return 1
  fb_checkpoint code_review
}

fb_review_code() {
  fb_write_diff
  cat > "$FB_TMP/p" <<EOF
Review this change adversarially, using the code-review skill. You did not write
it. Assume it contains a defect and find it.

The change is the diff at $FB_DIR/diff.patch. Read it, and read the surrounding
code — a defect is often in how the change interacts with what was already there.

Specification the change implements:
---
$(cat "$FB_DIR/spec.md")
---

Report: correctness bugs, unhandled failure paths, broken edge cases, race
conditions, resource leaks, misuse of existing APIs, tests that do not actually
test the behavior they claim, and duplication of code that already exists in this
repository.

Severity: CRITICAL is data loss, corruption, or a security hole. HIGH is a defect
users will hit. MEDIUM is a real but contained problem. LOW and NIT are style.
Only report what you can point at in the diff. No speculation, no praise, no
findings about code the diff does not touch. Status is PASS when nothing is
CRITICAL or HIGH.

Do not modify any file.
EOF
  fb_claude "Reviewing code" read "$FB_TOOLS_READ" "$FB_SCHEMA_VERDICT" "$FB_TMP/p"
}

fb_fix_code() {
  cat > "$FB_TMP/p" <<EOF
Fix the findings from the code review.

Findings:
---
$(cat "$FB_DIR/code-review.json")
---

Specification (do not change behavior it requires):
---
$(cat "$FB_DIR/spec.md")
---

Fix every CRITICAL and HIGH finding. Fix a MEDIUM finding only when the fix is
clearly safe and local; otherwise leave it and say so. Ignore LOW and NIT.

Where a finding is a real defect, add or update the test that would have caught
it. Never weaken a test. Follow the engineering guide at $FB_DIR/guide.md.
Do not commit.
EOF
  fb_claude "Fixing code review findings" write "$FB_TOOLS_WRITE" "" "$FB_TMP/p"
}

# --- 5.8 simplification ------------------------------------------------------

fb_stage_simplification() {
  fb_write_diff
  cat > "$FB_TMP/p" <<EOF
Simplify the change described by the diff at $FB_DIR/diff.patch, using the
code-simplifier skill. Scope is that change only.

Remove abstraction that has one caller, duplication, dead code, and options
nothing uses. Improve names. Align with the conventions already in this
repository.

Hard rule: no behavior changes. Every test must still pass unchanged, and every
requirement in the specification must still hold:
---
$(cat "$FB_DIR/spec.md")
---

If nothing is worth simplifying, change nothing and say so. Do not commit.
EOF
  fb_claude "Simplifying" write "$FB_TOOLS_WRITE" "" "$FB_TMP/p" || return 1
  fb_verify_gate "simplification" || return 1
  fb_commit "featurebandit: simplification"
  fb_checkpoint simplification
}

# --- 5.9 security review -----------------------------------------------------

fb_stage_security() {
  local filter='[.findings[]?|select(.severity=="CRITICAL" or .severity=="HIGH")]|length'
  [ "$(fb_config_get SECURITY_BLOCK_MEDIUM 2>/dev/null)" = 1 ] &&
    filter='[.findings[]?|select(.severity=="CRITICAL" or .severity=="HIGH" or .severity=="MEDIUM")]|length'
  fb_blocking_cycle "Security" fb_review_security fb_fix_security \
    "$FB_DIR/security-review.json" "$filter" || return 1
  fb_checkpoint security
}

fb_review_security() {
  fb_write_diff
  cat > "$FB_TMP/p" <<EOF
Perform a security review of the change in the diff at $FB_DIR/diff.patch, using
the security-review skill. Read the surrounding code for context.

Look for: injection through untrusted input, missing authentication or
authorization checks, broken access control between users or tenants, secrets in
code or logs, unsafe deserialization, path traversal, SSRF, weak or missing
validation at trust boundaries, and sensitive data written to logs or responses.

Specification, including the permission and validation expectations:
---
$(cat "$FB_DIR/spec.md")
---

Report only vulnerabilities reachable in this change, each with the concrete path
from untrusted input to the vulnerable operation. No theoretical findings, no
generic hardening advice. Status is PASS when nothing is CRITICAL or HIGH.

Do not modify any file.
EOF
  fb_claude "Reviewing security" read "$FB_TOOLS_READ" "$FB_SCHEMA_VERDICT" "$FB_TMP/p"
}

fb_fix_security() {
  cat > "$FB_TMP/p" <<EOF
Fix the security findings.

Findings:
---
$(cat "$FB_DIR/security-review.json")
---

Specification (behavior it requires must still hold):
---
$(cat "$FB_DIR/spec.md")
---

Fix every CRITICAL and HIGH finding at the root: validate or authorize where the
trust boundary actually is, not at the call site that happened to be reported.
Add a test that fails without the fix. Follow the engineering guide at
$FB_DIR/guide.md. Do not commit.
EOF
  fb_claude "Fixing security findings" write "$FB_TOOLS_WRITE" "" "$FB_TMP/p"
}

# --- 5.10 final acceptance ---------------------------------------------------

fb_stage_final() {
  fb_verify_gate "final" || return 1
  fb_commit "featurebandit: fix failing checks"
  fb_write_diff

  cat > "$FB_TMP/p" <<EOF
Final acceptance for this feature in the repository at $FB_ROOT. Decide whether
the delivered change is the feature that was asked for.

Raw requirements:
---
$(cat "$FB_DIR/requirements.md")
---

Decisions and accepted risks:
---
$(cat "$FB_DIR/decisions.md")
---

Specification:
---
$(cat "$FB_DIR/spec.md")
---

The delivered change is the diff at $FB_DIR/diff.patch.

Review verdicts already recorded:
- compliance: $(jq -r '.status' "$FB_DIR/compliance-review.json" 2>/dev/null)
- code review: $(jq -r '.status' "$FB_DIR/code-review.json" 2>/dev/null)
- security: $(jq -r '.status' "$FB_DIR/security-review.json" 2>/dev/null)

All configured verification commands passed in a clean shell.

Return PASS when the requirements are met and the accepted risks are the only
gaps. PASS_WITH_ACCEPTED_RISKS when the feature works but recorded risks remain
open. FAIL only when something the user asked for is missing or broken; say
exactly what, in the summary.

Do not modify any file.
EOF
  fb_claude "Final acceptance" read "$FB_TOOLS_READ" "$FB_SCHEMA_FINAL" "$FB_TMP/p" || return 1
  printf '%s' "$FB_OUT" | jq . > "$FB_DIR/final-review.json"

  local status summary
  status=$(printf '%s' "$FB_OUT" | jq -r '.status')
  summary=$(printf '%s' "$FB_OUT" | jq -r '.summary')

  say ""
  say "$FB_B FeatureBandit Final Acceptance $FB_R"
  say ""
  say "$summary"
  say ""

  if [ "$status" = FAIL ]; then
    warn "final acceptance: FAIL"
    fb_menu "Return to  [s] Specification  [p] Plan  [i] Implementation  [q] Abort" "spiq"
    case "$FB_CHOICE" in
      s) fb_uncheckpoint spec; fb_uncheckpoint plan; fb_uncheckpoint implementation ;;
      p) fb_uncheckpoint plan; fb_uncheckpoint implementation ;;
      i) fb_uncheckpoint implementation ;;
      q) return 1 ;;
    esac
    fb_uncheckpoint compliance; fb_uncheckpoint code_review
    fb_uncheckpoint simplification; fb_uncheckpoint security
    return 2
  fi

  fb_archive_spec
  fb_checkpoint final
  fb_status
  say "Status: $status"
  say "Branch: $(fb_git rev-parse --abbrev-ref HEAD) — review and merge it yourself."
  say "Spec archived: docs/specs/$(fb_state_get .feature).md"
}

fb_archive_spec() {
  local slug
  slug=$(fb_state_get .feature)
  mkdir -p "$FB_ROOT/docs/specs"
  {
    cat "$FB_DIR/spec.md"
    if [ "$(fb_state_get '.acceptedRisks | length')" != 0 ]; then
      printf '\n\n## Accepted risks and assumptions\n\n'
      fb_state_get '.acceptedRisks[] | "- " + .'
    fi
  } > "$FB_ROOT/docs/specs/$slug.md"
  fb_commit "featurebandit: archive spec for $slug"
}
