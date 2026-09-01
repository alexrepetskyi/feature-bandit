#!/usr/bin/env bash
# preflight: tools, Spec Kit, plugins, git branch, verification gate
# shellcheck disable=SC2153
#   FB_DIM, FB_ROOT and the other FB_* variables are set in the files sourced
#   before this one, which shellcheck cannot follow across a runtime `source`.

FB_MARKETPLACE="claude-plugins-official"
FB_SK_COMMANDS="specify clarify checklist plan tasks analyze implement converge"
FB_SPECKIT_CLI="uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
FB_SPECKIT_INIT="specify init --here --force --non-interactive --integration claude"

# --- installing what is missing ----------------------------------------------
# FeatureBandit can install its own dependencies, but never behind your back:
# it prints the exact command and asks first. FEATUREBANDIT_INSTALL=1 answers
# yes up front, for a non-interactive run.

fb_ask_install() { # WHAT
  [ "${FEATUREBANDIT_INSTALL:-}" = 1 ] && return 0
  ui_gate "Install $1 now?" "i:Install it now" "q:Stop here and do it myself" || return 1
  [ "$FB_CHOICE" = i ]
}

# Installs run in the foreground and in full view: this changes the machine, so
# it is not hidden in a log file.
fb_install_run() { # SHELL_COMMAND
  ui_command "$1"
  # in the repository root, not wherever you happened to be: `specify init
  # --here` scaffolds into the current directory
  ( cd "${FB_ROOT:-$PWD}" && sh -c "$1" ) >&2 || { ui_error "that command failed"; return 1; }
  # a fresh uv, npm or pipx install lands here and is not on PATH yet
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; export PATH ;; esac
  return 0
}

# the package manager this machine actually has
fb_pkg_install_cmd() { # PACKAGE
  if   command -v brew    >/dev/null 2>&1; then printf 'brew install %s' "$1"
  elif command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$1"
  elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$1"
  elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm %s' "$1"
  else return 1; fi
}

# offer to install one package with the system package manager
fb_offer_pkg() { # PACKAGE
  local cmd
  cmd=$(fb_pkg_install_cmd "$1") || return 1
  ui_err ""
  ui_err "  $cmd"
  ui_err ""
  fb_ask_install "$1" || return 1
  fb_install_run "$cmd" || return 1
  command -v "$1" >/dev/null 2>&1
}

# Gum draws the menus and styles the output. It is only needed when there is a
# terminal to draw on: a non-interactive run renders plain lines instead.
fb_require_gum() {
  if command -v gum >/dev/null 2>&1; then
    ui_err "  $FB_GRN$FB_S_OK$FB_OFF gum"
    return 0
  fi
  [ "$FB_TTY" = 1 ] || { ui_err "  $FB_DIM$FB_S_TODO gum (not needed without a terminal)"; return 0; }
  ui_err "  $FB_RED$FB_S_NO$FB_OFF gum"
  if fb_offer_pkg gum; then
    ui_err "  $FB_GRN$FB_S_OK$FB_OFF gum"
    return 0
  fi
  die "gum draws the interactive menus. Install it:

  brew install gum                         # macOS or Linux
  sudo pacman -S gum                       # Arch
  sudo dnf install gum                     # Fedora, EPEL 10
  winget install charmbracelet.gum         # Windows
  nix-env -iA nixpkgs.gum                  # Nix

  Debian and Ubuntu: https://github.com/charmbracelet/gum#installation

  Or run without a terminal and pass the decisions up front:
  FEATUREBANDIT_CHOICES=a,a,c,a,a,a featurebandit \"...\""
}

fb_require_tools() {
  command -v git  >/dev/null 2>&1 || die "git not found. Install git and retry."
  command -v jq   >/dev/null 2>&1 || fb_offer_pkg jq || die "jq not found:
  brew install jq            # macOS
  sudo apt install jq        # Debian, Ubuntu, WSL"
  command -v claude >/dev/null 2>&1 || die "claude not found. Install Claude Code:
  https://claude.com/claude-code"
  FB_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  FB_DIR="$FB_ROOT/.featurebandit"
}

# Spec Kit installs its commands for Claude either as skills (the default since
# 1.0.x: .claude/skills/speckit-<name>/) or as slash commands
# (.claude/commands/speckit.<name>.md). Whichever is on disk decides how they
# are spelled — FeatureBandit never guesses the separator.
fb_speckit_layout() {
  [ -d "$FB_ROOT/.specify" ] || return 1
  if [ -f "$FB_ROOT/.claude/skills/speckit-specify/SKILL.md" ]; then
    FB_SK="/speckit-"
  elif [ -f "$FB_ROOT/.claude/commands/speckit.specify.md" ]; then
    FB_SK="/speckit."
  else
    return 1
  fi
  return 0
}

# the CLI, then the repository. Spec Kit scaffolding belongs to the repository,
# not to a feature, so it is committed before any branch is taken — but only
# when the tree was clean beforehand, so nobody else's work is swept into it.
fb_speckit_install() {
  local was_clean=0
  fb_tree_clean && was_clean=1
  if ! command -v specify >/dev/null 2>&1; then
    command -v uv >/dev/null 2>&1 ||
      fb_install_run 'curl -LsSf https://astral.sh/uv/install.sh | sh' || return 1
    fb_install_run "$FB_SPECKIT_CLI" || return 1
  fi
  command -v specify >/dev/null 2>&1 || { ui_error "specify is still not on PATH"; return 1; }
  fb_install_run "$FB_SPECKIT_INIT" || return 1
  if [ $was_clean -eq 1 ] && ! fb_tree_clean; then
    fb_git add -A || return 1
    fb_git commit -qm "Initialise GitHub Spec Kit" || return 1
    ui_info "committed the Spec Kit scaffolding"
  fi
  return 0
}

fb_speckit_missing() {
  ui_err "  $FB_RED$FB_S_NO$FB_OFF spec kit"
  ui_err ""
  ui_err "GitHub Spec Kit is not initialised in this repository. Install and initialise it:"
  ui_err ""
  ui_err "  $FB_SPECKIT_CLI"
  ui_err "  $FB_SPECKIT_INIT"
  ui_err ""
  ui_err "  (uv: https://docs.astral.sh/uv/  —  spec kit: https://github.com/github/spec-kit)"
  ui_err ""
  fb_ask_install "GitHub Spec Kit in this repository" || die "spec kit is not initialised here"
  fb_speckit_install || die "could not initialise spec kit here"
  fb_speckit_layout || die "spec kit ran, but its claude integration is still not on disk"
}

fb_require_speckit() {
  local name missing=""
  fb_speckit_layout || fb_speckit_missing

  for name in $FB_SK_COMMANDS; do
    if [ "$FB_SK" = "/speckit-" ]; then
      [ -f "$FB_ROOT/.claude/skills/speckit-$name/SKILL.md" ] || missing="$missing $name"
    else
      [ -f "$FB_ROOT/.claude/commands/speckit.$name.md" ] || missing="$missing $name"
    fi
  done
  [ -z "$missing" ] || {
    ui_err "  $FB_RED$FB_S_NO$FB_OFF spec kit"
    die "this Spec Kit install is missing:$missing
  reinitialise it: specify init --here --force --non-interactive --integration claude"
  }

  ui_err "  $FB_GRN$FB_S_OK$FB_OFF spec kit (${FB_SK}*)"
  [ -f "$FB_ROOT/.specify/extensions.yml" ] &&
    ui_warning "spec kit extensions are configured — if one of them moves the git branch, FeatureBandit will stop"
  return 0
}

# name -> the exact official command that installs it
fb_plugin_install_cmd() {
  case "$1" in
    superpowers) printf 'claude plugin marketplace add https://github.com/obra/superpowers.git && claude plugin install superpowers@superpowers-dev --scope user' ;;
    *)           printf 'claude plugin install %s@%s --scope user' "$1" "$FB_MARKETPLACE" ;;
  esac
}

fb_plugin_enabled() { # NAME
  claude plugin list --json 2>/dev/null | jq -e --arg n "$1" \
    'map(select((.id | split("@")[0]) == $n and .enabled)) | length > 0' >/dev/null 2>&1
}

fb_check_plugins() {
  local missing="" name
  for name in $FB_PLUGINS; do
    if fb_plugin_enabled "$name"; then
      ui_err "  $FB_GRN$FB_S_OK$FB_OFF $name"
    else
      ui_err "  $FB_RED$FB_S_NO$FB_OFF $name"
      missing="$missing $name"
    fi
  done
  [ -z "$missing" ] && return 0

  ui_err ""
  ui_err "Missing plugins. Install them with:"
  for name in $missing; do
    ui_err ""
    ui_err "  $(fb_plugin_install_cmd "$name")"
  done
  ui_err ""
  fb_ask_install "the missing plugin(s):$missing" || die "required plugins missing:$missing"

  for name in $missing; do
    fb_install_run "$(fb_plugin_install_cmd "$name")" || die "could not install $name"
    fb_plugin_enabled "$name" || die "$name is installed but not enabled — enable it with: claude plugin enable $name"
    ui_err "  $FB_GRN$FB_S_OK$FB_OFF $name"
  done
  return 0
}

# works in a linked worktree, where .git is a file and info/ lives elsewhere
fb_git_exclude() {
  local ex
  ex=$(fb_git rev-parse --git-path info/exclude) || fb_fail "git rev-parse failed"
  case "$ex" in /*) ;; *) ex="$FB_ROOT/$ex" ;; esac
  mkdir -p "$(dirname "$ex")" || fb_fail "could not create $(dirname "$ex")"
  grep -qxF '.featurebandit/' "$ex" 2>/dev/null && return 0
  printf '.featurebandit/\n' >> "$ex" || fb_fail "could not write $ex"
}

# ascii slug; a title with no ascii letters still gets a stable unique one
fb_slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | tr -s '-')
  s=${s#-}; s=${s%-}; s=${s:0:40}; s=${s%-}
  [ -n "$s" ] || s="feature-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  printf '%s' "$s"
}

# a featurebandit/<slug> branch that already exists is never reused
fb_unique_branch() {
  local base="featurebandit/$1" n=2 branch="featurebandit/$1"
  while fb_git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; do
    branch="$base-$n"
    n=$((n + 1))
    [ $n -gt 99 ] && fb_fail "too many branches named $base-*"
  done
  printf '%s' "$branch"
}

# clean tree + a new branch off HEAD; echoes "startCommit<TAB>originalBranch<TAB>branch"
fb_git_start() {
  local branch orig head
  fb_tree_clean || {
    ui_warning "working tree is not clean:"
    fb_git status --short >&2
    die "commit or stash your changes first — FeatureBandit never touches them"
  }
  head=$(fb_git rev-parse HEAD 2>/dev/null) ||
    die "repository has no commits yet — make an initial commit first"
  orig=$(fb_git rev-parse --abbrev-ref HEAD) || fb_fail "git rev-parse failed"
  branch=$(fb_unique_branch "$1")
  fb_git checkout -q -b "$branch" || fb_fail "cannot create branch $branch"
  printf '%s\t%s\t%s' "$head" "$orig" "$branch"
}

# --- verification gate -------------------------------------------------------

fb_detect_verify() {
  FB_DET_TEST=""; FB_DET_LINT=""
  if [ -f "$FB_ROOT/package.json" ]; then
    jq -e '.scripts.test' "$FB_ROOT/package.json" >/dev/null 2>&1 && FB_DET_TEST="npm test"
    jq -e '.scripts.lint' "$FB_ROOT/package.json" >/dev/null 2>&1 && FB_DET_LINT="npm run lint"
  elif [ -f "$FB_ROOT/pyproject.toml" ] || [ -f "$FB_ROOT/pytest.ini" ]; then
    FB_DET_TEST="pytest"
    { [ -f "$FB_ROOT/.ruff.toml" ] || grep -q ruff "$FB_ROOT/pyproject.toml" 2>/dev/null; } && FB_DET_LINT="ruff check ."
  elif [ -f "$FB_ROOT/go.mod" ]; then
    FB_DET_TEST="go test ./..."; FB_DET_LINT="go vet ./..."
  elif [ -f "$FB_ROOT/Cargo.toml" ]; then
    FB_DET_TEST="cargo test"; FB_DET_LINT="cargo clippy -- -D warnings"
  elif [ -f "$FB_ROOT/Makefile" ]; then
    grep -qE '^test:' "$FB_ROOT/Makefile" && FB_DET_TEST="make test"
    grep -qE '^lint:' "$FB_ROOT/Makefile" && FB_DET_LINT="make lint"
  fi
}

fb_write_verify_config() {
  local i=1 c
  : > "$FB_DIR/config" || fb_fail "could not write $FB_DIR/config"
  for c in "$@"; do
    [ -n "$c" ] || continue
    printf 'VERIFY_COMMAND_%s=%s\n' "$i" "$c" >> "$FB_DIR/config" ||
      fb_fail "could not write $FB_DIR/config"
    i=$((i + 1))
  done
  [ $i -eq 1 ] && die "at least one verification command is required"
  return 0
}

fb_ask_verify_commands() {
  local cmds="" line n=0 old
  ui_err "Enter verification commands (lint, tests), one per line. Empty line to finish."
  while :; do
    printf '> ' >&2
    IFS= read -r line || break
    if [ -z "$line" ]; then
      [ $n -gt 0 ] && break
      ui_warning "at least one command is required — nothing else runs the tests the model writes"
      continue
    fi
    cmds="$cmds$line
"
    n=$((n + 1))
  done
  [ $n -eq 0 ] && die "at least one verification command is required"
  old="$IFS"; IFS='
'
  # shellcheck disable=SC2086
  #   splitting on newlines is the point: one typed line becomes one command
  set -- $cmds
  IFS="$old"
  fb_write_verify_config "$@"
}

fb_setup_verify() {
  fb_config_get VERIFY_COMMAND_1 >/dev/null 2>&1 && return 0

  fb_detect_verify
  if [ -n "$FB_DET_TEST" ] || [ -n "$FB_DET_LINT" ]; then
    ui_err ""
    ui_err "Detected verification commands:"
    [ -n "$FB_DET_LINT" ] && ui_err "  $FB_DET_LINT"
    [ -n "$FB_DET_TEST" ] && ui_err "  $FB_DET_TEST"
    ui_gate "Use these to verify every change?" "a:Accept them" "e:Enter my own" || return 1
    [ "$FB_CHOICE" = a ] && { fb_write_verify_config "$FB_DET_LINT" "$FB_DET_TEST"; return 0; }
  else
    ui_err ""
    ui_err "No test runner detected in this repository."
  fi
  fb_ask_verify_commands
}
