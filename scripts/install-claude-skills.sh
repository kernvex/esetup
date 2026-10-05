#!/usr/bin/env bash
# install-claude-skills.sh — machine-agnostic installer for the personal fork of
# mattpocock/skills (managed as the `skills` submodule of this esetup repo).
#
#   First run : init the submodule, symlink curated buckets into ~/.claude/skills.
#   Re-run    : sync the fork from upstream (report new skills), push, then re-link.
#
# Pure shell + symlinks — BSD-compatible (no `readlink -f`, no GNU-only flags).
# Prerequisites: git, gh (only `git` is needed once the submodule exists).
set -euo pipefail

# ---- config ----------------------------------------------------------------
MANAGER_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # script lives in scripts/
SUBMODULE_PATH="${MANAGER_REPO}/skills"
PERSONAL_BUCKET="6eniu5"
UPSTREAM_URL="https://github.com/mattpocock/skills.git"
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"

# Which buckets to expose. Curated set = upstream's plugin.json (engineering +
# productivity) + misc extras + our personal bucket. Matt's personal/, in-progress/
# and deprecated/ are intentionally excluded. This is the one knob for what lands
# in ~/.claude/skills.
ALLOWED_BUCKETS=(engineering productivity misc "${PERSONAL_BUCKET}")

# ---- flags -----------------------------------------------------------------
usage() {
  echo "Usage: $0 [-h]"
  echo "  Sets up (and on re-run, syncs) the personal Claude skills fork."
}
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1"; usage; exit 1 ;;
  esac
  shift
done

# ---- helpers ---------------------------------------------------------------
ensure_submodule() {
  if [ ! -f "${SUBMODULE_PATH}/README.md" ]; then
    echo "→ Initializing skills submodule…"
    git -C "$MANAGER_REPO" submodule update --init --recursive -- "$SUBMODULE_PATH"
  fi
  git -C "$SUBMODULE_PATH" remote | grep -qx upstream \
    || git -C "$SUBMODULE_PATH" remote add upstream "$UPSTREAM_URL"
}

# "installed" = submodule populated AND at least one of our symlinks resolves into it.
is_installed() {
  [ -f "${SUBMODULE_PATH}/README.md" ] || return 1
  local found=1 link target
  for link in "${CLAUDE_SKILLS_DIR}"/*; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"                 # BSD-safe: we store absolute targets
    case "$target" in "${SUBMODULE_PATH}"/*) found=0; break ;; esac
  done
  return $found
}

# After `submodule update --init` the submodule is at a DETACHED HEAD on the pinned
# SHA with no local `main` branch — so `rev-parse main` / `checkout main` would fail.
# Materialize a local `main` tracking origin/main before syncing.
ensure_main_branch() {
  git -C "$SUBMODULE_PATH" fetch --quiet origin
  if git -C "$SUBMODULE_PATH" show-ref --verify --quiet refs/heads/main; then
    git -C "$SUBMODULE_PATH" checkout --quiet main
  else
    git -C "$SUBMODULE_PATH" checkout --quiet -B main origin/main
  fi
}

link_skills() {
  mkdir -p "$CLAUDE_SKILLS_DIR"
  local bucket bdir skill_md src name target
  for bucket in "${ALLOWED_BUCKETS[@]}"; do
    bdir="${SUBMODULE_PATH}/skills/${bucket}"
    [ -d "$bdir" ] || { echo "  (bucket '${bucket}' not present, skipping)"; continue; }
    for skill_md in "$bdir"/*/SKILL.md; do
      [ -f "$skill_md" ] || continue
      src="$(dirname "$skill_md")"; name="$(basename "$src")"
      target="${CLAUDE_SKILLS_DIR}/${name}"
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        echo "  ! skip (real file/dir exists, not a symlink): ${target}"; continue
      fi
      ln -sfn "$src" "$target"
      echo "  linked ${name} -> ${src}"
    done
  done
}

sync_fork() {
  echo "→ Syncing fork from upstream…"
  ensure_main_branch
  git -C "$SUBMODULE_PATH" fetch --quiet upstream
  local after new
  after="$(git -C "$SUBMODULE_PATH" rev-parse upstream/main)"
  # "Up to date" = upstream/main is already an ancestor of main. This is true both when
  # we're equal AND when we're AHEAD (we have our own bucket commits on top) — an exact
  # SHA-equality check would mis-fire on every run once we've committed our own skills.
  if git -C "$SUBMODULE_PATH" merge-base --is-ancestor "$after" main; then
    echo "  ✓ Already current with upstream (${after:0:7}). No sync needed."
    return 0
  fi
  # Report NEW skills (added SKILL.md files) before merging — keeps you informed.
  echo "  ↪ Upstream advanced to ${after:0:7}. New skills:"
  new="$(git -C "$SUBMODULE_PATH" diff --name-status "main..upstream/main" -- skills \
         | awk '$1=="A" && $2 ~ /SKILL\.md$/ {print "    + " $2}')"
  [ -n "$new" ] && echo "$new" || echo "    (no new skills; other upstream changes only)"
  # Merge (never conflicts — our work lives in its own bucket). Abort cleanly if it does.
  if ! git -C "$SUBMODULE_PATH" merge --no-edit upstream/main; then
    git -C "$SUBMODULE_PATH" merge --abort
    echo "  ✗ Unexpected merge conflict — resolve manually (did an upstream file get edited?)."; exit 1
  fi
  git -C "$SUBMODULE_PATH" push origin main
  echo "  ✓ SYNCED: merged upstream/main; fork now at $(git -C "$SUBMODULE_PATH" rev-parse --short main) and pushed to origin."
  echo "  ↪ Record the new pointer in the manager repo:"
  echo "      git -C \"$MANAGER_REPO\" add skills && git -C \"$MANAGER_REPO\" commit -m 'chore: bump skills submodule'"
}

# ---- main ------------------------------------------------------------------
ensure_submodule
if is_installed; then
  echo "→ Skills already installed on this machine."
  sync_fork                           # subsequent run → sync + report
else
  echo "→ First-time skills install on this machine."
fi
link_skills                           # idempotent; picks up any newly-synced skills
echo "✓ Done. Skills linked into ${CLAUDE_SKILLS_DIR}."

# Third-party skills (vendor-skills/ submodules) are generated copies, prefixed per repo. They
# go in after the fork links and before the job-skills shadows, so ordering stays
# fork, then vendor, then private shadows win. See docs/claude-skills/vendor-skills.md.
bash "${MANAGER_REPO}/scripts/install-vendor-skills.sh"

# job-skills shadows some of the names just linked above, so it MUST run after link_skills.
# Calling it from here rather than leaving it to setup.sh is deliberate: this script is the
# documented way to re-link skills, and running it alone must not leave the shadows reverted.
# A reverted shadow is silent, and its consequence is a skill writing private notes into an
# employer's repository. Exits 0 quietly on a machine with no access to the private repo.
bash "${MANAGER_REPO}/scripts/install-job-skills.sh"
