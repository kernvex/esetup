# Module: claude — sourced by setup.sh, not executable on its own.
# Depends on shared machinery in setup.sh: log_info/log_warn/log_error, record_manual, record_failed, prompt_yes_no, brew_owns_* , and the NONINTERACTIVE / SCRIPT_DIR globals.

# Install Claude Code CLI without Homebrew (Linux/WSL, or any non-brew host). Uses the
# official native installer, which drops a self-updating `claude` binary into ~/.local/bin
# (no Node required) and works on both Linux and macOS. Idempotent: re-running updates in place.
install_claude_code_native() {
  if ! command -v curl &>/dev/null; then
    log_error "curl is required to install Claude Code. Install curl and re-run."
    return 1
  fi
  if command -v claude &>/dev/null; then
    log_info "claude already on PATH: $(command -v claude)."
    if ! prompt_yes_no "Reinstall/update Claude Code via the native installer?" n; then
      return 0
    fi
  fi
  log_info "Installing Claude Code CLI via the official installer (https://claude.ai/install.sh)."
  if curl -fsSL https://claude.ai/install.sh | bash; then
    log_info "Claude Code installed. If 'claude' isn't found, add ~/.local/bin to PATH or open a new shell."
  else
    log_error "Native Claude Code install failed. See https://docs.claude.com/en/docs/claude-code for manual steps."
    return 1
  fi
}

# Anthropic Claude, per host:
#   macOS  — the desktop app (cask `claude` = Chat/Cowork/Code GUI, auto-updates) stays a cask.
#            The CLI uses the NATIVE installer, not the `claude-code` cask. We tried brew-managing
#            it "so Claude Code defers self-updates to brew" — but the native updater wins in
#            practice: it self-updates into ~/.local/share/claude/versions and its ~/.local/bin
#            symlink shadows the older brew copy, so the two race and the report flags claude-code
#            as shadowed forever. One self-updating copy (native) is the only stable end state.
#            --upgrade therefore no longer manages Claude Code; it updates itself.
#   Linux/WSL (or unknown) — no official desktop cask exists, so install just the Claude Code
#            CLI via the native installer. On WSL this is the in-distro Linux CLI; the Windows
#            desktop app (if wanted) is installed separately on the Windows side.
install_claude() {
  [[ -n "$OS_KIND" ]] || detect_os
  if [[ "$OS_KIND" == "macos" ]]; then
    brew_install_cask claude "Claude (desktop app)"
  fi
  install_claude_code_native
}

# Personal fork of mattpocock/skills (the `skills` submodule) symlinked into
# ~/.claude/skills. The installer inits the submodule and, on re-runs, syncs from
# upstream and pushes the fork. See docs/claude-skills/ for the full model.
setup_claude_skills() {
  bash "${SCRIPT_DIR}/scripts/install-claude-skills.sh"
}

# agent-reach CLI (the vendor-skills/agent-reach submodule): the binary behind the vendored
# agent-reach skill, which install-vendor-skills.sh generates only once this is on PATH. uv
# installs it FROM THE SUBMODULE PATH, so the version is the pinned SHA and a bump is a
# `git submodule update --remote` plus a re-run, the same loop as every other vendored skill.
# Not an Artifact: uv owns the venv. Under --upgrade an installed copy converges onto the
# submodule (reinstall) and an absent one is reported, never introduced; same contract as the
# other optional_* steps. Only the binary is installed here: the per-platform tools it routes
# to (yt-dlp, gh, twitter-cli, ...) are agent-reach's own business, `agent-reach install`.
optional_agent_reach() {
  if ! command -v uv &>/dev/null; then
    log_warn "uv not on PATH; skipping agent-reach (install uv, then re-run)."
    return 0
  fi
  local src="${SCRIPT_DIR}/vendor-skills/agent-reach"
  local present=0
  command -v agent-reach &>/dev/null && present=1

  # Decide before touching the submodule. An --upgrade run on a machine that never took
  # agent-reach must not init a submodule (network) only to report the binary absent, and a
  # declined prompt must leave no trace either.
  if [[ "$present" -eq 0 ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      record_manual "agent-reach" "absent — --upgrade does not install optional artifacts; run setup.sh without --upgrade"
      return 0
    fi
    if ! prompt_yes_no "Install the agent-reach CLI via uv (fetchers behind the agent-reach skill: X, Reddit, YouTube, ...)?" n; then
      return 0
    fi
  fi

  if [[ ! -f "${src}/pyproject.toml" ]]; then
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
      log_info "Initializing vendor-skills/agent-reach submodule..."
      if ! git -C "${SCRIPT_DIR}" submodule update --init vendor-skills/agent-reach; then
        log_warn "Submodule init failed. From the esetup repo root run: git submodule update --init vendor-skills/agent-reach"
        return 1
      fi
    fi
    [[ -f "${src}/pyproject.toml" ]] || { log_error "vendor-skills/agent-reach missing (no pyproject.toml); clone esetup with submodules."; return 1; }
  fi

  # uv's status is the function's status: setup.sh pairs this with record_failed.
  if [[ "$present" -eq 1 ]]; then
    log_info "agent-reach present; converging onto the pinned submodule (uv tool install --reinstall)."
    uv tool install --quiet --reinstall "$src" || return 1
    return 0
  fi
  uv tool install --quiet "$src" || return 1
  log_info "agent-reach installed. 'agent-reach install --env=auto' is a read-only check of the per-platform tools it still needs."
}
