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

chmod +x "$SRC/featurebandit" "$SRC/test/smoke.sh" 2>/dev/null

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

# runtime dependencies are needed to use it, not to install it
for dep in jq claude; do
  command -v "$dep" >/dev/null 2>&1 || {
    printf '  warn  %s is not installed\n' "$dep"
    [ "$dep" = jq ] && note "brew install jq   |   sudo apt install jq"
    [ "$dep" = claude ] && note "https://claude.com/claude-code"
  }
done

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
