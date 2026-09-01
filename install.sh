#!/usr/bin/env bash
# Install FeatureBandit. Run it from a clone, or pipe it from curl to clone first.

REPO="https://github.com/alexrepetskyi/feature-bandit.git"
CLONE="${FEATUREBANDIT_HOME:-$HOME/.feature-bandit}"
BINDIR="${FEATUREBANDIT_BIN:-$HOME/.local/bin}"

ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }
die()  { printf '  fail  %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required to install"

# source directory: this clone, or a fresh one when piped from curl
SRC=""
case "$0" in
  */*) CAND=$(cd -- "$(dirname -- "$0")" && pwd)
       [ -f "$CAND/featurebandit" ] && [ -d "$CAND/lib" ] && SRC="$CAND" ;;
esac

if [ -z "$SRC" ]; then
  if [ -d "$CLONE/.git" ]; then
    git -C "$CLONE" pull --quiet || die "could not update $CLONE"
    ok "updated $CLONE"
  else
    git clone --quiet "$REPO" "$CLONE" || die "could not clone into $CLONE"
    ok "cloned into $CLONE"
  fi
  SRC="$CLONE"
else
  ok "installing from $SRC"
fi

chmod +x "$SRC/featurebandit" "$SRC/test/smoke.sh" "$SRC/test/regress.sh" 2>/dev/null

# Git Bash cannot be trusted with symlinks: put the clone itself on PATH
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    ok "Windows shell detected — skipping the symlink"
    note "add this to ~/.bashrc, then open a new terminal:"
    note "  export PATH=\"$SRC:\$PATH\""
    exit 0
    ;;
esac

mkdir -p "$BINDIR" || die "could not create $BINDIR"
ln -sf "$SRC/featurebandit" "$BINDIR/featurebandit" || die "could not link into $BINDIR"
ok "linked $BINDIR/featurebandit"

# --- runtime dependencies ----------------------------------------------------
# They are needed to use FeatureBandit, not to install it, so a failure here is
# a warning with the exact command, never a failed install. Nothing is
# installed without a yes: FEATUREBANDIT_YES=1 answers yes for all of them.

ask_yes() { # QUESTION
  local reply
  [ "${FEATUREBANDIT_YES:-}" = 1 ] && return 0
  [ -r /dev/tty ] || return 1
  printf '        %s [y/N] ' "$1" > /dev/tty
  read -r reply < /dev/tty || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

pkg_cmd() { # PACKAGE
  if   command -v brew    >/dev/null 2>&1; then printf 'brew install %s' "$1"
  elif command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$1"
  elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$1"
  elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm %s' "$1"
  else return 1; fi
}

run_install() { # COMMAND
  printf '        $ %s\n' "$1"
  sh -c "$1" || { printf '  warn  that command failed\n'; return 1; }
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; export PATH ;; esac
  return 0
}

need() { command -v "$1" >/dev/null 2>&1; }

install_pkg() { # PACKAGE  DESCRIPTION
  local cmd
  need "$1" && { ok "$1"; return 0; }
  if ! cmd=$(pkg_cmd "$1"); then
    printf '  warn  %s is not installed and no known package manager was found\n' "$1"
    return 1
  fi
  printf '  warn  %s is not installed\n' "$1"
  note "$2"
  ask_yes "install $1 with \`$cmd\`?" || { note "$cmd"; return 1; }
  run_install "$cmd" && need "$1" && ok "$1"
}

install_pkg jq  "jq reads the JSON envelopes Claude Code returns"
install_pkg gum "gum draws the interactive menus; without a terminal it is not used"

need claude || {
  printf '  warn  claude is not installed\n'
  note "install Claude Code and sign in: https://claude.com/claude-code"
}

# Spec Kit: the CLI here, the per-repository init inside each repository
if need specify; then
  ok "specify"
else
  printf '  warn  the Spec Kit CLI is not installed\n'
  if ask_yes "install uv and specify-cli?"; then
    need uv || run_install 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    need uv && run_install 'uv tool install specify-cli --from git+https://github.com/github/spec-kit.git'
    need specify && ok "specify"
  fi
  need specify || {
    note "uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
    note "then, in each repository: specify init --here --force --non-interactive --integration claude"
  }
fi

# the plugins FeatureBandit drives
if need claude; then
  installed=$(claude plugin list --json 2>/dev/null || echo '[]')
  for plugin in superpowers pr-review-toolkit code-simplifier; do
    case "$installed" in
      *"\"$plugin@"*) ok "$plugin"; continue ;;
    esac
    if [ "$plugin" = superpowers ]; then
      cmd='claude plugin marketplace add https://github.com/obra/superpowers.git && claude plugin install superpowers@superpowers-dev --scope user'
    else
      cmd="claude plugin install $plugin@claude-plugins-official --scope user"
    fi
    printf '  warn  the %s plugin is not installed\n' "$plugin"
    if ask_yes "install the $plugin plugin?"; then
      run_install "$cmd" && ok "$plugin"
    else
      note "$cmd"
    fi
  done
fi

case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on your PATH" ;;
  *)
    profile="$HOME/.bashrc"
    case "$SHELL" in */zsh) profile="$HOME/.zshrc" ;; esac
    printf '  warn  %s is not on your PATH\n' "$BINDIR"
    note "run this, then open a new terminal:"
    note "  echo 'export PATH=\"$BINDIR:\$PATH\"' >> $profile"
    ;;
esac

printf '\nInstalled. Try it in a repository with a clean working tree:\n\n'
printf '  featurebandit "Add a health endpoint"\n\n'
