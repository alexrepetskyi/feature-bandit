#!/usr/bin/env bash
# preflight: tools, git, plugins, project conventions, verification gate

FB_PLUGINS="feature-dev superpowers code-simplifier"
FB_MARKETPLACE="claude-plugins-official"

fb_require_tools() {
  command -v claude >/dev/null 2>&1 || die "claude not found. Install Claude Code: https://claude.com/claude-code"
  command -v jq  >/dev/null 2>&1 || die "jq not found. Install jq and retry."
  command -v git >/dev/null 2>&1 || die "git not found. Install git and retry."
  FB_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  FB_DIR="$FB_ROOT/.featurebandit"
}

fb_plugin_installed() {
  printf '%s' "$1" | jq -e --arg n "$2" \
    'map(select((.id | split("@")[0]) == $n and .enabled)) | length > 0' >/dev/null 2>&1
}

fb_check_plugins() {
  local list missing="" name
  list=$(claude plugin list --json 2>/dev/null) || list='[]'
  for name in $FB_PLUGINS; do
    if fb_plugin_installed "$list" "$name"; then
      say "  $FB_OK $name"
    else
      say "  $FB_NO $name"
      missing="$missing $name"
    fi
  done
  [ -z "$missing" ] && return 0

  fb_menu "Install missing plugins automatically? [y/n]" "yn"
  [ "$FB_CHOICE" = y ] || die "required plugins missing:$missing"

  for name in $missing; do
    step "Installing $name"
    claude plugin install "$name@$FB_MARKETPLACE" --scope user >/dev/null 2>&1 ||
      die "failed to install $name@$FB_MARKETPLACE. If the marketplace is not configured, run: claude plugin marketplace add $FB_MARKETPLACE"
  done

  list=$(claude plugin list --json 2>/dev/null) || list='[]'
  for name in $missing; do
    fb_plugin_installed "$list" "$name" || die "plugin still missing after install: $name"
  done
}

fb_rules_block() {
  cat <<'EOF'
<!-- featurebandit:rules:start -->
# Engineering style (FeatureBandit)
- Be sharp and direct: facts, conclusions, code. No thinking out loud.
- Build exactly what was asked. Nothing extra "for the future". YAGNI.
- Prefer the smallest working solution; no abstractions or config options for hypothetical requirements.
- No error handling, logging, retries, or validation beyond what the task needs.
- Don't refactor surrounding code unless asked. Reuse what exists before writing new code.
- Follow the engineering guide in .featurebandit/guide.md.
<!-- featurebandit:rules:end -->
EOF
}

fb_install_rules() {
  local f="$FB_ROOT/CLAUDE.md" tmp="$FB_TMP/claudemd" line skip=0
  local start='<!-- featurebandit:rules:start -->'
  local end='<!-- featurebandit:rules:end -->'
  : > "$tmp"

  if [ -f "$f" ] && grep -qF "$start" "$f"; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$start") skip=1; fb_rules_block >> "$tmp"; continue ;;
        "$end")   skip=0; continue ;;
      esac
      [ $skip -eq 1 ] || printf '%s\n' "$line" >> "$tmp"
    done < "$f"
  else
    if [ -f "$f" ]; then
      cat "$f" >> "$tmp"
      printf '\n' >> "$tmp"
    fi
    fb_rules_block >> "$tmp"
  fi
  mv "$tmp" "$f"
}

fb_install_guide() {
  cp "$FB_HOME/lib/guide.md" "$FB_DIR/guide.md"
}

fb_git_exclude() {
  local ex="$FB_ROOT/.git/info/exclude"
  [ -d "$FB_ROOT/.git/info" ] || return 0
  grep -qxF '.featurebandit/' "$ex" 2>/dev/null && return 0
  printf '.featurebandit/\n' >> "$ex"
}

# clean tree + feature branch; echoes "startCommit originalBranch"
fb_git_start() {
  local slug="$1" branch head
  fb_tree_clean || {
    warn "working tree is not clean:"
    fb_git status --short >&2
    die "commit or stash your changes first — FeatureBandit never touches them"
  }
  branch=$(fb_git rev-parse --abbrev-ref HEAD 2>/dev/null)
  head=$(fb_git rev-parse HEAD 2>/dev/null) || die "repository has no commits yet — make an initial commit first"
  fb_git checkout -q -b "featurebandit/$slug" 2>/dev/null ||
    fb_git checkout -q "featurebandit/$slug" || die "cannot create branch featurebandit/$slug"
  printf '%s %s' "$head" "$branch"
}

# --- verification gate detection --------------------------------------------

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
  : > "$FB_DIR/config"
  for c in "$@"; do
    [ -n "$c" ] || continue
    printf 'VERIFY_COMMAND_%s=%s\n' "$i" "$c" >> "$FB_DIR/config"
    i=$((i + 1))
  done
  printf 'SECURITY_BLOCK_MEDIUM=0\n' >> "$FB_DIR/config"
}

fb_ask_verify_commands() {
  local cmds="" line n=0
  say "Enter verification commands (lint, tests), one per line. Empty line to finish."
  while :; do
    printf '> '
    IFS= read -r line || break
    [ -z "$line" ] && break
    cmds="$cmds$line
"
    n=$((n + 1))
  done
  if [ $n -eq 0 ]; then
    warn "no verification commands — nothing will check the tests the model writes"
    fb_menu "Continue without verification? [y/n]" "yn"
    [ "$FB_CHOICE" = y ] || return 1
    fb_write_verify_config
    return 0
  fi
  local old="$IFS"
  IFS='
'
  set -- $cmds
  IFS="$old"
  fb_write_verify_config "$@"
}

fb_setup_verify() {
  fb_config_get VERIFY_COMMAND_1 >/dev/null 2>&1 && return 0
  [ -f "$FB_DIR/config" ] && return 0

  fb_detect_verify
  if [ -n "$FB_DET_TEST" ] || [ -n "$FB_DET_LINT" ]; then
    say ""
    say "Detected verification commands:"
    [ -n "$FB_DET_LINT" ] && say "  $FB_DET_LINT"
    [ -n "$FB_DET_TEST" ] && say "  $FB_DET_TEST"
    fb_menu "[a] Accept  [e] Enter my own" "ae"
    if [ "$FB_CHOICE" = a ]; then
      fb_write_verify_config "$FB_DET_LINT" "$FB_DET_TEST"
      return 0
    fi
  else
    say ""
    say "No test runner detected in this repository."
  fi
  fb_ask_verify_commands
}

fb_bootstrap() {
  fb_require_tools
  say "Plugins:"
  fb_check_plugins
  mkdir -p "$FB_DIR"
  fb_git_exclude
  fb_install_rules
  fb_install_guide
}
