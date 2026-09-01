# FeatureBandit

Takes one feature from a sentence of requirements to reviewed, tested code on its
own branch.

You describe the feature and answer a few questions. It explores your repository,
writes a specification, plans the work, implements it test-first, reviews what it
wrote, and hands you a branch to merge. It is a handful of bash scripts driving
the Claude Code CLI — nothing running in the background, no API key of its own.

## How it works

Nine stages in a fixed order. Each one is a fresh Claude session with a focused
prompt; the shell reads the result and decides whether to move on. That split is
the whole idea — Claude makes the engineering decisions, the script owns the
workflow, so the pipeline stays predictable even though the work inside it isn't.

```
requirements → spec → plan → implementation → compliance
             → code review → simplify → security → done
```

**Requirements.** Reads your code and any specs from earlier features, then asks
only about gaps that would actually change the implementation. Blocking questions
need an answer; the rest you can skip.

**Spec and plan.** Each is written, then reviewed by a separate session that never
saw the author's context, then approved by you. The plan review checks that every
requirement maps to a task.

**Implementation.** Task by task, test first. After each task your own tests and
linter have to pass in a plain shell — not just inside the model's session —
before anything gets committed. The commands are detected from `package.json`,
`pyproject.toml`, `go.mod`, `Cargo.toml`, or a `Makefile`, and you confirm them.

**Reviews.** Compliance against the spec, an adversarial code review,
simplification, then security. Critical and high findings block and get fixed; the
rest are reported and left to you.

Everything happens on `featurebandit/<slug>`, one commit per task. It never merges
and never touches your uncommitted work. Ctrl-C is safe — rerun and it continues
from the last checkpoint, `featurebandit status` shows where that is, and
`featurebandit abort` puts you back where you started.

The approved spec is committed to `docs/specs/`. The next feature reads it as
existing behavior, so specs pile up into a description of what the project does.

```bash
featurebandit "Add RBAC support"   # start from a description
featurebandit requirements.md      # or from a file
featurebandit                      # resume where you left off
featurebandit status               # what's done, what's next
featurebandit abort                # drop the feature, back to your branch
```

## Requirements

`bash`, `git`, `jq`, and the `claude` CLI. On first run it installs the three
Claude plugins it uses.

```bash
brew install jq            # macOS
sudo apt install jq        # Debian, Ubuntu, WSL
```

Run it inside a git repository that has at least one commit and no uncommitted
changes.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexrepetskyi/feature-bandit/main/install.sh | bash
```

This clones into `~/.feature-bandit` and puts `featurebandit` in `~/.local/bin`.
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

Full specification: [docs/SPEC.md](docs/SPEC.md). To watch the whole pipeline run
against a stubbed Claude, for free: `./test/smoke.sh`.
