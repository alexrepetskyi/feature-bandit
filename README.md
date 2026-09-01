# FeatureBandit

Terminal orchestrator that takes one feature from raw requirements to reviewed,
tested code. Portable shell scripts around the Claude Code CLI — no runtime, no
SDK, no API keys of its own.

**The shell makes workflow decisions; Claude makes engineering decisions.** Every
stage is a fresh `claude -p` call returning schema-validated JSON. The script
reads the verdict and decides what happens next, so the pipeline is deterministic
even though the work inside each stage is not.

```
requirements ──▶ specification ──▶ plan ──▶ implementation ──▶ done
                      │              │            │
                   reviewed       reviewed    per task:
                 independently  independently  tests + lint
                                                  ↓
                                        compliance ▶ code review
                                        ▶ simplify ▶ security ▶ accept
```

Each arrow is a checkpoint written to `.featurebandit/state.json`. Ctrl-C
anywhere; the next run resumes from the last one.

## What it does

- **Explores the repository first.** Reads the code, the conventions, the tests,
  and every previously archived spec before writing anything.
- **Asks about real gaps only.** Blocking questions must be answered; the rest can
  be skipped and are recorded as accepted assumptions. Answers are never re-asked.
- **Writes a specification with stable FR/AC ids**, then has a *separate* session
  review it — the reviewer never shares context with the author.
- **Plans against the spec**, and checks the plan by traceability: every
  requirement must map to a task, or it is a blocking finding.
- **Implements task by task, test first**, committing only after the tests and
  linter pass in a plain shell. A committed tree is a working tree.
- **Runs your project's own tests and linter as the gate** — detected from
  `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, or a `Makefile`, and
  confirmed by you. Tests the model wrote count only when they pass outside the
  model's session.
- **Reviews the diff adversarially** for correctness, then simplifies it, then
  reviews it for vulnerabilities. Critical and high findings block; the rest are
  reported.
- **Archives the approved spec to `docs/specs/`** on the feature branch. The next
  feature reads it as existing behavior and must state any change as superseding.
- **Never merges and never touches your uncommitted work.** All work happens on
  `featurebandit/<slug>`; `abort` puts you back where you started.

## Requirements

`bash`, `git`, `jq`, and the `claude` CLI. Bootstrap installs the three plugins it
needs (`feature-dev`, `superpowers`, `code-simplifier`) on first run.

```bash
brew install jq                      # macOS
sudo apt install jq                  # Debian/Ubuntu/WSL
```

## Install

Clone once, then symlink the entry point onto your `PATH`. The script follows the
symlink back to its own directory, so the clone can live anywhere — just don't
move it afterwards without redoing the link.

**macOS / Linux / WSL**

```bash
git clone git@github.com:alexrepetskyi/feature-bandit.git ~/.feature-bandit
mkdir -p ~/.local/bin
ln -s ~/.feature-bandit/featurebandit ~/.local/bin/featurebandit
```

If `~/.local/bin` is not on your `PATH` yet, add it to your shell profile
(`~/.zshrc` for zsh, `~/.bashrc` for bash) and open a new terminal:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Prefer a system-wide install? Use `sudo ln -s ~/.feature-bandit/featurebandit
/usr/local/bin/featurebandit` instead — same result, needs root.

**Git Bash on Windows**

Symlinks are unreliable there, so put the clone itself on `PATH`:

```bash
git clone git@github.com:alexrepetskyi/feature-bandit.git ~/.feature-bandit
echo 'export PATH="$HOME/.feature-bandit:$PATH"' >> ~/.bashrc
```

**Verify**

```bash
featurebandit status      # "not inside a git repository" outside a repo is correct
```

**Update**

```bash
git -C ~/.feature-bandit pull
```

The engineering guide and the rules block in `CLAUDE.md` are refreshed on the next
run in each repository.

## Usage

```bash
featurebandit                     # resume, or start interactively
featurebandit requirements.md     # start from a file
featurebandit "Add RBAC support"  # start from text
featurebandit status              # where it stopped
featurebandit abort               # back to the original branch
```

Start in a repository with a clean working tree and at least one commit.
`FEATUREBANDIT_VERBOSE=1` prints what each session returned.

## Layout

```
featurebandit      entry point: arguments, resume, the stage loop
lib/common.sh      ui, the claude wrapper, git helpers, the verification gate
lib/state.sh       state.json and checkpoints
lib/bootstrap.sh   preflight, plugins, project conventions, gate detection
lib/stages.sh      the nine stages: schemas, prompts, decisions
lib/guide.md       engineering guide installed into the target repository
```

Artifacts live in `.featurebandit/` (git-excluded, one active feature per
repository). Only the spec outlives the feature.

## Testing it

```bash
./test/smoke.sh
```

Runs the whole pipeline against a stubbed `claude` in throwaway repositories: no
API calls, no cost. Covers the happy path, dirty-tree refusal, interrupt and
resume, a failing test gate with its fix loop, an interactive review failure, and
abort.

See [docs/SPEC.md](docs/SPEC.md) for the full specification.
