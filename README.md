# FeatureBandit

Takes one feature from a sentence of requirements to reviewed, tested code on its
own branch — by driving tools that already exist, not by inventing a methodology.

FeatureBandit is a handful of bash scripts. It owns git, workflow state,
approval gates, running your commands, verification and resume. Everything else
belongs to a plugin:

| Stage | Owner |
|---|---|
| Specification, clarification, plan, tasks, analysis, implementation, convergence | [GitHub Spec Kit](https://github.com/github/spec-kit) |
| Test-first discipline and debugging | [Superpowers](https://github.com/obra/superpowers) |
| Code review | PR Review Toolkit |
| Simplification | Code Simplifier |
| Security | Claude Code's built-in `/security-review` |
| The terminal interface | [Charmbracelet Gum](https://github.com/charmbracelet/gum) |

Nothing running in the background, no API key of its own, no home-grown review
prompts.

## How it works

Eight stages in a fixed order, each one a fresh `claude -p` call running an
official command, skill or agent. The shell reads the result and decides whether
to move on, and checks after every call that nothing moved the git branch.

```
specification → plan → implementation → review → simplification → security
              → compliance ─┐
                            └─ new work found? implement, then review it too
```

**Specification.** `/speckit-specify`, then `/speckit-clarify` relays its
questions to your terminal one at a time, then `/speckit-checklist`. At the gate
you see how many checklist items are still open and which ones, and can clarify
further before approving — a checklist existing is not a checklist passing.

**Plan.** `/speckit-plan`, `/speckit-tasks`, `/speckit-analyze`. Each finding
goes back to the artefact that owns it: clarify the spec, redo the plan, or redo
the tasks. It never re-runs `specify`, which would start a second feature.

**Implementation.** `/speckit-implement` runs three tasks at a time. After each
batch your own tests and linter have to pass in a plain shell — not just inside
the model's session — before anything is committed. Code and the `[X]` markers in
`tasks.md` go into the same commit, so Ctrl-C never loses or repeats a task.

**Review, simplification, security.** The PR Review Toolkit agents on the feature
diff, then Code Simplifier, then `/security-review`. These tools report in prose,
not with machine-readable severities — so FeatureBandit shows you what they said
and asks, rather than guessing a status out of the text. Fixes go through
`/superpowers:test-driven-development`, and a failing check through
`/superpowers:systematic-debugging`.

**Compliance last.** `/speckit-converge` looks for what the spec asks for and the
code does not do. It runs *after* review, simplification and security, because
those change code — compliance has to be judged on what you are actually going to
merge. If converge appends tasks, they get implemented, verified, and then
reviewed, simplified and security-checked in their turn, until it appends nothing.

## What you see

Every stage is numbered and framed, every long call shows what it is doing and
how many seconds it has been doing it, and every finished block says whether it
worked, how long it took, and where its full log is.

```
◆ 4/8 · Implementation
  Implementing tasks in batches, verifying each in a plain shell

⠋ Implementing T001 T002 T003 · 17s
✓ Implementing T001 T002 T003 completed in 24s
────────────────────────────────────────────────────────────
✓ Verification: make test
  Status:   success
  Duration: 38s
  Command:  make test
  Output:   .featurebandit/logs/add-greeting/verification/implementation-02.log
────────────────────────────────────────────────────────────

  142 passed, 0 failed

  Full output: .featurebandit/logs/add-greeting/verification/implementation-02.log

• commit a1b2c3d  featurebandit: implement T001 T002 T003

────────────────────────────────────────────────────────────
✓ Implementation completed in 4m 18s
  Tasks:        T001 T002 T003 T004
  Verification: 2/2 passed
  Commits:      a1b2c3d e4f5a6b
  Logs:         .featurebandit/logs/add-greeting/implementation/
  Next:         Review
────────────────────────────────────────────────────────────
```

The elapsed seconds are real and update once a second. There is no percentage
and no progress bar: nobody knows how much work an AI session has left, so a
number like `60%` would be decoration that misleads you.

Approvals are arrow-key menus drawn by [Gum](https://github.com/charmbracelet/gum),
with the safe option selected first and Enter to take it. Enter never approves
anything: the review and security gates start on *fix and review again*, a
compliance gap starts on *stop here*, and the spec and plan gates start on *view
it*. Accepting findings unfixed is a deliberate choice, and the final summary
lists exactly the reports you accepted that way. Findings from the review agents
and the security review are shown exactly as those tools wrote them — nothing is
re-read, ranked or summarised on their behalf.

Run it with the output piped to a file or in CI and it renders plain lines
instead: no colour, no cursor movement, no spinner, and a progress line every
fifteen seconds. It never waits for input it cannot get. Approvals must then be
passed up front, or the run stops and tells you so:

```bash
FEATUREBANDIT_CHOICES=a,a,c,a,a,a featurebandit "Add a health endpoint"
```

`NO_COLOR` turns colour off, `TERM=dumb` turns every escape sequence off, and
`FEATUREBANDIT_TTY=0|1` forces either mode.

Every command's full output is kept, stdout and stderr separately, under
`.featurebandit/logs/<feature>/<stage>/`, one file per attempt so nothing is
ever overwritten. What you see on screen is a preview; the log is never cut.

## Everything else

Everything happens on `featurebandit/<slug>`. It never merges, never pushes and
never touches your uncommitted work. Ctrl-C is safe — the running Claude Code
session and everything it started are terminated with it, then rerun and it
continues from the last checkpoint, `featurebandit status` shows where that is,
and `featurebandit abort` puts you back where you started.

A call that could have written files is never retried on its own: if
`/speckit-implement` or a fix session fails halfway, you are shown the output
and asked whether to stop, discard what it wrote and retry, or retry as is.
Rerunning a half-finished write silently is how work gets duplicated.

The specification lives where Spec Kit puts it, `specs/<nnn-slug>/`, committed on
the branch. Merging the feature merges its spec, and the next feature builds on it.

```bash
featurebandit "Add RBAC support"   # start from a description
featurebandit requirements.md      # or from a file
featurebandit                      # resume where you left off
featurebandit status               # what's done, what's next
featurebandit abort                # drop the feature, back to your branch
```

## Requirements

`bash`, `git`, `jq`, the `claude` CLI and `gum`, plus Spec Kit initialised in
the repository and three Claude plugins. Gum is only required when there is a
terminal — a piped or CI run does not use it and does not ask for it.

FeatureBandit checks all of them on every run. For anything missing it prints
the exact official install command and offers to run it for you — `jq`, `gum`,
`uv`, the Spec Kit CLI, `specify init` in this repository, and each of the three
plugins. Declining stops the run; nothing is installed without a yes. Claude
Code itself is the exception: it needs a sign-in, so that one is yours to
install.

Spec Kit's Claude integration installs its commands as skills, so they are spelled
`/speckit-specify` with a hyphen. FeatureBandit also supports the older
`.claude/commands/speckit.specify.md` layout and uses whichever it finds.

The same commands, if you would rather run them yourself:

```bash
brew install jq            # macOS
sudo apt install jq        # Debian, Ubuntu, WSL

# gum draws the menus; only needed when you run it in a terminal
brew install gum           # macOS or Linux
sudo pacman -S gum         # Arch
sudo dnf install gum       # Fedora, EPEL 10

# Spec Kit, once per repository (needs uv: https://docs.astral.sh/uv/)
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
specify init --here --force --non-interactive --integration claude

# plugins, once per machine
claude plugin install pr-review-toolkit@claude-plugins-official --scope user
claude plugin install code-simplifier@claude-plugins-official --scope user
claude plugin marketplace add https://github.com/obra/superpowers.git
claude plugin install superpowers@superpowers-dev --scope user
```

Run it inside a git repository that has at least one commit and no uncommitted
changes. You will be asked for at least one verification command — there is no
way to continue without one.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexrepetskyi/feature-bandit/main/install.sh | bash
```

This clones into `~/.feature-bandit`, puts `featurebandit` in `~/.local/bin`,
and offers to install every dependency it cannot find — `FEATUREBANDIT_YES=1`
answers yes to all of them.
If you already have the repo, run `./install.sh` from it and it links that copy
instead. Running it again pulls the latest version and relinks, so it doubles as
the update command.

Check it worked:

```bash
featurebandit status
```

Outside a repository that prints "not inside a git repository", which means it
loaded fine. If the command isn't found at all, `~/.local/bin` isn't on your
`PATH` — the installer prints the line to add. To install somewhere else, set
`FEATUREBANDIT_BIN`, for example `sudo FEATUREBANDIT_BIN=/usr/local/bin
./install.sh`.

---

Full specification: [docs/SPEC.md](docs/SPEC.md).

```bash
./test/smoke.sh             # the whole pipeline against a stubbed Claude, free
./test/regress.sh           # 26 failure and resume scenarios, free
./test/ui.sh                # the terminal interface and the logs, free
./test/e2e.sh               # check the real plugins and Spec Kit install, free
./test/e2e.sh --dispatch    # also dispatch a real agent and load the real skills
./test/e2e.sh --full        # one whole real pipeline in a throwaway repository
```
