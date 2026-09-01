# FeatureBandit V1 — Technical Specification

FeatureBandit is a cross-platform, terminal-based AI feature development orchestrator: a small set of portable shell scripts around the Claude Code CLI and existing Claude plugins.

> Take one feature from raw requirements to validated implementation through a deterministic sequence of AI-assisted stages, with interactive approval gates and resume support.

It is **not** a generic agent platform, workflow engine, CI/CD system, or multi-feature manager.

---

## 1. Verified Environment Facts

These mechanisms were inspected against a real Claude Code installation (v2.1.252) and are the only integration points FeatureBandit uses. No custom runtime, no SDK, no API calls.

### 1.1 Headless invocation

Every AI stage is a fresh `claude -p` (print mode) call:

```bash
claude -p "<prompt>" \
  --output-format json \          # single JSON result envelope (includes session_id, structured_output)
  --json-schema '<schema>' \      # structured output validated against a JSON Schema
  --permission-mode acceptEdits \ # write stages only; review stages use default mode
  --allowedTools "..."            # constrain tools per stage
```

- `--output-format json` returns a JSON envelope; with `--json-schema` the validated answer is the already-parsed object in `.structured_output` (`.result` holds the same JSON as a string — always read `.structured_output`).
- `--json-schema` gives schema-validated structured output — used for all review verdicts (spec review, plan review, compliance, code review, security review, final acceptance).
- Review stages run in default permission mode with read-only tools: `--allowedTools "Read Grep Glob Bash(git diff:*) Bash(git log:*)"`. `bypassPermissions` is never used.
- There is no `--max-turns` in the current CLI; runaway calls are bounded by `timeout` (the shell utility) around the `claude` call, generous per-stage limits.
- `--resume <session_id> -p "<answer>"` continues a prior session — used to feed user answers back into the requirements-clarification session without losing its repository context.
- Skill invocation in print mode: a slash command expands **only when the prompt starts with it**, one command per call (`claude -p "/code-review <args>"`). A skill named mid-prompt is plain text; for the model to invoke it itself, `Skill` must be in `--allowedTools`. Stage prompts therefore either start with the slash command or explicitly allow the `Skill` tool.

### 1.2 Plugin detection (supported mechanism)

```bash
claude plugin list --json
```

Returns a JSON array of installed plugins:

```json
{
  "id": "code-simplifier@claude-plugins-official",
  "version": "1.0.0",
  "scope": "user",
  "enabled": true,
  "installPath": "..."
}
```

Detection = plugin `id` matches `<name>@<any-marketplace>` and `enabled == true`. Match on plugin *name* only (e.g. superpowers may come from `superpowers-dev` or `claude-plugins-official`).

### 1.3 Plugin installation (supported mechanism)

```bash
claude plugin install <name>@claude-plugins-official --scope user
```

Exactly three plugins are required (verified: `/code-review` and `/security-review` are built into Claude Code itself and need no plugin):

| Capability            | Plugin id                                  |
|-----------------------|--------------------------------------------|
| Repo discovery / requirements | `feature-dev@claude-plugins-official` |
| Brainstorm / plan / execute   | `superpowers@claude-plugins-official` (any marketplace accepted) |
| Simplification                | `code-simplifier@claude-plugins-official` |

If `claude-plugins-official` is not a configured marketplace, print instructions and stop (adding marketplaces on the user's behalf is out of scope for auto-install; offer the exact `claude plugin marketplace add` command).

---

## 2. Architecture

**Principle: the shell makes workflow decisions; Claude makes engineering decisions.**

```text
featurebandit           # entry point (bash)
lib/
  common.sh             # ui helpers, prompts, claude call wrapper
  bootstrap.sh          # preflight: claude + plugins
  state.sh              # state.json read/write (jq)
  stages.sh             # one function per pipeline stage
```

(Fewer files are acceptable; more are not. No frameworks, DSLs, daemons, databases.)

Each stage is:

1. one or more fresh `claude -p` calls with a focused prompt and artifacts as input,
2. a deterministic shell decision on the structured result,
3. an interactive gate where the spec requires one,
4. a state checkpoint written to `.featurebandit/state.json`.

Fresh contexts are mandatory for independent reviews (spec review, plan review, compliance, code review, security, final acceptance) — a reviewer never shares a session with the producer of the artifact it reviews.

### Portability rules

- Target `bash` on macOS, Linux, Git Bash, WSL. Shebang `#!/usr/bin/env bash`.
- Dependencies: `bash`, `git`, `jq`, `claude`. Nothing else.
- Forbidden: GNU-only `sed -i` semantics, `grep -P`, `readlink -f`, `realpath`, `/proc`, Linux-only process tools.
- All JSON handling through `jq`. All paths relative to the repository root (`git rev-parse --show-toplevel`).

### Git strategy

Git is the source of truth for code state; `state.json` only tracks workflow position.

- **Start**: working tree must be clean (`git status --porcelain` empty). If not, print the dirty files and exit — FeatureBandit never stashes or commits user changes.
- FeatureBandit creates and checks out `featurebandit/<feature-slug>` from the current HEAD; that HEAD is recorded as `start_commit` in `state.json`.
- `.featurebandit/` is added to `.git/info/exclude` (not `.gitignore` — the repo's own files are never modified for bookkeeping).
- **Commit per atomic block**: every code-modifying `claude -p` block (implementation task, any fix session, simplification) ends with `git add -A && git commit -m "featurebandit: <stage>: <what>"`. A committed block is done; an uncommitted tree means the block was interrupted.
- **Resume with a dirty tree**: the last block was interrupted mid-write. Prompt once: `[d] Discard uncommitted changes and redo the block / [q] Quit`. Discard = `git checkout -- . && git clean -fd` (paths under the repo, `.featurebandit/` excluded). Blocks are only ever re-run from a clean tree.
- **All review diffs** are `git diff <start_commit>...HEAD` — deterministic and free of unrelated changes by construction.
- **Abort**: confirm, then check out the original branch (recorded in state) and offer to delete the feature branch. Code rollback is exactly branch deletion.
- **DONE**: FeatureBandit never merges. It prints the branch name and summary; merging/PR is the user's job.

### Spec archive

`.featurebandit/` is transient, but approved specs are permanent repo knowledge:

- On final acceptance, `spec.md` (with the accepted risks/assumptions from `decisions.md` appended as a final section) is copied to `docs/specs/<feature-slug>.md` and committed on the feature branch as the last commit. Merging the feature merges its spec. Fixed path, no config.
- Every later feature reads `docs/specs/*.md` as input: the requirements stage (§5.2) treats them as approved existing behavior, and the spec review (§5.3) checks the new spec for contradictions with them. A deliberate behavior change is not an error — it surfaces as a finding, and on approval the new spec states which prior spec (by file and FR id) it supersedes; old spec files are never rewritten.

---

## 3. CLI

```bash
featurebandit                    # interactive start, or resume if unfinished feature exists
featurebandit requirements.md    # start from a file
featurebandit "Add RBAC support" # start from text
featurebandit resume             # resume explicitly
featurebandit status             # print stage checklist, exit
featurebandit abort              # abort current feature (confirm, reset state, back to original branch — §2)
```

No other commands. An argument that is an existing readable file is treated as a requirements file; otherwise as requirement text; no argument → interactive prompt:

```text
FeatureBandit

What feature do you want to build?

>
```

If an unfinished feature exists and new requirements are given:

```text
Existing unfinished feature found:

RBAC Support
Current stage: Code Review

[r] Resume existing feature
[a] Abort existing feature and start new one
[q] Quit
```

---

## 4. State and Artifacts

Everything lives in `.featurebandit/` at the repository root. Exactly one active feature per repository.

```text
.featurebandit/
├── state.json               # the only workflow state
├── config                   # optional: VERIFY_COMMAND_N lines
├── guide.md                 # language-agnostic engineering guide (installed by bootstrap)
├── requirements.md          # original raw requirements (preserved verbatim)
├── context.md               # repository discovery summary
├── decisions.md             # user answers + accepted assumptions/risks
├── spec.md                  # approved specification (source of truth)
├── spec-review.json         # last spec review verdict
├── plan.md                  # implementation plan
├── plan-review.json         # last plan review verdict
├── tasks.json               # plan tasks with status
├── compliance-review.json
├── code-review.json
├── security-review.json
└── final-review.json
```

### state.json

```json
{
  "feature": "rbac-support",
  "title": "RBAC Support",
  "stage": "code_review",
  "startCommit": "abc1234",
  "originalBranch": "main",
  "checkpoints": {
    "requirements_approved": true,
    "spec_approved": true,
    "plan_approved": true,
    "implementation_complete": true,
    "compliance_review_complete": true,
    "code_review_complete": false,
    "simplification_complete": false,
    "security_review_complete": false,
    "final_acceptance_complete": false
  },
  "acceptedRisks": []
}
```

Writes are atomic: write to `state.json.tmp`, then `mv` over `state.json` (rename is atomic enough on all target platforms for a single-terminal tool).

### Resume

On start, if `state.json` exists and `final_acceptance_complete` is false, resume at the first checkpoint that is false, in pipeline order. Completed stages are never regenerated. `featurebandit status` renders:

```text
✓ Requirements
✓ Specification
✓ Plan
✓ Implementation
✓ Spec Compliance
→ Code Review
○ Simplification
○ Security
○ Final
```

Sub-stage granularity for resume exists in exactly one place: implementation task status in `tasks.json` (`pending` / `done`), so an interrupted implementation resumes at the first pending task.

---

## 5. Pipeline Stages

Ordered checkpoints (each is atomic; state is written immediately after it passes):

```text
bootstrap (not persisted — runs every start)
requirements_approved
spec_approved
plan_approved
implementation_complete        (includes deterministic verification)
compliance_review_complete
code_review_complete
simplification_complete       (includes deterministic re-verification)
security_review_complete
final_acceptance_complete → DONE
```

### 5.1 Bootstrap

1. `command -v claude` — if missing, print install message and exit 1. No fallback provider.
2. `command -v jq`, `command -v git` — same treatment.
3. Working directory must be inside a git repository. On a new feature start, run the git preflight (§2 Git strategy): clean tree, create feature branch, record `startCommit`/`originalBranch`, exclude `.featurebandit/`.
4. `claude plugin list --json` → check the three required plugins (§1.2). Print the ✓/✗ table.
5. If any missing: `Install them automatically? [Y/n]` → `claude plugin install <id>` per missing plugin → recheck once. Any failure: print the failing plugin and exit 1.

Bootstrap runs on every invocation (cheap, idempotent, no state).

**Project conventions setup** (also part of bootstrap, idempotent):

6. Install the model configuration into the target repository's `CLAUDE.md` (repo root):
   - The rules live between markers so the step is idempotent and user content is never touched:

     ```markdown
     <!-- featurebandit:rules:start -->
     # Engineering style (FeatureBandit)
     - Be sharp and direct: facts, conclusions, code. No thinking out loud.
     - Build exactly what was asked. Nothing extra "for the future". YAGNI.
     - Prefer the smallest working solution; no abstractions or config options for hypothetical requirements.
     - No error handling, logging, retries, or validation beyond what the task needs.
     - Don't refactor surrounding code unless asked. Reuse what exists before writing new code.
     - Follow the engineering guide in .featurebandit/guide.md.
     <!-- featurebandit:rules:end -->
     ```

   - No `CLAUDE.md` → create it with the block. `CLAUDE.md` exists without markers → append the block. Markers present → replace block content (upgrades ship rule updates). Implementation: plain `grep` for the marker + append/rewrite; no templating.
7. Install `.featurebandit/guide.md` — a short language-agnostic engineering guide shipped with FeatureBandit (copied verbatim, overwritten on version change). Every stage prompt references it. There is no single industry-wide cross-language style standard, so the guide distills the universal ones and defers language specifics to the repo's own linters/formatters:
   - naming: intention-revealing names, no abbreviations, consistency with the surrounding code;
   - functions/modules: small, single responsibility, shallow nesting, early returns;
   - errors: fail fast, no swallowed exceptions, actionable messages;
   - tests: test behavior not implementation, one assertion focus per test, cover the failure path;
   - structure: files that change together live together; follow the repo's existing layout, don't invent a new one;
   - comments: only for what the code cannot say (constraints, invariants), never narration;
   - formatting: whatever the repo's formatter/linter says wins; if none, match existing files.
8. Verification gate setup: if `.featurebandit/config` has no `VERIFY_COMMAND_N` lines, run detection (§5.5), confirm with the user, write the config.

### 5.2 Requirements → `requirements_approved`

1. Persist raw input verbatim to `.featurebandit/requirements.md`.
2. Fresh `claude -p` session invoking `/feature-dev:feature-dev` exploration behavior: read requirements, read prior specs in `docs/specs/` (approved existing behavior — §2 Spec archive), inspect the repository, locate relevant code, conventions, tests. Output constrained by `--json-schema`:

```json
{
  "context_summary": "markdown",
  "gaps": [
    { "id": "GAP-001", "severity": "BLOCKING|IMPORTANT|OPTIONAL", "question": "..." }
  ]
}
```

3. Write `context.md`. For each gap, in severity order, ask the user in the terminal. BLOCKING gaps require an answer; IMPORTANT/OPTIONAL may be skipped (skip = "use your best judgment", recorded as an accepted assumption).
4. Feed answers back with `claude --resume <session_id> -p` so the clarifier keeps its repository context; repeat until no new BLOCKING gaps (max 2 clarification rounds, then remaining gaps become findings for the spec stage).
5. Persist Q&A to `decisions.md`. Answered questions are never re-asked (decisions.md is input to every later stage).
6. Checkpoint `requirements_approved`.

No implementation happens here.

### 5.3 Specification → `spec_approved`

1. Fresh session with `requirements.md` + `context.md` + `decisions.md`, invoking Superpowers brainstorming/design guidance to produce a concise `spec.md` with stable IDs (`FR-nnn`, `AC-nnn`) and only relevant sections (functional requirements, acceptance criteria, failure behavior, permissions/validation, non-goals, explicit assumptions — omit what doesn't apply).
2. **Independent spec review** — fresh session, input is spec + requirements + decisions, output via `--json-schema`:

```json
{
  "status": "PASS|FAIL|NEEDS_USER_INPUT",
  "findings": [
    { "id": "SPEC-001", "severity": "BLOCKING|HIGH|MEDIUM|LOW",
      "requirement": "FR-002", "type": "ambiguity", "message": "..." }
  ]
}
```

Reviewer checks: completeness, ambiguity, contradictions, untestable requirements, missing edge cases / failure behavior / authorization expectations, data consistency, security concerns, backward compatibility, scope ambiguity, and contradictions with prior specs in `docs/specs/` (§2 Spec archive — deliberate supersession must be stated in the new spec, silent conflict is a finding).

3. Interactive loop on `FAIL` or `NEEDS_USER_INPUT`:

```text
[f] Fix findings      → fix session updates spec.md → fresh review
[a] Accept findings   → recorded in decisions.md as accepted risks
[c] Continue anyway   → recorded as accepted risks
[q] Abort
```

Loop until PASS or user accepts/continues. Persist last verdict to `spec-review.json`. Checkpoint `spec_approved`.

### 5.4 Plan → `plan_approved`

1. Fresh session using Superpowers writing-plans guidance; input spec + context. Produces `plan.md` and `tasks.json`:

```json
{
  "tasks": [
    { "id": "TASK-001", "title": "...", "covers": ["FR-001", "AC-001"],
      "files": ["src/..."], "steps": ["..."], "status": "pending" }
  ]
}
```

Small tasks, each mapped to FR/AC IDs.

2. **Independent plan review** — fresh session; core question: *"If this plan is executed exactly as written, will the approved specification be fully implemented?"* Same verdict schema as spec review plus a traceability map (`FR/AC → TASK`); unmapped requirements are findings.
3. Same `[f]/[a]/[c]/[q]` loop. Persist `plan-review.json`. Checkpoint `plan_approved`.

### 5.5 Implementation → `implementation_complete`

For each pending task in `tasks.json`, in order:

1. Fresh `claude -p` session with `--permission-mode acceptEdits`: task definition + spec excerpt + decisions. Loop inside the session: understand → write/update tests → implement → verify. Superpowers execution skills are referenced in the prompt; where Superpowers dispatches its own subagents, that is reused, not rebuilt.
2. On task success, commit (§2 Git strategy) and mark `status: "done"` in `tasks.json` (this is the implementation resume point; an uncommitted tree on resume means the task was interrupted — see §2).

Rules:
- Implementation must not redefine the spec. The task prompt instructs: if a genuine spec problem is exposed, stop and report `{"status": "SPEC_PROBLEM", "detail": ...}` — FeatureBandit then returns the user to the spec stage (clears `spec_approved`, `plan_approved`) instead of inventing behavior.

**Deterministic verification gate** (shell, not AI): lint + tests. This is the step that actually executes the tests the LLM wrote during TDD — a test that only ever ran inside an AI session doesn't count; it must pass here, in a plain shell, or the stage doesn't checkpoint.

Commands come from `.featurebandit/config` (`VERIFY_COMMAND_N` lines, run in order). If no config exists, detect once during bootstrap by project markers — the subtle part is that every language has its own tooling, so detection is a small fixed table, never guesswork:

| Marker (repo root)           | Test command        | Lint command (if configured)      |
|------------------------------|---------------------|-----------------------------------|
| `package.json`               | `npm test`          | `npm run lint` (script exists)    |
| `pyproject.toml` / `pytest.ini` | `pytest`         | `ruff check .` (ruff configured)  |
| `go.mod`                     | `go test ./...`     | `go vet ./...`                    |
| `Cargo.toml`                 | `cargo test`        | `cargo clippy -- -D warnings`     |
| `Makefile` with `test` target| `make test`         | `make lint` (target exists)       |

Detected commands are shown to the user for confirmation (edit/accept), then written to config. Nothing detected → ask ("Enter verification commands, empty line to finish") and write the config. Either way the gate always exists — a project with no detectable test runner still gets an explicit, user-supplied one before implementation starts.

Any non-zero exit blocks progression → a fix session gets the failing command output → the gate reruns (bounded, 3 attempts, then ask the user: retry / shell out / abort). The same gate reruns after simplification (§5.8) and once more immediately before final acceptance (§5.10).

Checkpoint `implementation_complete` only after all tasks are done **and** all verification commands pass.

### 5.6 Spec Compliance → `compliance_review_complete`

Fresh reviewer. Inputs: `spec.md`, `plan.md`, `git diff <startCommit>...HEAD` (§2 Git strategy), verification results. Output:

```json
{
  "status": "PASS|FAIL",
  "requirements": { "FR-001": "PASS", "FR-003": "FAIL" },
  "findings": [ { "requirement": "FR-003", "message": "..." } ]
}
```

On FAIL: fix session per failing requirement → deterministic verification → fresh compliance re-review (bounded loop; after 3 failures, ask the user). Persist `compliance-review.json`. Checkpoint.

### 5.7 Code Review → `code_review_complete`

Fresh session invoking the built-in `/code-review` skill over the diff. Verdict schema with severities `CRITICAL|HIGH|MEDIUM|LOW|NIT`.

Policy (deterministic, in shell):
- CRITICAL, HIGH → fix session, then rerun deterministic verification, then re-review.
- MEDIUM → fix when the fix session judges it clearly safe; otherwise report.
- LOW, NIT → report only (persisted in `code-review.json`).

Checkpoint when no CRITICAL/HIGH findings remain.

### 5.8 Simplification → `simplification_complete`

Fresh session invoking `code-simplifier` over the diff: remove unneeded abstraction/duplication/dead code, improve naming, align with repo style, **no behavior changes**. Then rerun deterministic verification; checkpoint only when it passes (on failure: fix loop as in 5.5).

### 5.9 Security Review → `security_review_complete`

Fresh session invoking the built-in `/security-review` skill over the diff. Same verdict schema; policy: CRITICAL/HIGH blocking → fix → verification → re-review; MEDIUM configurable (`SECURITY_BLOCK_MEDIUM=1` in config, default off); LOW report. Persist `security-review.json`. Checkpoint.

### 5.10 Final Acceptance → `final_acceptance_complete`

The deterministic verification gate (§5.5) runs one final time; only then a fresh session with all artifacts (requirements, decisions, spec, plan, diff, all review verdicts, verification results). Output `{"status": "PASS|PASS_WITH_ACCEPTED_RISKS|FAIL", "summary": "..."}` → `final-review.json`.

- PASS / PASS_WITH_ACCEPTED_RISKS → archive the spec to `docs/specs/<feature-slug>.md` and commit (§2 Spec archive), print the checklist summary and the feature branch name (merging is the user's job), mark DONE.
- FAIL → show reasons; user chooses which stage to return to, or aborts.

```text
FeatureBandit Final Acceptance

✓ Requirements   ✓ Specification   ✓ Plan
✓ Implementation ✓ Verification    ✓ Spec Compliance
✓ Code Review    ✓ Simplification  ✓ Security

Status: PASS
```

After DONE, starting a new feature resets `.featurebandit/` after confirmation — the spec already lives in `docs/specs/` (§2 Spec archive), git history preserves the code; nothing else is kept.

---

## 6. Interaction Conventions

- Single terminal, plain `read -r` prompts, single-letter menus (`[f]/[a]/[c]/[q]`), `✓ ✗ → ○ !` status glyphs (ASCII fallback when `LANG` isn't UTF-8).
- Default output is the concise stage checklist plus current activity. `FEATUREBANDIT_VERBOSE=1` streams claude output verbatim.
- Every claude call prints a one-line "what's happening" (`Reviewing specification...`).
- All abort paths leave `state.json` consistent — a stage is either checkpointed or it isn't; partial artifacts are overwritten on retry.

---

## 7. Error Handling

- Any `claude -p` non-zero exit or schema-invalid output → one automatic retry, then interactive `[r] Retry / [q] Abort`.
- All review loops are bounded (3 automatic iterations) before asking the user, preventing infinite AI ping-pong.
- Ctrl-C at any point is safe: the next run resumes from the last checkpoint.

---

## 8. Out of Scope (V1)

Browser QA / Playwright, multi-feature or parallel workflows, background workers, cloud execution, CI/CD integration, GitHub/Jira sync, web UI/dashboards, server mode, databases, distributed agents, multiple LLM providers, generic plugin frameworks, multi-repo workflows.

---

## 9. Definition of Done

A developer runs `featurebandit requirements.md` and the tool: checks Claude → detects/offers to install required plugins → verifies a clean tree and creates the feature branch → detects/confirms lint+test commands → reads requirements → inspects the repo → clarifies gaps → approves requirements → generates and independently reviews the spec (interactive resolution) → generates and independently reviews the plan (interactive resolution) → implements task-by-task → runs deterministic checks → validates spec compliance → runs adversarial code review and fixes blockers → simplifies code and re-verifies → runs security review and fixes blockers → performs final acceptance → archives the approved spec into `docs/specs/` → marks the feature DONE. The next feature builds on the archived specs of all previous ones. Interrupting at any point and re-running resumes from the last incomplete checkpoint.
