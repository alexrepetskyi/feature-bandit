# FeatureBandit

Takes one feature from a sentence of requirements to reviewed, tested code on its
own branch.

It is a handful of bash scripts and invents no methodology of its own. It owns
git, workflow state, approval gates, running your tests and resume. Every
engineering decision belongs to a tool that already does that job:
[Spec Kit](https://github.com/github/spec-kit),
[Superpowers](https://github.com/obra/superpowers), PR Review Toolkit, Code
Simplifier and Claude Code's built-in `/security-review`.

## How it works

Eight stages in a fixed order. Each line is one `claude -p` call running an
official command, skill or agent; the shell reads the result, commits, and checks
that nothing moved the git branch.

```
1  Specification   /speckit-specify  →  /speckit-clarify ⇄ your answers
                   its questions become menus when it offers options
                   →  /speckit-checklist
                   gate: view · approve · clarify more · stop        → commit

2  Plan            /speckit-plan  →  /speckit-tasks  →  /speckit-analyze
                   gate: send each finding back to spec / plan / tasks
                   gate: view · approve the plan · stop              → commit

3  Implementation  /speckit-implement, three tasks at a time
                   your lint and tests, in a real shell, not in the model's head
                   └─ failed: /superpowers:systematic-debugging, up to 3 rounds
                   code and the [X] markers in tasks.md              → 1 commit

4  Review          Agent pr-review-toolkit:code-reviewer
                   Agent pr-review-toolkit:pr-test-analyzer
                   Agent pr-review-toolkit:silent-failure-hunter
                   Agent pr-review-toolkit:type-design-analyzer   (added when
                   Agent pr-review-toolkit:comment-analyzer        the diff
                                                                   calls for it)
                   gate: fix · stop · nothing to fix · accept unfixed
                   └─ fix: /superpowers:test-driven-development
                      → verify                                       → commit

5  Simplification  Agent code-simplifier:code-simplifier, diff files only
                   → verify                                          → commit

6  Security        /security-review                       same gate as 4

7  Compliance      /speckit-converge — what the spec asks for and the code
                   does not do. Runs last, because 4-6 change code.
                   └─ it appended tasks: implement them, then back to 4

8  Done            final verification → summary
                   └─ the fix changed code: reopen 4-7, nothing ships unreviewed
```

Superpowers is used in exactly two places: `systematic-debugging` when your tests
fail, and `test-driven-development` when review or security findings get fixed.
Both are invoked as slash commands, so the skill really loads.

Everything happens on `featurebandit/<slug>` — or on the branch you are already
on, with `FEATUREBANDIT_BRANCH=current`. It never merges, never pushes and never
touches your uncommitted work. Ctrl-C kills the running Claude session with
it; rerun and it continues from the last checkpoint. Every call's full output is
kept under `.featurebandit/logs/<feature>/<stage>/`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexrepetskyi/feature-bandit/main/install.sh | bash
```

Clones into `~/.feature-bandit`, links `featurebandit` into `~/.local/bin`, and
offers to install whatever is missing — `FEATUREBANDIT_YES=1` answers yes to all
of it. Run it again to update. From an existing clone, `./install.sh` links that
copy instead.

## Dependencies

| | |
|---|---|
| `bash`, `git`, `jq` | always |
| `claude` CLI | always — the only one you install yourself, it needs a sign-in |
| `gum` | only with a terminal; a piped or CI run does not use it |
| Spec Kit, initialised in the repository | `specify init --here --force --non-interactive --integration claude` |
| Plugins `superpowers`, `pr-review-toolkit`, `code-simplifier` | once per machine |

FeatureBandit checks all of them on every run and, for anything missing, prints
the official install command and offers to run it. Declining stops the run.

## Commands

```bash
featurebandit "Add RBAC support"   # start from a description
featurebandit requirements.md      # or from a file
featurebandit                      # resume where you left off
featurebandit status               # what is done, what is next
featurebandit abort                # drop the feature, back to your branch
```

Run it in a git repository with at least one commit and a clean tree. You will be
asked for at least one verification command — your linter and tests, run in a real
shell before every commit. If there is genuinely nothing to run, pick *skip
verification entirely* at the gate (or type `skip` at the prompt); it is recorded
and repeated at every stage, because then nothing but you is checking the code.

| Variable | |
|---|---|
| `FEATUREBANDIT_CHOICES=a,a,c,a,a,a` | gate answers when there is no terminal; without them the run stops rather than guessing |
| `FEATUREBANDIT_BRANCH=current` | work on the branch you are already on instead of creating `featurebandit/<slug>` |
| `FEATUREBANDIT_INSTALL=1` | say yes to installing missing dependencies |
| `FEATUREBANDIT_TIMEOUT=3600` | seconds one call may take |
| `NO_COLOR`, `FEATUREBANDIT_TTY=0` or `1` | colour off; force plain or interactive rendering |

## Tests

```bash
./test/smoke.sh             # the whole pipeline against a stubbed Claude, free
./test/regress.sh           # 29 failure and resume scenarios, free
./test/ui.sh                # the terminal interface and the logs, free
./test/e2e.sh               # the real plugins and Spec Kit install, free
./test/e2e.sh --dispatch    # also dispatch a real agent and load the real skills
./test/e2e.sh --full        # one whole real pipeline in a throwaway repository
```

Full specification: [docs/SPEC.md](docs/SPEC.md).
