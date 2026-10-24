#!/usr/bin/env bash
# clone-private-repos.sh — clone the private siblings of this repo, if they are reachable.
#
# These are NOT submodules. This repo is public; a private submodule puts its URL in a public
# .gitmodules and makes `git clone --recursive` fail for everyone without access — on a repo
# published so that others can use it. The submodule's pinned SHA buys little for either of
# these: both are wanted at HEAD, and neither is built against a pinned version of the other.
#
# Absent or unreachable, each is skipped and the script still exits 0. A machine without access
# gets a working esetup with these two features missing, which is the correct outcome — not a
# failed bootstrap.
#
# Idempotent: re-running fast-forwards a clean clone and leaves a dirty one alone.
set -euo pipefail

MANAGER_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# name | url | what it is
#
# These names and URLs are visible in a PUBLIC repo, so a name must never reveal
# a client. "identity" is deliberately generic: it says what the repo does and
# nothing about whose identities it holds.
PRIVATE_REPOS=(
  "job-doc|git@github.com:kernvex/job-doc.git|the job-doc generator and binary"
  "job-skills|git@github.com:kernvex/job-skills.git|Job-aware skills that shadow the upstream ones"
  "identity|git@github.com:kernvex/job-id.git|per-folder identity routing, generated from data"
)

clone_or_update() {
  local name="$1" url="$2" what="$3" dest="${MANAGER_REPO}/$1"

  if [ -d "${dest}/.git" ]; then
    # Never clobber local work. A dirty clone is someone mid-task, not a stale checkout.
    if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
      echo "  · ${name}: local changes present, leaving alone"
    else
      git -C "$dest" pull --quiet --ff-only 2>/dev/null \
        && echo "  ✓ ${name}: up to date" \
        || echo "  · ${name}: could not fast-forward, leaving alone"
    fi
    return 0
  fi

  if git ls-remote --exit-code "$url" >/dev/null 2>&1; then
    git clone --quiet "$url" "$dest"
    echo "  ✓ ${name}: cloned (${what})"
  else
    echo "  · ${name}: no access, skipping (${what} will be unavailable)"
  fi
}

echo "→ Private repos…"
for entry in "${PRIVATE_REPOS[@]}"; do
  IFS='|' read -r name url what <<< "$entry"
  clone_or_update "$name" "$url" "$what"
done
