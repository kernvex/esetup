#!/usr/bin/env bash
# macOS bootstrap: Homebrew, CLI tools, runtimes, dotfiles (stow), submodules.
# 2-space indent; guard clauses; interactive prompts.

set -euo pipefail

# The PATH we were invoked with, captured before anything mutates it. `ensure_homebrew`
# runs `eval "$(brew shellenv)"`, which prepends $(brew --prefix)/bin -- so after that
# point `command -v X` answers "which copy does *this script* see", not "which copy does
# the *user* run". Shadowed/Foreign are questions about the latter. See docs/adr/0002.
ESETUP_ORIGINAL_PATH="$PATH"

# Likewise for SHELL: export_shell_for_homebrew_fish sets SHELL=$(command -v fish) so
# Homebrew emits fish completions. Anything asking "what is the user's login shell?"
# must read this, not $SHELL -- otherwise it always answers "fish".
ESETUP_ORIGINAL_SHELL="${SHELL:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where the standalone dotfiles repo is cloned and stowed from (see docs/adr/0004).
TARGET_DOTFILES="${TARGET_DOTFILES:-${HOME}/kernvex/dotfiles}"
# Decrypted key from kernvex/ssh vault; per-repo git core.sshCommand uses this (no global ~/.ssh/config Host github.com).
ESETUP_SSH_IDENTITY="${ESETUP_SSH_IDENTITY:-${HOME}/.ssh/kernvex_id_ed25519}"

# Set by preflight_environment; 1 = do not install OrbStack cask this run
SKIP_ORBSTACK=0
SKIP_PREFLIGHT=0
# 1 = --claude fast path: install Claude Code + skills only, skip the rest
CLAUDE_ONLY=0
# 1 = --claude-skills fast path: set up ONLY the Claude skills (cross-platform: macOS/Linux/WSL)
CLAUDE_SKILLS_ONLY=0
# Set by detect_os: macos | wsl | linux | unknown
OS_KIND=""
CAVEATS_INFO=()
CAVEATS_ACTION=()

# --- Plan state (see docs/adr/0001, docs/adr/0002) --------------------------
# What to do with an Artifact that is already Brew-owned: prompt | skip | upgrade
IF_INSTALLED=prompt
# 1 = --upgrade: suppress prompts. Idempotent Non-Artifacts run; destructive ones
# become Manual entries rather than silently defaulting to "no" on a closed stdin.
NONINTERACTIVE=0

# Ownership: one bare `brew list` dump each (0.02s) instead of ~32 named probes
# (0.37s each). Built on every run — Foreign/Shadowed matter in all modes.
OWNED_FORMULAE=""
OWNED_CASKS=""
BREW_PREFIX_PATH=""

# The Plan: memoized `brew outdated --json=v2 --greedy`, one TSV record per
# Artifact with a Version Diff:  name<TAB>kind<TAB>installed<TAB>latest<TAB>pinned
# Only built under --upgrade (it needs a slow, online `brew update`).
# macOS ships bash 3.2 — no `declare -A` — hence a flat string + awk.
PLAN=""

# Manual: knowingly not converged, exits 0. Failed: tried and broke, exits 1.
MANUAL_ACTIONS=()
FAILED_ACTIONS=()

# Side channels set by the detection predicates, consumed for Reason text.
FOREIGN_PATH=""
UNOWNED_APP=""
RUNNING_APP=""

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERR]\033[0m $*" >&2; }

prompt_yes_no() {
  local msg="$1"
  local default="${2:-n}"
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  read -r -p "${msg} ${hint} " ans || true
  ans="${ans:-}"
  if [[ -z "$ans" ]]; then
    [[ "$default" == "y" ]] && return 0
    return 1
  fi
  [[ "$ans" =~ ^[Yy] ]]
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

get_brew_caveat_json() {
  local kind="$1"
  local name="$2"
  if [[ "$kind" == "formula" ]]; then
    brew info --json=v2 --formula "$name" 2>/dev/null || true
    return 0
  fi
  brew info --json=v2 --cask "$name" 2>/dev/null || true
}

record_caveat() {
  local kind="$1"
  local name="$2"

  if ! command -v jq &>/dev/null; then
    log_warn "jq not found; skipping caveat capture for ${name}."
    return 0
  fi

  local raw_json
  raw_json="$(get_brew_caveat_json "$kind" "$name")"
  [[ -n "$raw_json" ]] || return 0

  local caveat
  if [[ "$kind" == "formula" ]]; then
    caveat="$(printf '%s' "$raw_json" | jq -r '.formulae[0].caveats // empty' 2>/dev/null || true)"
  else
    caveat="$(printf '%s' "$raw_json" | jq -r '.casks[0].caveats // empty' 2>/dev/null || true)"
  fi
  [[ -n "$caveat" ]] || return 0
  [[ "$caveat" == "null" ]] && return 0

  local entry
  entry="${name}: ${caveat}"

  local lc
  lc="$(printf '%s' "$caveat" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lc" == *"path"* ]] \
    || [[ "$lc" == *"shellenv"* ]] \
    || [[ "$lc" == *"service"* ]] \
    || [[ "$lc" == *"launchctl"* ]] \
    || [[ "$lc" == *"manual"* ]] \
    || [[ "$lc" == *"completions"* ]] \
    || [[ "$lc" == *"post-install"* ]] \
    || [[ "$lc" == *"post install"* ]]; then
    if ! array_contains "$entry" "${CAVEATS_ACTION[@]+"${CAVEATS_ACTION[@]}"}"; then
      CAVEATS_ACTION+=("$entry")
    fi
    return 0
  fi

  if ! array_contains "$entry" "${CAVEATS_INFO[@]+"${CAVEATS_INFO[@]}"}"; then
    CAVEATS_INFO+=("$entry")
  fi
}

print_caveat_summary() {
  local has_any=0
  if [[ "${#CAVEATS_ACTION[@]}" -gt 0 ]]; then
    has_any=1
    echo
    echo "=============================="
    echo "Action required caveats"
    echo "=============================="
    local item
    for item in "${CAVEATS_ACTION[@]+"${CAVEATS_ACTION[@]}"}"; do
      echo
      printf '%s\n' "$item"
    done
  fi

  if [[ "${#CAVEATS_INFO[@]}" -gt 0 ]]; then
    has_any=1
    echo
    echo "=============================="
    echo "Informational caveats"
    echo "=============================="
    local info_item
    for info_item in "${CAVEATS_INFO[@]+"${CAVEATS_INFO[@]}"}"; do
      echo
      printf '%s\n' "$info_item"
    done
  fi

  [[ "$has_any" -eq 1 ]] || log_info "No Homebrew caveats collected."
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  [[ -f "$file" ]] || touch "$file"
  grep -Fqx "$line" "$file" && return 0
  printf '%s\n' "$line" >> "$file"
}

# Homebrew infers the target shell from $SHELL for completion install paths and caveat text.
# Call after fish is on PATH so subsequent brew installs target fish instead of zsh.
export_shell_for_homebrew_fish() {
  if command -v fish &>/dev/null; then
    SHELL="$(command -v fish)"
    export SHELL
    log_info "Using SHELL=${SHELL} for Homebrew (fish-targeted completions and caveats)."
  else
    log_warn "fish not on PATH; Homebrew will infer completion hints from your login shell."
  fi
}

link_homebrew_completions_for_fish() {
  command -v fish &>/dev/null || return 0
  local fish_bin
  fish_bin="$(command -v fish)"
  if SHELL="$fish_bin" brew completions link 2>/dev/null; then
    log_info "Ran: brew completions link (fish)."
  fi
}

# Thin wrapper. The work lives in scripts/apply-toolchain-env.sh so the same logic can be
# run on its own after installing or removing a toolchain by hand; duplicating it here as
# a function would mean two copies to keep honest. A broken shell env is worth reporting,
# never worth aborting a run over.
apply_toolchain_env() {
  local script="${SCRIPT_DIR}/scripts/apply-toolchain-env.sh"
  if [[ ! -x "$script" ]]; then
    log_warn "Missing or non-executable ${script}; skipping toolchain shell env."
    record_manual "toolchain-env" "scripts/apply-toolchain-env.sh missing or not executable"
    return 0
  fi
  TARGET_DOTFILES="$TARGET_DOTFILES" "$script" \
    || record_failed "toolchain-env" "apply-toolchain-env.sh failed"
  return 0
}

apply_known_caveat_actions() {
  local fish_cfg="${TARGET_DOTFILES}/fish/.config/fish/config.fish"
  local need_fish_paths=0
  local item
  for item in "${CAVEATS_ACTION[@]+"${CAVEATS_ACTION[@]}"}"; do
    local lc_item
    lc_item="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lc_item" == *"fish completions"* ]] || [[ "$lc_item" == *"vendor_completions.d"* ]]; then
      need_fish_paths=1
      break
    fi
  done

  if [[ "$need_fish_paths" -eq 1 ]]; then
    mkdir -p "$(dirname "$fish_cfg")"
    ensure_line_in_file "" "$fish_cfg"
    ensure_line_in_file "# Homebrew fish completion paths (auto-added from caveat actions)" "$fish_cfg"
    ensure_line_in_file "if test -d (brew --prefix)/share/fish/completions" "$fish_cfg"
    ensure_line_in_file "  set -p fish_complete_path (brew --prefix)/share/fish/completions" "$fish_cfg"
    ensure_line_in_file "end" "$fish_cfg"
    ensure_line_in_file "if test -d (brew --prefix)/share/fish/vendor_completions.d" "$fish_cfg"
    ensure_line_in_file "  set -p fish_complete_path (brew --prefix)/share/fish/vendor_completions.d" "$fish_cfg"
    ensure_line_in_file "end" "$fish_cfg"
    log_info "Applied known caveat action: added Homebrew fish completion paths to ${fish_cfg}."
  fi

  if [[ "${#CAVEATS_ACTION[@]}" -gt 0 ]]; then
    log_info "Manual caveat actions may still be needed for service/launchctl/path caveats shown above."
  fi
}

record_manual() {
  local entry="$1: $2"
  array_contains "$entry" "${MANUAL_ACTIONS[@]+"${MANUAL_ACTIONS[@]}"}" && return 0
  MANUAL_ACTIONS+=("$entry")
}

record_failed() {
  local entry="$1: $2"
  array_contains "$entry" "${FAILED_ACTIONS[@]+"${FAILED_ACTIONS[@]}"}" && return 0
  FAILED_ACTIONS+=("$entry")
}

# --- Ownership --------------------------------------------------------------
# "Installed" means exactly one thing when building a Plan: Homebrew has a receipt.
# `command -v X` and `/Applications/X.app` are different predicates (Foreign,
# Unowned App) and are handled separately.
build_ownership() {
  BREW_PREFIX_PATH="$(brew --prefix)"
  OWNED_FORMULAE="$(brew list --formula 2>/dev/null || true)"
  OWNED_CASKS="$(brew list --cask 2>/dev/null || true)"
}

brew_owns_formula() { printf '%s\n' "$OWNED_FORMULAE" | grep -qxF -- "$1"; }
brew_owns_cask() { printf '%s\n' "$OWNED_CASKS" | grep -qxF -- "$1"; }

path_inside_brew() {
  case "$1" in "${BREW_PREFIX_PATH}"/*) return 0 ;; esac
  return 1
}

# `command -v` against the invoking shell's PATH, in its original order -- the first
# hit is the copy the user actually runs. Not `command -v`, which sees the PATH that
# `brew shellenv` rewrote.
resolve_in_original_path() {
  local name="$1" dir
  local IFS=:
  for dir in $ESETUP_ORIGINAL_PATH; do
    [[ -n "$dir" ]] || continue
    if [[ -x "${dir}/${name}" ]] && [[ ! -d "${dir}/${name}" ]]; then
      printf '%s\n' "${dir}/${name}"
      return 0
    fi
  done
  return 1
}

# --- The Plan ---------------------------------------------------------------
# One `brew update` (the internet), one `brew outdated` (the machine, already
# joined against the internet). We never compare two version strings ourselves.
# No stale-metadata fallback: a Plan built from yesterday's index looks
# authoritative and is wrong. Abort (exit 2) instead. See docs/adr/0001.
build_plan() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required to build the upgrade Plan. Install jq and re-run."
    exit 2
  fi

  log_info "Refreshing Homebrew metadata (brew update)..."
  if ! brew update; then
    log_error "brew update failed. Refusing to build a Plan from stale metadata."
    exit 2
  fi

  local raw
  if ! raw="$(brew outdated --json=v2 --greedy 2>/dev/null)"; then
    log_error "brew outdated failed; cannot build a Plan."
    exit 2
  fi

  PLAN="$(printf '%s' "$raw" | jq -r '
    ((.formulae // []) | map(. + {kind: "formula"}))
      + ((.casks // []) | map(. + {kind: "cask"}))
    | .[]
    | [ .name,
        .kind,
        ((.installed_versions // []) | join(",")),
        (.current_version // ""),
        (if .pinned then "pinned" else "-" end) ]
    | @tsv')"

  local n
  n="$(printf '%s' "$PLAN" | grep -c . || true)"
  log_info "Plan built: ${n:-0} artifact(s) with a version diff."
}

# plan_row NAME KIND -> prints the TSV record, or returns 1 if not outdated.
plan_row() {
  [[ -n "$PLAN" ]] || return 1
  printf '%s\n' "$PLAN" | awk -F'\t' -v n="$1" -v k="$2" \
    '$1 == n && $2 == k { print; f = 1; exit } END { if (!f) exit 1 }'
}

plan_field() { plan_row "$1" "$2" | cut -f"$3"; }
plan_pinned() { [[ "$(plan_field "$1" "$2" 5)" == "pinned" ]]; }
plan_diff() { printf '%s -> %s' "$(plan_field "$1" "$2" 3)" "$(plan_field "$1" "$2" 4)"; }

# --- Foreign / Shadowed / Unowned App / Running app -------------------------
# Foreign: brew does NOT own it, yet the name is on PATH. Detected *before*
# installing, by name — brew cannot help us here (for an uninstalled formula
# `brew ls` errors and the formula JSON carries no binary key). Every formula
# where a Foreign copy is realistic has formula-name == binary-name; the
# post-install Shadowed check catches the rest.
is_foreign_formula() {
  local name="$1" p
  brew_owns_formula "$name" && return 1
  p="$(resolve_in_original_path "$name" || true)"
  [[ -n "$p" ]] || return 1
  path_inside_brew "$p" && return 1
  FOREIGN_PATH="$p"
}

# Shadowed: brew DOES own it, but the binary you run is somewhere else. Detected
# *after* acting, from brew's own artifact list — so gnu-sed→gsed and
# claude-code→claude are both covered with no hand-maintained map.
formula_bin_names() { brew ls --verbose "$1" 2>/dev/null | sed -n 's|.*/bin/\([^/]*\)$|\1|p'; }

# Records a Manual entry per shadowed binary. Returns 0 if the Artifact is shadowed.
# Callers use the verdict to skip converging a copy the user never executes.
# Safe to call twice: record_manual dedupes.
check_shadowed_formula() {
  local formula="$1" bin resolved found=0
  while IFS= read -r bin; do
    [[ -n "$bin" ]] || continue
    resolved="$(resolve_in_original_path "$bin" || true)"
    [[ -n "$resolved" ]] || continue
    path_inside_brew "$resolved" && continue
    record_manual "$formula" "shadowed — '${bin}' resolves to ${resolved}, outside ${BREW_PREFIX_PATH}"
    found=1
  done < <(formula_bin_names "$formula")
  [[ "$found" -eq 1 ]]
}

cask_json() { brew info --json=v2 --cask "$1" 2>/dev/null; }
cask_app_names() { cask_json "$1" | jq -r '.casks[0].artifacts[]?.app[]? // empty' 2>/dev/null || true; }
cask_bin_targets() {
  cask_json "$1" | jq -r '.casks[0].artifacts[]? | select(.binary) | .target // empty' 2>/dev/null || true
}

check_shadowed_cask() {
  local cask="$1" target bin resolved found=0
  command -v jq &>/dev/null || return 1
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    bin="$(basename "$target")"
    resolved="$(resolve_in_original_path "$bin" || true)"
    [[ -n "$resolved" ]] || continue
    [[ "$resolved" == "$target" ]] && continue
    record_manual "$cask" "shadowed — '${bin}' resolves to ${resolved}, not ${target}"
    found=1
  done < <(cask_bin_targets "$cask")
  [[ "$found" -eq 1 ]]
}

# Unowned App: the cask flavour of Foreign. Pre-empts brew's "already an App at" failure.
cask_unowned_app() {
  local cask="$1" app
  command -v jq &>/dev/null || return 1
  brew_owns_cask "$cask" && return 1
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ -d "/Applications/${app}" ]]; then
      UNOWNED_APP="/Applications/${app}"
      return 0
    fi
  done < <(cask_app_names "$cask")
  return 1
}

# Neither raycast nor orbstack declares a quit/uninstall stanza, so `brew upgrade
# --cask` would swap the bundle out from under a live process. Decline instead.
cask_app_running() {
  local cask="$1" app
  command -v jq &>/dev/null || return 1
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if pgrep -qf "/Applications/${app}/Contents/MacOS/"; then
      RUNNING_APP="$app"
      return 0
    fi
  done < <(cask_app_names "$cask")
  return 1
}

print_action_summary() {
  if [[ "${#MANUAL_ACTIONS[@]}" -gt 0 ]]; then
    echo
    echo "=============================="
    echo "Needs your attention (left unchanged)"
    echo "=============================="
    local item
    for item in "${MANUAL_ACTIONS[@]+"${MANUAL_ACTIONS[@]}"}"; do
      printf '  - %s\n' "$item"
    done
  fi

  if [[ "${#FAILED_ACTIONS[@]}" -gt 0 ]]; then
    echo
    echo "=============================="
    echo "Failed"
    echo "=============================="
    local fail_item
    for fail_item in "${FAILED_ACTIONS[@]+"${FAILED_ACTIONS[@]}"}"; do
      printf '  - %s\n' "$fail_item"
    done
  fi
}

brew_install_formula() {
  local formula="$1"
  local desc="${2:-$formula}"
  _formula_step "$formula" "$desc"
  # Post-check: catches the freshly-installed case, and the up-to-date case where
  # _formula_step never asked. `|| true` — a clean verdict is a nonzero return.
  if brew_owns_formula "$formula"; then
    check_shadowed_formula "$formula" || true
  fi
  return 0
}

_formula_step() {
  local formula="$1"
  local desc="$2"

  if ! brew_owns_formula "$formula"; then
    if is_foreign_formula "$formula"; then
      log_warn "${desc}: '${formula}' already on PATH at ${FOREIGN_PATH}, not Homebrew-owned."
      record_manual "$formula" "foreign — ${FOREIGN_PATH} is on PATH but not Homebrew-owned; installing would create a second copy"
      return 0
    fi
    if brew install "$formula"; then
      OWNED_FORMULAE="${OWNED_FORMULAE}
${formula}"
      record_caveat formula "$formula"
    else
      record_failed "$formula" "brew install failed"
    fi
    return 0
  fi

  case "$IF_INSTALLED" in
    skip)
      log_info "Skipping already-installed formula: $formula"
      return 0
      ;;
    upgrade)
      if ! plan_row "$formula" formula &>/dev/null; then
        log_info "Up to date: ${formula}"
        return 0
      fi
      if plan_pinned "$formula" formula; then
        record_manual "$formula" "pinned in Homebrew; not upgrading"
        return 0
      fi
      # Brew already owns it, so `brew ls` works and we can ask *before* acting.
      # Upgrading a copy the user never executes is wasted work, and it would make
      # the Manual report a lie: "will not converge" must mean we did not converge.
      if check_shadowed_formula "$formula"; then
        log_warn "${desc}: not upgrading — you run a copy outside ${BREW_PREFIX_PATH}."
        return 0
      fi
      log_info "Upgrading formula: ${formula} ($(plan_diff "$formula" formula))"
      if brew upgrade "$formula"; then
        record_caveat formula "$formula"
      else
        record_failed "$formula" "brew upgrade failed"
      fi
      return 0
      ;;
    prompt|*)
      if ! prompt_yes_no "${desc} already present. Reinstall or proceed with setup step anyway?" n; then
        log_warn "Skipping formula: $formula"
        return 0
      fi
      if brew install "$formula"; then
        record_caveat formula "$formula"
      else
        record_failed "$formula" "brew install failed"
      fi
      return 0
      ;;
  esac
}

brew_install_cask() {
  local cask="$1"
  local desc="${2:-$cask}"
  _cask_step "$cask" "$desc"
  if brew_owns_cask "$cask"; then
    check_shadowed_cask "$cask" || true
  fi
  return 0
}

_cask_step() {
  local cask="$1"
  local desc="$2"

  if ! brew_owns_cask "$cask"; then
    if cask_unowned_app "$cask"; then
      log_warn "${desc}: ${UNOWNED_APP} exists but Homebrew does not own it."
      record_manual "$cask" "unowned app — ${UNOWNED_APP} exists but is not Homebrew-owned; remove it, then re-run"
      return 0
    fi
    _cask_install "$cask" "$desc"
    return 0
  fi

  case "$IF_INSTALLED" in
    skip)
      log_info "Skipping already-installed cask: $cask"
      return 0
      ;;
    upgrade)
      if ! plan_row "$cask" cask &>/dev/null; then
        log_info "Up to date: ${cask}"
        return 0
      fi
      if plan_pinned "$cask" cask; then
        record_manual "$cask" "pinned in Homebrew; not upgrading"
        return 0
      fi
      if check_shadowed_cask "$cask"; then
        log_warn "${desc}: not upgrading — you run a copy outside Homebrew's target."
        return 0
      fi
      if cask_app_running "$cask"; then
        log_warn "${desc}: ${RUNNING_APP} is running; not swapping the bundle underneath it."
        record_manual "$cask" "app running — quit ${RUNNING_APP} and re-run ($(plan_diff "$cask" cask))"
        return 0
      fi
      log_info "Upgrading cask: ${cask} ($(plan_diff "$cask" cask))"
      if brew upgrade --cask "$cask"; then
        record_caveat cask "$cask"
      else
        record_failed "$cask" "brew upgrade --cask failed"
      fi
      return 0
      ;;
    prompt|*)
      if ! prompt_yes_no "${desc} already present. Reinstall or proceed with setup step anyway?" n; then
        log_warn "Skipping cask: $cask"
        return 0
      fi
      _cask_install "$cask" "$desc"
      return 0
      ;;
  esac
}

_cask_install() {
  local cask="$1"
  local desc="$2"
  local output=""
  if output="$(brew install --cask "$cask" 2>&1)"; then
    [[ -n "$output" ]] && printf '%s\n' "$output"
    OWNED_CASKS="${OWNED_CASKS}
${cask}"
    record_caveat cask "$cask"
    return 0
  fi

  printf '%s\n' "$output" >&2

  # cask_unowned_app pre-empts this in the common case; this is the fallback for
  # a bundle that appeared after ownership was built, or one brew reports oddly.
  if [[ "$output" == *"already an App at '"* ]]; then
    local app_path
    app_path="$(printf '%s\n' "$output" | sed -n "s/.*already an App at '\\([^']*\\)'.*/\\1/p" | head -n 1)"
    if [[ -n "$app_path" ]]; then
      if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        record_manual "$cask" "unowned app — ${app_path} exists but is not Homebrew-owned; remove it, then re-run"
        return 0
      fi
      if prompt_yes_no "${app_path} already exists. Remove it and retry installing ${cask}?" n; then
        rm -rf "$app_path"
        if brew install --cask "$cask"; then
          OWNED_CASKS="${OWNED_CASKS}
${cask}"
          record_caveat cask "$cask"
        else
          record_failed "$cask" "brew install --cask failed after removing ${app_path}"
        fi
        return 0
      fi
      log_warn "Skipped cask due to existing app: ${cask}"
      record_manual "$cask" "unowned app — ${app_path} kept; cask not installed"
      return 0
    fi
  fi

  # Convergence is per-Artifact independent: one broken cask must not stop the rest.
  log_error "Cask install failed for ${cask}."
  record_failed "$cask" "brew install --cask failed"
  return 0
}

ensure_homebrew() {
  ARCH="$(uname -m)"
  if [[ "$ARCH" == "arm64" ]]; then
    BREW_PREFIX="/opt/homebrew"
  else
    BREW_PREFIX="/usr/local"
  fi
  export BREW_PREFIX

  if [[ -x "${BREW_PREFIX}/bin/brew" ]]; then
    eval "$("${BREW_PREFIX}/bin/brew" shellenv)"
    return 0
  fi

  if ! prompt_yes_no "Homebrew not found at ${BREW_PREFIX}. Install Homebrew?" y; then
    log_error "Homebrew is required."
    exit 2   # cannot start
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$("${BREW_PREFIX}/bin/brew" shellenv)"
}

app_in_applications() {
  local name="$1"
  [[ -d "/Applications/${name}.app" ]]
}

brew_cask_installed() {
  command -v brew &>/dev/null && brew_owns_cask "$1"
}

docker_desktop_present() {
  app_in_applications "Docker" \
    || brew_cask_installed docker \
    || brew_cask_installed docker-desktop
}

orbstack_present() {
  app_in_applications "OrbStack" || brew_cask_installed orbstack
}

rancher_desktop_present() {
  app_in_applications "Rancher Desktop" \
    || brew_cask_installed rancher-desktop \
    || brew_cask_installed rancher
}

colima_present() {
  brew_owns_formula colima || command -v colima &>/dev/null
}

# Unattended, every `read` here hits EOF and falls to its default -- and two of those
# defaults call `exit 1`. Detection is non-interactive; only the resolution is. So under
# --upgrade we detect, pick the conservative default, and report instead of asking.
preflight_noninteractive() {
  log_info "Preflight (non-interactive): detecting conflicts, choosing safe defaults."

  if [[ -x /opt/homebrew/bin/brew ]] && [[ -x /usr/local/bin/brew ]]; then
    record_manual "homebrew" "two installations (/opt/homebrew and /usr/local); using ${BREW_PREFIX}"
  fi

  if [[ -d "${TARGET_DOTFILES}" ]] && [[ ! -d "${TARGET_DOTFILES}/.git" ]]; then
    local count
    count="$(find "${TARGET_DOTFILES}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${count:-0}" -gt 0 ]]; then
      record_manual "dotfiles" "${TARGET_DOTFILES} has content but no .git; run setup.sh without --upgrade to review the sync"
    fi
  fi

  if docker_desktop_present; then
    SKIP_ORBSTACK=1
    if ! orbstack_present; then
      record_manual "orbstack" "not installed and Docker Desktop is present; declining to add a second Docker stack"
    else
      record_manual "orbstack" "both Docker Desktop and OrbStack are installed; only one should own the docker socket"
    fi
  fi

  rancher_desktop_present && record_manual "rancher-desktop" "installed; can overlap with Docker Desktop / OrbStack"
  colima_present && record_manual "colima" "present; can conflict with other Docker endpoints"

  if command -v docker &>/dev/null && ! docker info &>/dev/null; then
    record_manual "docker" "CLI exists but 'docker info' failed (daemon down or context broken)"
  fi

  return 0
}

preflight_environment() {
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    preflight_noninteractive
    return 0
  fi

  log_info "Preflight: checking for common conflicts (Docker, OrbStack, dotfiles, Homebrew)"

  if [[ -x /opt/homebrew/bin/brew ]] && [[ -x /usr/local/bin/brew ]]; then
    log_warn "Two Homebrew installations detected (/opt/homebrew and /usr/local)."
    log_warn "This script uses BREW_PREFIX=${BREW_PREFIX} after shellenv."
    if ! prompt_yes_no "Continue using the active brew from shellenv (see: brew --prefix)?" y; then
      exit 1
    fi
  fi

  if [[ -e "${TARGET_DOTFILES}" ]] && [[ ! -d "${TARGET_DOTFILES}/.git" ]]; then
    log_warn "${TARGET_DOTFILES} exists but is not the dotfiles git clone; setup_dotfiles will leave it alone."
  fi

  if docker_desktop_present && orbstack_present; then
    log_warn "Both Docker Desktop and OrbStack appear to be installed."
    log_warn "Only one Docker stack should own the docker CLI / socket; conflicts are common."
    if ! prompt_yes_no "Continue setup anyway? (Consider removing or quitting one.)" n; then
      exit 1
    fi
  elif docker_desktop_present && ! orbstack_present; then
    log_warn "Docker Desktop is installed. OrbStack also provides Docker and typically should not run alongside it."
    echo "  1) Skip installing OrbStack this run (recommended if you keep Docker Desktop)"
    echo "  2) Install OrbStack anyway (quit Docker Desktop; plan to use one stack only)"
    echo "  3) Abort setup"
    read -r -p "Choose [1-3, default 1]: " orb_choice || true
    orb_choice="${orb_choice:-1}"
    case "$orb_choice" in
      1) SKIP_ORBSTACK=1 ;;
      2) SKIP_ORBSTACK=0 ;;
      3) log_info "Aborted."; exit 1 ;;
      *) SKIP_ORBSTACK=1 ;;
    esac
  fi

  if rancher_desktop_present; then
    log_warn "Rancher Desktop is installed (Kubernetes/Docker). It can overlap with Docker Desktop or OrbStack."
    if ! prompt_yes_no "Continue setup?" y; then
      exit 1
    fi
  fi

  if colima_present; then
    log_warn "Colima is present (container runtime). It can conflict with other Docker endpoints if multiple are active."
    if ! prompt_yes_no "Continue setup?" y; then
      exit 1
    fi
  fi

  if command -v docker &>/dev/null; then
    if docker info &>/dev/null; then
      log_info "docker CLI responds (docker info OK)."
    else
      log_warn "docker CLI exists but 'docker info' failed (daemon not running or context broken)."
      if ! prompt_yes_no "Continue setup anyway?" y; then
        exit 1
      fi
    fi
  fi
}

# Clone (or fast-forward) the standalone dotfiles repo, run its self-installer, and apply
# the non-stowed artifact areas. The dotfiles now live in their own repo (kernvex/dotfiles)
# that stows itself with `--no-folding` — esetup no longer rsyncs, git-inits, or stows.
# See docs/adr/0004.
DOTFILES_REPO="${DOTFILES_REPO:-git@github.com:kernvex/dotfiles.git}"

# Classify the host so the skills-only path can run on macOS, native Linux, and
# WSL. WSL is a Linux kernel that reports "microsoft"/"WSL" in /proc/version (or
# sets $WSL_DISTRO_NAME); we treat it as its own kind for messaging only — the
# skills installer itself is pure git + symlinks and behaves identically.
detect_os() {
  case "$(uname -s)" in
    Darwin) OS_KIND="macos" ;;
    Linux)
      if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
        OS_KIND="wsl"
      else
        OS_KIND="linux"
      fi
      ;;
    *) OS_KIND="unknown" ;;
  esac
}

# --claude-skills fast path. Cross-platform (macOS / Linux / WSL): sets up ONLY the
# Claude skills, for machines that already have Claude installed: the fork's
# ~/.claude/skills symlinks, the vendored third-party copies (git + awk + perl), and
# the opt-in agent-reach CLI via uv. Deliberately does NOT touch Homebrew, dotfiles,
# or anything macOS-specific. We only sanity-check that git is present and that
# `claude` is on PATH (a warning, not a hard requirement).
run_claude_skills_only() {
  detect_os
  log_info "Claude skills setup (--claude-skills) — detected host: ${OS_KIND}."

  if ! command -v git &>/dev/null; then
    log_error "git is required to set up Claude skills. Install git and re-run."
    exit 2   # cannot start
  fi

  if command -v claude &>/dev/null; then
    log_info "Found claude on PATH: $(command -v claude)."
  else
    log_warn "claude not found on PATH. Skills will still be linked into ~/.claude/skills,"
    log_warn "but they only take effect once Claude Code is installed."
    if ! prompt_yes_no "Continue setting up skills anyway?" y; then
      exit 1
    fi
  fi

  optional_agent_reach || record_failed "agent-reach" "uv tool install failed"
  setup_claude_skills
  log_info "Claude skills done. Linked into ${HOME}/.claude/skills."
}

# --claude fast path. Cross-platform (macOS / Linux / WSL): installs Claude Code (plus the
# desktop app on macOS) and the skills, and nothing else. On macOS it bootstraps Homebrew
# and installs the casks; on Linux/WSL it uses the native CLI installer (no Homebrew).
run_claude_only() {
  detect_os
  log_info "Claude bundle (--claude) — detected host: ${OS_KIND}."
  if [[ "$OS_KIND" == "macos" ]]; then
    ensure_homebrew
    trust_brew_taps
    build_ownership
    if [[ "$IF_INSTALLED" == "upgrade" ]]; then
      command -v jq &>/dev/null || brew install jq || true
      build_plan
    fi
  fi
  install_claude || record_failed "claude-code" "install_claude failed (native installer / cask)"
  optional_agent_reach || record_failed "agent-reach" "uv tool install failed"
  setup_claude_skills || record_failed "claude-skills" "skills sync failed"
  log_info "Claude + skills done."
  print_action_summary
  # Same exit contract as main(): Failed is transient and must be loud.
  if [[ "${#FAILED_ACTIONS[@]}" -gt 0 ]]; then
    log_error "${#FAILED_ACTIONS[@]} artifact(s) failed to converge."
    return 1
  fi
  return 0
}

# Homebrew 4.x prints a noisy "taps are not trusted" banner on every operation unless
# third-party taps are explicitly trusted. Trust the specific formulae/casks we rely on
# (preferred over whole-tap), falling back to whole-tap for taps with no single target.
# Idempotent; only trusts taps actually present, and no-ops if `brew trust` is unavailable.
trust_brew_taps() {
  command -v brew &>/dev/null || return 0
  brew commands 2>/dev/null | grep -qx trust || { log_info "brew trust unavailable; skipping tap trust."; return 0; }
  local tapped entry tap rest
  tapped="$(brew tap 2>/dev/null)"
  # "<tap>|<brew trust args>"  — specific formula/cask where there's one target, else --tap.
  local specs=(
    "oven-sh/bun|--formula oven-sh/bun/bun"
    "upcloudltd/tap|--formula upcloudltd/tap/upcloud-cli"
    "glinford/tap|--cask glinford/tap/dns-easy-switcher"
    "jesseduffield/lazygit|--tap jesseduffield/lazygit"
    "asmvik/formulae|--tap asmvik/formulae"
  )
  for entry in "${specs[@]}"; do
    tap="${entry%%|*}"; rest="${entry#*|}"
    printf '%s\n' "$tapped" | grep -qx "$tap" || continue
    # shellcheck disable=SC2086
    if brew trust $rest &>/dev/null; then
      log_info "Trusted brew tap entry: ${rest}"
    else
      log_warn "Could not trust brew tap entry: ${rest}"
    fi
  done
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --skip-preflight) SKIP_PREFLIGHT=1 ;;
      --claude) CLAUDE_ONLY=1 ;;
      --claude-skills) CLAUDE_SKILLS_ONLY=1 ;;
      # --skip-installed-brew / --upgrade-installed-brew: pre-Plan names, kept as
      # aliases. The scope is no longer brew-only (Rust converges too).
      --skip-installed|--skip-installed-brew)
        if [[ "$IF_INSTALLED" == "upgrade" ]]; then
          log_error "Cannot use --skip-installed with --upgrade."
          exit 2
        fi
        IF_INSTALLED=skip
        ;;
      --upgrade|--upgrade-installed-brew)
        if [[ "$IF_INSTALLED" == "skip" ]]; then
          log_error "Cannot use --upgrade with --skip-installed."
          exit 2
        fi
        IF_INSTALLED=upgrade
        NONINTERACTIVE=1
        ;;
      -h|--help)
        echo "Usage: $0 [--claude] [--claude-skills] [--skip-preflight] [--skip-installed | --upgrade]"
        echo "  --claude            Cross-platform (macOS/Linux/WSL): install Claude Code (+ desktop app on macOS) + skills only"
        echo "  --claude-skills     Cross-platform (macOS/Linux/WSL): set up ONLY the Claude skills, skip everything else"
        echo "  --skip-preflight    Skip conflict / environment checks (CI or advanced users)"
        echo "  --skip-installed    Skip artifacts that are already Homebrew-owned (no per-package prompts)"
        echo "  --upgrade           Non-interactive: install what's missing, converge what's installed,"
        echo "                      and report anything that needs a human. Requires network."
        echo
        echo "Exit codes: 0 = converged (some artifacts may need attention), 1 = an artifact failed,"
        echo "            2 = the run could not start (no brew/jq, brew update failed, bad flags)."
        echo "Aliases: --skip-installed-brew, --upgrade-installed-brew (pre-Plan names)."
        echo "Env: TARGET_DOTFILES (default: \$HOME/kernvex/dotfiles)"
        echo "     ESETUP_DOTNET_FLAVOR=cask|formula  (unset = ask; 'cask' is the MAUI-capable one)"
        exit 0
        ;;
      *)
        # Without this, a typo'd flag (e.g. --upgade) was silently ignored, so an
        # intended unattended --upgrade ran as a fully interactive setup.
        log_error "Unknown flag: $arg  (see: $0 --help)"
        exit 2
        ;;
    esac
  done

  # --claude-skills: cross-platform skills-only path. Runs BEFORE ensure_homebrew so it
  # works on Linux and WSL, where Homebrew is absent and none of it should be triggered.
  if [[ "$CLAUDE_SKILLS_ONLY" -eq 1 ]]; then
    run_claude_skills_only
    return 0
  fi

  # --claude: Claude Code (+ desktop app on macOS) + skills, nothing else. Also runs
  # BEFORE ensure_homebrew so Linux/WSL use the native CLI installer; the macOS branch
  # bootstraps Homebrew itself inside run_claude_only.
  if [[ "$CLAUDE_ONLY" -eq 1 ]]; then
    run_claude_only
    return 0
  fi

  log_info "Starting macOS setup (esetup)"
  ensure_homebrew
  trust_brew_taps   # silence the Homebrew tap-trust banner before any brew install

  # Ownership on every run: cheap, offline, and Foreign/Shadowed matter in all modes.
  build_ownership

  # The Plan must come AFTER trust_brew_taps, or packages from untrusted third-party
  # taps (bun, from oven-sh/bun) can be missing from the diff and silently look
  # up-to-date. It comes BEFORE preflight so a network failure costs nothing.
  if [[ "$IF_INSTALLED" == "upgrade" ]]; then
    # build_plan needs jq, but jq isn't installed until the formulas loop below —
    # a chicken-and-egg trap for --upgrade on a fresh machine. Bootstrap it here.
    command -v jq &>/dev/null || brew install jq || true
    build_plan
  fi

  if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
    preflight_environment
  else
    log_warn "Preflight skipped (--skip-preflight)."
  fi

  # Install fish before other formulas so $SHELL can point at fish for all later brew installs
  # (Homebrew uses $SHELL for completion hints and caveat text).
  brew_install_formula fish "fish"
  export_shell_for_homebrew_fish

  # Early, opt-in Source Build (default no). Placed here so a user who only wants
  # VoiceInk can answer and bail before the bulk of the install, while cmake still
  # inherits fish completions from the SHELL export just above.
  optional_voiceink

  local formulas=(
    eza zoxide starship ripgrep bat fd gnu-sed atuin lazygit gh jq stow tmux fzf fnm neovim go tree-sitter-cli flamegraph
    # Keg-only, and pinned to 5.4 on purpose: it exists to run the dotfiles'
    # window-slot resolver tests on the same Lua that Hammerspoon ships. Plain
    # `lua` is 5.5 and `luajit` is 5.1-compatible, so either would test a
    # different language from the one the code actually runs on.
    lua@5.4
    # Media pipeline for the /watch skill (skills/6eniu5/watch): yt-dlp fetches
    # captions/audio, ffmpeg cuts frames, uv installs the mlx-whisper ASR tool
    # (see modules/watch-media.sh for that non-Artifact step).
    yt-dlp ffmpeg uv
  )
  for f in "${formulas[@]}"; do
    brew_install_formula "$f" "$f"
  done

  # bun needs its own arm only because it may come from core or from oven-sh/bun.
  # Ownership is still the predicate -- the old `command -v bun` guard meant a
  # curl-installed bun made every brew upgrade fail into a warning and do nothing.
  if brew_owns_formula bun; then
    case "$IF_INSTALLED" in
      skip)
        log_info "Skipping already-installed formula: bun"
        ;;
      upgrade)
        if ! plan_row bun formula &>/dev/null; then
          log_info "Up to date: bun"
        elif plan_pinned bun formula; then
          record_manual bun "pinned in Homebrew; not upgrading"
        elif check_shadowed_formula bun; then
          log_warn "bun: not upgrading — you run a copy outside ${BREW_PREFIX_PATH}."
        else
          log_info "Upgrading formula: bun ($(plan_diff bun formula))"
          if brew upgrade bun 2>/dev/null || brew upgrade oven-sh/bun/bun; then
            record_caveat formula bun
          else
            record_failed bun "brew upgrade failed"
          fi
        fi
        ;;
      prompt|*)
        if prompt_yes_no "bun already present. Reinstall or proceed with setup step anyway?" n; then
          if brew install bun 2>/dev/null || brew install oven-sh/bun/bun; then
            record_caveat formula bun
          else
            record_failed bun "brew install failed"
          fi
        fi
        ;;
    esac
    check_shadowed_formula bun || true
  elif is_foreign_formula bun; then
    log_warn "bun already on PATH at ${FOREIGN_PATH}, not Homebrew-owned."
    record_manual bun "foreign — ${FOREIGN_PATH} is on PATH but not Homebrew-owned; installing would create a second copy"
  else
    if brew install bun 2>/dev/null || brew install oven-sh/bun/bun; then
      record_caveat formula bun
      check_shadowed_formula bun || true
    else
      record_failed bun "brew install failed"
    fi
  fi

  brew_install_cask wezterm "WezTerm"
  if [[ "$SKIP_ORBSTACK" -eq 0 ]]; then
    brew_install_cask orbstack "OrbStack"
  else
    log_info "Skipping OrbStack install (preflight choice or conflict resolution)."
  fi

  brew_install_cask raycast "Raycast"
  if brew_owns_cask raycast; then
    disable_spotlight_hotkey
  fi

  speed_up_window_animations

  # Guarded: a curl blip in the native Claude installer must not abort the whole run
  # (the brew path is failure-isolated; this makes the non-brew installers match).
  install_claude || record_failed "claude-code" "install_claude failed (native installer / cask)"

  # The last three are load-bearing for the WezTerm Persian fallback, in that order
  # (see wezterm.lua). A terminal gives every character one cell, so the fallback is
  # chosen by advance width: DejaVu Sans Mono carries Persian at ~cell width, which is
  # what keeps the cursive joins from coming apart. Cascadia covers Arabic too and must
  # stay behind it; Vazirmatn is the coverage backstop. Dropping font-dejavu here does
  # not fail the run -- it silently demotes Persian to the next face that matches.
  local fonts=(
    font-hack-nerd-font font-meslo-lg-nerd-font font-fira-code
    font-jetbrains-mono font-jetbrains-mono-nerd-font
    font-dejavu font-cascadia-code font-vazirmatn
  )
  for fc in "${fonts[@]}"; do
    brew_install_cask "$fc" "$fc"
  done

  # Dotfiles: clone the standalone repo, run its self-installer (stow --no-folding),
  # and apply non-stowed artifacts. Replaces the old rsync + git-init + per-package stow.
  setup_dotfiles

  # Immediately after dotfiles: `apply` writes into ~/.config and depends on stow
  # having already placed ~/.gitconfig with its `[include] local.inc` line.
  setup_identity_routing || true

  run_fnm_default_node || record_failed "node" "fnm default-node setup failed"
  run_rustup_default_toolchain || record_failed "rust" "rustup toolchain setup failed"
  run_mlx_whisper_tool || record_failed "mlx-whisper" "uv tool install failed"

  optional_karabiner_manager || record_failed "karabiner-manager" "karabiner build/config failed"

  optional_obsidian_habit_tracker || record_failed "obsidian-habit-tracker" "vault build/deploy failed"

  optional_obsidian_lingo || record_failed "obsidian-lingo" "vault build/deploy failed"

  # Before the skills step: install-vendor-skills.sh generates the agent-reach skill only
  # when its binary is on PATH, so the CLI has to land first.
  optional_agent_reach || record_failed "agent-reach" "uv tool install failed"

  # Non-Artifact, idempotent (git pull + symlinks + vendored copies): --upgrade runs it.
  if [[ "$NONINTERACTIVE" -eq 1 ]] || prompt_yes_no "Set up Claude Code skills (fork submodule + ~/.claude/skills symlinks)?" y; then
    setup_claude_skills || record_failed "claude-skills" "skills sync failed (git fetch/push)"
  fi

  # No `|| record_failed` on these three, unlike their neighbours: they go through
  # brew_install_cask / brew_install_formula, which record their own Failed entries and
  # return 0 by design (one broken Artifact must not stop the rest). A wrapper here
  # would be unreachable.
  optional_gcloud
  optional_db_tunnel
  optional_dotnet
  optional_dotnet_versioned

  optional_miniconda || record_failed "miniconda" "miniconda install failed"
  optional_sdkman || record_failed "sdkman" "sdkman install failed"

  link_homebrew_completions_for_fish

  # Non-Artifact, idempotent, and last on purpose: it reads what the run actually left on
  # disk (DOTNET_ROOT depends on which dotnet flavour got installed) rather than what was
  # requested, so it must come after every install step. Standalone-runnable by design --
  # re-run it after installing or removing a toolchain by hand. --upgrade runs it too.
  apply_toolchain_env

  print_caveat_summary
  # Non-Artifact, idempotent (ensure_line_in_file): --upgrade applies it.
  if [[ "$NONINTERACTIVE" -eq 1 ]] || prompt_yes_no "Apply known caveat actions now?" n; then
    apply_known_caveat_actions
  fi

  # set_fish_default_shell records a Manual entry rather than chsh-ing unattended.
  if [[ "$NONINTERACTIVE" -eq 1 ]] || prompt_yes_no "Set fish as default shell?" n; then
    set_fish_default_shell
  fi

  log_info "Done. Dotfiles repo: ${TARGET_DOTFILES}"
  log_info "Open a new terminal or: exec fish"

  print_action_summary

  # Manual is a steady state and exits 0 -- `claude-code` will be shadowed next month
  # too, and a report that is red forever is a report nobody reads. Failed is transient.
  if [[ "${#FAILED_ACTIONS[@]}" -gt 0 ]]; then
    log_error "${#FAILED_ACTIONS[@]} artifact(s) failed to converge."
    return 1
  fi
  return 0
}

# Per-tool Modules: sourced (not executed) so they share this process's globals,
# helpers, ownership arrays, and the accumulating Manual list. Enumerated
# explicitly — like the Declared Set, not discovered. main() calls them in order.
MODULES_DIR="${SCRIPT_DIR}/modules"
source "${MODULES_DIR}/dotfiles.sh"
source "${MODULES_DIR}/identity.sh"
source "${MODULES_DIR}/node.sh"
source "${MODULES_DIR}/rust.sh"
source "${MODULES_DIR}/watch-media.sh"
source "${MODULES_DIR}/karabiner.sh"
source "${MODULES_DIR}/voiceink.sh"
source "${MODULES_DIR}/miniconda.sh"
source "${MODULES_DIR}/sdkman.sh"
source "${MODULES_DIR}/gcloud.sh"
source "${MODULES_DIR}/db-tunnel.sh"
source "${MODULES_DIR}/dotnet.sh"
source "${MODULES_DIR}/obsidian.sh"
source "${MODULES_DIR}/macos.sh"
source "${MODULES_DIR}/claude.sh"

main "$@"
