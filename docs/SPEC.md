# FeatureBandit — Technical Specification

FeatureBandit is a plugin-first feature orchestrator: a small set of portable
shell scripts that drive **existing, maintained tools** through one deterministic
sequence, on one git branch, with resume.

It invents no methodology of its own. Every engineering decision — what the
specification says, how the work is broken down, how the code is written,
reviewed, simplified and security-checked — belongs to a tool that already owns
that job. FeatureBandit owns git, state, approvals, running commands,
verification and resume. Nothing else.

It is **not** an agent platform, workflow engine, CI system or multi-feature
manager.

---

## 1. The stack

| Concern | Tool | Invocation |
|---|---|---|
| Spec-driven workflow | [GitHub Spec Kit](https://github.com/github/spec-kit) | `/speckit-specify`, `-clarify`, `-checklist`, `-plan`, `-tasks`, `-analyze`, `-implement`, `-converge` |
| Implementation discipline | [Superpowers](https://github.com/obra/superpowers) | `/superpowers:test-driven-development`, `/superpowers:systematic-debugging` |
| Code review | PR Review Toolkit (`claude-plugins-official`) | agents `code-reviewer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer` |
| Simplification | Code Simplifier (`claude-plugins-official`) | agent `code-simplifier` |
| Security | Claude Code built-in | `/security-review` |
| Terminal interface | [Charmbracelet Gum](https://github.com/charmbracelet/gum) | `gum choose`, `gum confirm`, `gum input`, `gum style` |

Deliberately **not** used: `feature-dev`; the `code-review` plugin (its command
is built around a GitHub PR, not a local branch); GSD, BMAD, Ralph and other
orchestration frameworks; any home-grown review prompt, severity scale or
convergence protocol that duplicates one of the tools above.

Superpowers is used for implementation discipline only. Brainstorming, planning
and workflow control belong to Spec Kit. Gum is used for presentation only: it
never touches pipeline state, git or exit codes.

---

## 2. Verified integration points

Every mechanism below was exercised against the real tools — Claude Code
2.1.257, Spec Kit 1.0.3, PR Review Toolkit and Code Simplifier from
`claude-plugins-official`, Superpowers 5.0.7. No SDK, no API calls, no runtime
of its own.

`test/e2e.sh` re-checks what can be checked for free: the plugins are installed
and enabled, every agent file the pipeline names exists, and a repository really
has the Spec Kit layout (it initialises a throwaway one if this repository has
none). `test/e2e.sh --dispatch` adds three real `claude -p` calls — one agent
dispatch and both Superpowers skills. `test/e2e.sh --full` runs one complete
real pipeline, every stage, in a throwaway repository; it costs real money and
takes as long as building a small feature takes. The free run alone does **not**
prove the pipeline end to end — only `--full` does.

### 2.1 Headless invocation

```bash
claude -p "<prompt>" --output-format json --allowedTools "..." [--permission-mode acceptEdits] [--resume <id>]
```

- A slash command expands in print mode **only when the prompt starts with it**,
  one per call; `$ARGUMENTS` is everything after it. Verified.
- `--output-format json` returns one envelope: `.type == "result"`, `.is_error`,
  `.result` (text), `.session_id`.
- `--resume <session_id> -p "<text>"` continues a session. This is the only way
  to answer an interactive command headlessly.
- A subagent is dispatched by asking the session to call the `Agent` tool with
  `subagent_type: "<plugin>:<agent>"`, with `Agent` in `--allowedTools`.
  Verified for `pr-review-toolkit:code-reviewer` — the namespace matters, because
  `feature-dev` and `superpowers` each ship an agent also called `code-reviewer`.
- A skill is invoked as a slash command: `/superpowers:systematic-debugging <text>`
  answers "Systematic debugging is loaded". Verified for both Superpowers skills
  the pipeline uses, so the skill demonstrably loads instead of being named in
  prose and hoped for.
- **No structured output is requested anywhere.** None of these tools publishes a
  JSON contract, and inventing one via `--json-schema` would mean FeatureBandit
  re-deciding what the tool already decided.

### 2.2 How Spec Kit is spelled

`specify init --integration claude` installs Spec Kit **as skills**, not as
slash-command files — its own help says "Claude installs skills by default". The
result is `.claude/skills/speckit-<name>/SKILL.md`, invoked `/speckit-specify`
(hyphen). Older or non-default installs use `.claude/commands/speckit.<name>.md`,
invoked `/speckit.specify` (dot).

FeatureBandit detects which of the two is on disk and uses that spelling. It
never guesses the separator, and it refuses to start unless all eight commands
it drives are present.

### 2.3 Dependency detection

- Spec Kit: `.specify/` at the repository root plus the eight command or skill
  files above.
- Plugins: `claude plugin list --json`, matching the plugin name before `@` with
  `.enabled == true`, any marketplace.
- Gum: `command -v gum`, and only when there is a terminal to draw on. Verified
  against gum 2.0.0: `gum choose` and `gum confirm` exit 1 with
  `could not open TTY` when stdin is not a terminal, so a non-interactive run
  never calls them and does not need gum installed. `gum style` works either
  way and drops colour on its own when the output is redirected or `NO_COLOR`
  is set.

Nothing is installed behind the user's back. A missing dependency prints its
exact official install command, and then offers to run that command — the same
command, in the foreground, in full view:

```bash
brew install jq          # or apt-get / dnf / pacman, whichever this machine has
brew install gum

curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
specify init --here --force --non-interactive --integration claude

claude plugin install pr-review-toolkit@claude-plugins-official --scope user
claude plugin install code-simplifier@claude-plugins-official --scope user
claude plugin marketplace add https://github.com/obra/superpowers.git && \
  claude plugin install superpowers@superpowers-dev --scope user
```

Declining is always an option and always stops the run; off a terminal the
answer must come from `FEATUREBANDIT_CHOICES` like any other, or
`FEATUREBANDIT_INSTALL=1` answers yes to all of them up front. Claude Code
itself is never installed automatically: it needs a sign-in, so a missing
`claude` prints the link and stops. Spec Kit scaffolding is committed straight
away when the tree was clean beforehand — it belongs to the repository, not to a
feature — and never when it was not.

`install.sh` does the same for a fresh machine: it links `featurebandit` onto
`PATH`, then offers each missing dependency in turn (`FEATUREBANDIT_YES=1`
answers yes to all).

### 2.4 What each tool guarantees

| Tool | Machine-readable contract | Consequence |
|---|---|---|
| `speckit-specify` | writes `.specify/feature.json` → `feature_directory` | the feature directory is read from it, never guessed |
| `speckit-clarify` | one question per turn, each prefixed `**Question:**`; ≤5 | the marker ends the loop, not a guess about the prose |
| `speckit-checklist` | `- [ ] CHK###` / `- [x]` in `<feature>/checklists/*.md` | open items are counted and listed at the spec gate |
| `speckit-tasks` / `speckit-implement` | `- [ ] T###` → `- [X] T###` in `tasks.md` | the batch and resume signal |
| `speckit-converge` | append-only; `tasks.md` byte-identical ⇔ converged | compared with `git hash-object` |
| `speckit-analyze` | none; read-only markdown report | user gate |
| PR Review Toolkit agents | none; markdown reports | user gate |
| `/security-review` | none; markdown report | user gate |

**Where a tool publishes no machine-readable severity, FeatureBandit shows its
output verbatim and asks.** It never parses prose to invent a status.

### 2.5 Known incompatibilities

1. `speckit-clarify` cannot run unattended. It asks one question per turn and
   waits. FeatureBandit relays each turn to the terminal and feeds the answer
   back with `--resume`, stopping when the output carries no `**Question:**`
   line, when the user answers with nothing (which sends Spec Kit's documented
   `done` signal), or at Spec Kit's own limit of five.
2. `speckit-analyze`, the review agents and `/security-review` return prose.
   Their findings are never auto-classified — every one of them ends in an
   explicit approval gate.
3. `speckit-implement` has no batch flag. The batch is expressed in
   `$ARGUMENTS`; correctness does not depend on the model honouring it, because
   progress is read from the `[X]` markers afterwards.
4. Spec Kit is a Python CLI and needs `uv`. FeatureBandit will not install it.
5. Spec Kit's core never changes the git branch, but its optional `git`
   extension can. FeatureBandit therefore asserts the branch before and after
   every plugin call rather than assuming it (§3, Git).
6. `gum spin` renders a **static** title: it has no elapsed-time counter and no
   way to update the title while the command runs. Since the pipeline must show
   real elapsed seconds, the spinner and the counter are a small Bash timer
   instead (§3, Terminal output). Gum keeps the menus, prompts and styling.

---

## 3. Architecture

```text
featurebandit           # entry point: CLI, start/resume, pipeline loop
lib/
  common.sh             # ui, the claude wrapper, git, verification gate
  bootstrap.sh          # dependency checks, branch creation, verify config
  state.sh              # state.json
  stages.sh             # one function per stage
```

The shell owns transitions, git and exit codes. The plugins own the engineering
and their own artifacts. There is no framework, daemon, database, background
worker, plugin abstraction or DSL, and no adapter layer for tools that are not
in §1.

### Portability

`bash`, `git`, `jq`, `claude`. Shebang `#!/usr/bin/env bash`. No GNU-only `sed
-i`, `grep -P`, `readlink -f`, `realpath` or `/proc`. GNU `timeout` is absent on
stock macOS, so a stage is bounded by a background watchdog process instead.

### Git

- The tree must be clean before anything is touched.
- A **new** branch is created off HEAD. `featurebandit/<slug>` is never reused:
  a colliding name becomes `featurebandit/<slug>-2`, `-3`, … A title with no
  ASCII letters (Cyrillic, CJK) gets `feature-<cksum>` so it is still unique.
- **Branch invariant.** `git rev-parse --abbrev-ref HEAD` is compared with
  `state.branch` at the top of every pipeline iteration and immediately after
  every plugin call. A mismatch stops the run — state and commits must never
  describe different branches.
- `.featurebandit/` is added to the exclude file found via
  `git rev-parse --git-path info/exclude`, which is correct in a linked worktree.
- Review diffs are always `git diff <startCommit>...HEAD`.
- **Every commit is atomic with the state it represents.** A batch commits the
  code *and* the `[X]` markers in `tasks.md` together, so a Ctrl-C leaves no
  window: either the commit exists and those tasks are done, or neither is true.
- Rollback of an interrupted block is `git checkout -- .` **and**
  `git clean -fd` — tracked edits and files the block created.
- FeatureBandit never merges, never pushes, never stashes and never edits
  `CLAUDE.md`. Project rules belong to Spec Kit's constitution.

### Failure policy

Any failing `git`, `jq`, `mv`, state write or commit stops the run immediately.
A checkpoint is never written after a failed commit or state write. State writes
are atomic (`state.json.tmp` then `mv`).

State reads are **fail closed**, which needs care in shell: a `$(...)` capture
runs in a subshell, so an `exit` inside it would not stop the run. Therefore
`fb_state_ok` validates `state.json` in the parent shell before every pipeline
iteration, and `fb_load_state` reads every field in one `jq` call whose exit
status is checked in the parent and cached in shell variables. Stages read those
variables, not `state.json`.

Reaching the end of input at a menu is an error, not a default — the run stops
rather than silently choosing.

### The command runner

Every command — a Spec Kit call, an agent dispatch, a verification command —
goes through one function, `fb_run`. It:

- writes stdout and stderr to two files beside each other, so a machine-readable
  stdout stays parseable while stderr is still kept verbatim;
- pipes nothing, so `$?` is the command's own exit code, preserved and reported;
- writes to `<log>.partial` and `mv`s into place, so a log is either complete or
  absent, and a failed `mkdir`, open or `mv` stops the stage;
- times the call and reports `completed in 24s` or `failed after 24s · exit 1`;
- starts the command in **its own process group** (`set -m`) with stdin on
  `/dev/null`, and records that group. A Claude Code session is a process tree;
  signalling only the shell that started it would leave the tree running. The
  watchdog and the `EXIT`/`INT`/`TERM` traps therefore terminate the whole group
  — `TERM`, one second, then `KILL`.

Nothing is ever `eval`ed. Commands are passed as argument arrays. The single
exception is documented: a verification command is a user-supplied shell
expression, so it runs as `sh -c "<the line>"` in the repository root, in its
own process — one explicit contract, not string-built commands everywhere.

### Verification gate

Deterministic, in the shell, never AI. Every command in every attempt gets its
own log; nothing is overwritten.

**One command is required, or an explicit skip.** The setup gate offers
*accept the detected commands*, *enter my own* and *skip verification entirely*;
where nothing was detected, `skip` typed on the first line does the same. A skip
is written to `.featurebandit/config` as `VERIFY_SKIPPED=1`, so it survives a
resume, and it is announced at every stage that would have verified, in the
stage summary and in the final summary. Nothing else in the pipeline checks what
the model wrote, so a skipped run is the user's word alone — which is why it
cannot happen by pressing Enter.

Detection is a fixed table, confirmed by the user:

| Marker | Test | Lint |
|---|---|---|
| `package.json` | `npm test` | `npm run lint` |
| `pyproject.toml` / `pytest.ini` | `pytest` | `ruff check .` |
| `go.mod` | `go test ./...` | `go vet ./...` |
| `Cargo.toml` | `cargo test` | `cargo clippy -- -D warnings` |
| `Makefile` | `make test` | `make lint` |

A failing command opens a `/superpowers:systematic-debugging` session, bounded to
three rounds, then hands the choice to the user (retry / shell out / stop).

The **final** verification, in the `done` stage, is the one gate that can still
change code. If it passes, the feature is finished. If it fails and the
debugging session then changes something that gets committed, that code has
never been reviewed, simplified, security-checked or converged: the `review`,
`simplify`, `security` and `converge` checkpoints are cleared and the pipeline
goes back through them. Nothing is declared finished on the strength of a fix
nobody reviewed.

### Retrying a failed call

A **read** call — a review agent, `/security-review` — writes nothing, so it is
retried once automatically and then handed to the user.

A **write** call is never retried automatically. `speckit.specify`, `.tasks`,
`.implement`, Code Simplifier and the TDD and debugging sessions can all have
edited files, run scripts or half-finished their work before failing; rerunning
one on FeatureBandit's initiative could duplicate or continue that partial work.
The failure is shown and the user chooses: stop (the default — resume redoes the
block from the last checkpoint), discard every uncommitted change and retry, or
retry keeping what was already written.

### Terminal output

`lib/ui.sh` holds every rendering decision and nothing else: it never touches
state, git or exit codes. Its whole surface is `ui_stage_start`,
`ui_stage_summary`, `ui_pipeline`, `ui_step_start`, `ui_step_success`,
`ui_step_failure`, `ui_block`, `ui_output`, `ui_info`, `ui_warning`,
`ui_error`, `ui_command`, `ui_detail`, `ui_gate`, `ui_confirm` and `ui_prompt`.

**Interactive or not.** Interactive means `TERM` is not `dumb`, both stdout and
stderr are terminals, and `CI` is unset; `FEATUREBANDIT_TTY=1|0` forces it
either way. `NO_COLOR` drops colour but leaves the interactive behaviour alone.

|  | interactive | not interactive |
|---|---|---|
| menus | `gum choose` — arrow keys, highlighted option, Enter takes the first (safe) one | the options are printed and the answer comes from `FEATUREBANDIT_CHOICES` |
| yes/no | `gum confirm`, defaulting to no | same, from `FEATUREBANDIT_CHOICES` |
| free text | `gum input`, or `gum choose` over the options the tool itself offered | one line read from stdin |
| progress | spinner glyph and elapsed seconds, repainted in place on stderr | one plain line at the start, then a line every 15s; no cursor movement at all |
| colour | semantic | none |

**Colour and symbols.** Cyan for stages and running steps, green for success,
yellow for warnings and anything awaiting a decision, red for failure, dim grey
for commands, paths and technical detail, and no colour at all for plugin
output — a report is shown exactly as the plugin wrote it. Symbols are `◆`
stage, `→` running, `✓` done, `✗` failed, `!` warning, `?` your decision, `•`
detail, with an ASCII fallback when the locale is not UTF-8.

**Approvals fail closed.** Off a terminal, an approval that was not passed in
advance is not an approval: the run stops and says which variable to set, rather
than hanging or assuming. `FEATUREBANDIT_CHOICES` is a comma-separated list of
option letters, consumed in order:

```bash
FEATUREBANDIT_CHOICES=a,a,c,a,a,a featurebandit "Add a health endpoint" < answers.txt
```

Gum's exit code is always checked. A cancelled selection (Ctrl-C or Esc) is
never read as a choice — it stops the stage. `gum confirm` answers 0 for yes and
1 for no; any other exit is gum failing, not the user saying no, and is reported
as the error it is.

**The first option is never an approval.** Enter takes the first option, so no
menu offers approval there: the review and security gates lead with *fix and
review again*, the compliance-gap gate with *stop here*, and the specification
and plan gates with *view it*. Accepting findings unfixed, accepting a
compliance gap and approving an artifact are all deliberate selections. A gate
that accepts findings unfixed records which report was accepted, and the final
summary lists exactly those — a report that was fixed, or that the user marked
as having nothing to fix, is not listed.

**Elapsed time, never a percentage.** How much work a plugin or an AI session
has left is unknowable, so a percentage or a progress bar would be decoration
that misleads. What is shown is real elapsed seconds, updated once a second,
measured with bash's `SECONDS` — the most reliable clock portable bash offers.
Status lines and the timer go to **stderr**; captured output goes to its log.

**Nothing is left running.** The timer is a single background process whose PID
is recorded; it is torn down by `ui_timer_stop` at the end of every step and by
an `EXIT`/`INT`/`TERM` trap. The watchdog that bounds a long call sleeps one
second at a time and exits as soon as its target does, so killing it can never
orphan a long `sleep`. The command itself runs in its own process group, and
both the watchdog and the traps end that whole group, so a Ctrl-C during a long
Claude Code call leaves no `claude` and no child of one behind.

---

## 4. State

```text
.featurebandit/
├── state.json          # the only workflow state
├── config              # VERIFY_COMMAND_N
├── requirements.md     # raw input, verbatim
├── diff.patch          # startCommit...HEAD, regenerated per review
├── *.md                # the verbatim text each tool reported
└── logs/<feature>/
    ├── specification/  clarify-01.log  specify-01.log  specify-01.log.err …
    ├── plan/
    ├── implementation/
    ├── review/
    ├── simplification/
    ├── security/
    ├── compliance/
    └── verification/   implementation-01.log  implementation-02.log …
```

Log names are deterministic — stage directory, block name, and a two-digit
attempt that never reuses a number, with the task ids in the name for an
implementation batch. Logs are never committed: `.featurebandit/` is in the
repository's exclude file. Environment variables and secrets are never written
to a log; only the command's own output is.

The UI reads this state and adds none of its own: stage status comes from
`checkpoints`, and a stage's measured duration is written into `durations` in
the same atomic write as its checkpoint.

Everything about the feature itself lives where Spec Kit puts it:
`specs/<NNN-slug>/{spec.md,plan.md,tasks.md,checklists/}`, committed on the
branch. That is the archive — merging the feature merges its specification, and
the next feature reads it as existing behaviour through Spec Kit.

```json
{
  "title": "Add greeting",
  "slug": "add-greeting",
  "branch": "featurebandit/add-greeting",
  "startCommit": "abc1234",
  "originalBranch": "main",
  "featureDir": "specs/001-add-greeting",
  "stage": "review",
  "convergeRounds": 0,
  "checkpoints": {
    "specify": true, "plan": true, "implement": true,
    "review": false, "simplify": false, "security": false,
    "converge": false, "done": false
  }
}
```

Resume starts at the first checkpoint that is false. Within implementation,
resume is per batch and comes from `tasks.md`, not from `state.json`: an already
implemented task is `[X]` in the commit and `speckit-implement` skips it.

---

## 5. Pipeline

```text
specification → plan → implementation → review → simplification → security
              → compliance ─┐
                            └─ if converge appended tasks: implement them, then
                               review, simplify and secure them too
```

Compliance runs **last** on purpose. Review, simplification and security all
change code, so whether the result still satisfies the specification can only be
decided on what is actually going to be merged.

### 5.1 Bootstrap (every run, not persisted)

`git`, `jq`, `claude`, Spec Kit (layout and all eight commands), the three
plugins — each missing one offered for installation, then rechecked; clean tree;
new unique branch off HEAD; `.featurebandit/` excluded; verification commands
configured. Starting a new feature after a finished one resets
`.featurebandit/`, verification commands included: the next feature is not
silently checked with the last one's commands.

### 5.2 Specification → `specify`

1. `speckit-specify <raw requirements>`.
2. Read `feature_directory` from `.specify/feature.json`.
3. Clarification loop: relay each `**Question:**` turn, answer via `--resume`.
   When the turn carries Spec Kit's own option table, its rows are drawn as a
   menu and the answer sent back is the option key Spec Kit printed; the keys
   and the wording stay Spec Kit's, and "type my own answer" is always the last
   entry. A turn without a table is answered as free text, as before.
4. `speckit-checklist completeness, unambiguous requirements, testable
   acceptance criteria, failure behaviour, permissions and validation`.
5. **Spec gate.** Open checklist items are counted and listed. Approve, view the
   spec, or clarify further and recheck. The checklist existing is not the same
   as the checklist passing, and FeatureBandit does not judge the items itself.
6. Commit the artifacts.

### 5.3 Plan → `plan`

1. `speckit-plan`, `speckit-tasks`, commit.
2. `speckit-analyze`, output shown verbatim.
3. Each finding goes back to the artefact that owns it: clarify the
   specification and replan, rerun plan and tasks, or rerun tasks only.
   **`speckit-specify` is never re-run** — that would create a second feature
   directory instead of correcting the current specification.
4. **Plan gate.**

### 5.4 Implementation → `implement`

Repeat while `tasks.md` has unchecked tasks:

1. `speckit-implement` naming the next three task ids. Test-first ordering is
   Spec Kit's own contract: `speckit-tasks` emits the test task before the
   implementation task and `speckit-implement` executes them in order.
2. Verification gate in a plain shell.
3. One commit: code + `tasks.md` markers.
4. If no marker changed, stop and ask — never loop silently.

### 5.5 Review → `review`

PR Review Toolkit agents over `diff.patch`, always `code-reviewer`,
`pr-test-analyzer`, `silent-failure-hunter`, plus:

- `type-design-analyzer` when the diff adds type declarations,
- `comment-analyzer` when the diff adds or removes comment or documentation lines.

Each report is shown verbatim and saved. The blocking policy is deterministic and
belongs to the user, in four explicit choices: fix (a
`/superpowers:test-driven-development` session over the reports, then
verification and a commit — bounded to three rounds), stop and look at them,
nothing to fix in this report, or accept the open findings unfixed. Only the last
one is recorded as an accepted finding, and only it appears in the final summary.
Fixing is the first option, so Enter never accepts anything.

### 5.6 Simplification → `simplify`

`code-simplifier:code-simplifier`, scoped to the files the diff changes, no
behaviour change, then verification and a commit.

### 5.7 Security → `security`

Built-in `/security-review`. Same gate as §5.5.

### 5.8 Compliance → `converge`

1. Verification.
2. `speckit-converge`. `tasks.md` unchanged ⇒ converged, checkpoint.
3. Otherwise: commit the appended tasks, implement them (§5.4), verify, then
   clear the review, simplification and security checkpoints so the new code
   gets the same treatment the rest did, and re-enter the pipeline at review.
4. After `convergeRounds` reaches 3 the user decides: accept the remaining gap,
   go round again, or stop.

### 5.9 Done → `done`

Final verification, then the summary: branch, commits, verification commands, the
specification path, and the reports whose findings the user chose to accept
rather than fix — exactly those, and `none` when there were none. There is **no
separate AI final acceptance** — converge, the review agents, the security
review and the tests already cover it. Nothing is merged or pushed.

If the final verification fails, the fix that makes it pass is code nobody has
reviewed, so `review`, `simplify`, `security` and `converge` are reopened and
run again before the feature can finish.

---

## 6. CLI

```bash
featurebandit                     # interactive start, or resume
featurebandit requirements.md     # start from a file
featurebandit "Add RBAC support"  # start from text
featurebandit resume
featurebandit status
featurebandit abort
```

`abort` restores the original branch **first**. If that checkout fails, nothing
is deleted and no success is reported.

---

## 7. Tests

| Suite | Cost | Covers |
|---|---|---|
| `test/smoke.sh` | free | the whole pipeline against `test/fake-claude` |
| `test/regress.sh` | free | 27 failure and resume scenarios |
| `test/e2e.sh` | free | plugins enabled, every agent file the pipeline names, the Spec Kit layout and all eight commands, in a real repository (a throwaway one if this repository has no Spec Kit) |
| `test/ui.sh` | free | 17 interface scenarios against a stubbed gum |
| `test/e2e.sh --dispatch` | real API calls | a real `pr-review-toolkit:code-reviewer` dispatch and both Superpowers skills actually loading |
| `test/e2e.sh --full` | real API calls, real time | one complete pipeline against the real tools in a throwaway repository: every Spec Kit command, the review agents, Code Simplifier, `/security-review`, the verification gate and the final summary |

`test/regress.sh` covers: missing Spec Kit, missing plugin, a failing plugin
command, a dirty tree, an existing feature branch, a Cyrillic title, a linked
worktree, a failing commit, a failing state write, interruption after a batch
commit, failing verification, skipping verification on purpose, refusing to run
without verification and without a skip, rollback of
untracked files, converge appending tasks and the work being reviewed again,
abort with a failed checkout, resume after every stage, an open checklist item,
clarify with nothing to ask, an analyze finding never restarting specify, a
plugin that moves the git branch, installing a missing plugin on request, a
failed write call never being retried on its own, discarding a partial write
before a retry, a fix at the final verification going back through review, a new
feature not inheriting the last one's verification commands, and the summary
listing only the findings that were really accepted.

`test/ui.sh` covers: an interactive choice through gum, an option table from a
tool becoming a menu, a cancelled choice, a failing gum call, gum missing while a terminal is in use, gum not being needed
without one, an approval that was never given, an answer that is not on offer,
`NO_COLOR`, `TERM=dumb`, no invented percentage, the timer leaving nothing
behind after success, failure and interruption, Ctrl-C ending the running
command and not just the runner, the command's own exit code
surviving, per-block logs keeping stdout and stderr whole, a long output shown
as a bounded preview, verification logs never overwriting each other, a log that
cannot be written, and what a resume reports.

---

## 8. Out of scope

Browser QA, multi-feature or parallel workflows, background workers, cloud
execution, CI/CD integration, GitHub/Jira sync, web UI, server mode, databases,
multiple LLM providers, generic plugin frameworks, multi-repo workflows.
