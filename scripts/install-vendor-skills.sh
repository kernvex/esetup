#!/usr/bin/env bash
# install-vendor-skills.sh — generate the third-party skills listed in vendor-skills/MANIFEST
# into ~/.claude/skills, each under a per-repo prefix.
#
# Why generated copies and not symlinks like the fork installer: Claude Code keys a skill on its
# frontmatter `name` (the directory name is only an alias), so a prefix that lives only in the
# symlink's name shows up nowhere, and two skills that both declare `name: prototype` collide
# whatever their directories are called. The copy differs from upstream in exactly four ways,
# all of them mechanical: the `name` line, an optional `disable-model-invocation`, an optional
# description from vendor-skills/overrides/, and backticked references to sibling skills of the
# same repo, which are rewritten to their prefixed names so "hand off to `animate`" still lands.
#
# Every generated directory carries a `.vendor-skill` marker. A real directory without one is
# somebody else's and is refused, never overwritten; a symlink is replaced. The run is otherwise
# idempotent: every entry is regenerated on every run, which is also the update path after a
# submodule bump.
#
# Ordering: install-claude-skills.sh calls this AFTER the fork's symlinks and BEFORE the
# job-skills shadow pass, so a private shadow of a vendored name would still win. Nothing
# shadows one today; the prefixes exist so that nothing has to.
#
# Pure shell plus awk and perl, both present on a stock macOS. BSD-compatible.
set -euo pipefail

MANAGER_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_SKILLS_ROOT="${VENDOR_SKILLS_ROOT:-${MANAGER_REPO}/vendor-skills}"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-${HOME}/.claude/skills}"
MANIFEST="${VENDOR_SKILLS_ROOT}/MANIFEST"
OVERRIDES="${VENDOR_SKILLS_ROOT}/overrides"
MARKER=".vendor-skill"

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  -h|--help) echo "Usage: $0 [--check]"; echo "  Generate vendored skills from ${MANIFEST}; --check only verifies."; exit 0 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 1 ;;
esac

[ -f "$MANIFEST" ] || { echo "error: no manifest at ${MANIFEST}" >&2; exit 1; }

# ---- manifest ---------------------------------------------------------------
# Parallel arrays (bash 3.2 has no associative arrays). One index per manifest line.
repos=(); dirs=(); targets=(); flags=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  # shellcheck disable=SC2086
  set -- $line
  [ $# -ge 3 ] || continue
  repos+=("$1"); dirs+=("$2"); targets+=("$3"); shift 3
  flags+=("$*")
done < "$MANIFEST"

[ "${#repos[@]}" -gt 0 ] || { echo "error: manifest lists no skills" >&2; exit 1; }

flag_value() { # $1 = flags string, $2 = key  -> prints value of key=value, or nothing
  local f
  for f in $1; do
    case "$f" in "$2="*) echo "${f#*=}"; return 0 ;; esac
  done
  return 0
}
has_flag() { # $1 = flags string, $2 = bare flag
  local f
  for f in $1; do [ "$f" = "$2" ] && return 0; done
  return 1
}

frontmatter_name() { # $1 = skill markdown file
  awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm && /^name:/ {sub(/^name:[ \t]*/, ""); print; exit}' "$1"
}

# Does this entry apply on this machine? requires-bin gates a skill that is dead weight
# without its CLI (and whose description would still fire).
entry_applies() { # $1 = index
  local bin
  bin="$(flag_value "${flags[$1]}" requires-bin)"
  [ -z "$bin" ] || command -v "$bin" >/dev/null 2>&1
}

entry_source_file() { # $1 = index -> absolute path of the markdown to read
  local src
  src="$(flag_value "${flags[$1]}" source)"
  echo "${VENDOR_SKILLS_ROOT}/${repos[$1]}/${dirs[$1]}/${src:-SKILL.md}"
}

# ---- --check ------------------------------------------------------------------
if [ "$CHECK" -eq 1 ]; then
  bad=0
  for i in "${!repos[@]}"; do
    entry_applies "$i" || continue
    t="${CLAUDE_SKILLS_DIR}/${targets[$i]}"
    if [ ! -f "${t}/${MARKER}" ] || [ "$(frontmatter_name "${t}/SKILL.md" 2>/dev/null)" != "${targets[$i]}" ]; then
      echo "VENDOR SKILL MISSING OR STALE: ${t}" >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] || { echo "Re-run $0 to regenerate." >&2; exit 1; }
  exit 0
fi

# ---- generate ---------------------------------------------------------------
mkdir -p "$CLAUDE_SKILLS_DIR"
refused=0

for i in "${!repos[@]}"; do
  repo="${repos[$i]}"; name="${targets[$i]}"; fl="${flags[$i]}"
  src_dir="${VENDOR_SKILLS_ROOT}/${repo}/${dirs[$i]}"
  src_md="$(entry_source_file "$i")"
  target="${CLAUDE_SKILLS_DIR}/${name}"

  if [ ! -f "$src_md" ]; then
    echo "  ! ${name}: source missing at ${src_md} (submodule not initialised? run: git submodule update --init vendor-skills/${repo})" >&2
    refused=1; continue
  fi
  if ! entry_applies "$i"; then
    echo "  (skip ${name}: $(flag_value "$fl" requires-bin) not on PATH)"
    # A copy left behind by an earlier run, when the binary was present, would now be a
    # trap: a skill promising a CLI that is gone. Remove our own copy only.
    if [ -f "${target}/${MARKER}" ]; then rm -rf "$target"; echo "  removed ${name} (binary gone)"; fi
    continue
  fi

  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ] && [ ! -f "${target}/${MARKER}" ]; then
    echo "  ! refuse ${name}: ${target} exists and is not ours (no ${MARKER}). Move it aside and re-run." >&2
    refused=1; continue
  fi
  rm -rf "$target"
  mkdir -p "$target"
  cp -R "${src_dir}/." "$target/"

  # The copy keeps one SKILL.md: the chosen source, transformed. Other locale files go.
  src_base="$(basename "$src_md")"
  [ "$src_base" = "SKILL.md" ] || rm -f "${target}/${src_base}"

  desc=""
  [ -f "${OVERRIDES}/${name}.description" ] && desc="$(tr '\n' ' ' < "${OVERRIDES}/${name}.description" | sed 's/[[:space:]]*$//')"
  user_only=0; has_flag "$fl" user-only && user_only=1

  # Frontmatter rewrite. Only the first `---` block is touched; a folded `description: >`
  # block is replaced whole: its continuation lines are the indented and blank lines that
  # follow, up to the next key (agent-reach separates paragraphs with blank lines).
  awk -v target="$name" -v desc="$desc" -v userOnly="$user_only" '
    NR==1 && /^---$/ { fm=1; print; next }
    fm==1 && /^---$/ { fm=2; if (userOnly && !sawDmi) print "disable-model-invocation: true"; print; next }
    fm==1 {
      if (skipping && (/^[ \t]/ || /^[ \t]*$/)) next
      skipping=0
      if (/^name:/) { print "name: " target; next }
      if (/^disable-model-invocation:/) { sawDmi=1; if (userOnly) { print "disable-model-invocation: true"; next } }
      if (desc != "" && /^description:/) { print "description: " desc; skipping=1; next }
      print; next
    }
    { print }
  ' "$src_md" > "${target}/SKILL.md"

  # Sibling references: every entry of the same repo, by its upstream frontmatter name and by
  # its folder name. Backticked occurrences are always rewritten. Bare occurrences are rewritten
  # only for names containing a hyphen (`review-animations`, `pick-ui-library`): those cannot be
  # ordinary prose, whereas `animate` and `prototype` are English words the body uses freely.
  # Descriptions name their siblings bare, so without this rule the `/` menu would still say
  # "use review-animations" after the skill became emil-review-animations.
  for j in "${!repos[@]}"; do
    [ "${repos[$j]}" = "$repo" ] || continue
    sib_md="$(entry_source_file "$j")"
    [ -f "$sib_md" ] || continue
    sib_target="${targets[$j]}"
    for orig in "$(frontmatter_name "$sib_md")" "$(basename "${dirs[$j]}")"; do
      [ -n "$orig" ] && [ "$orig" != "$sib_target" ] || continue
      case "$orig" in
        *-*) expr='s/(?<![\w\-\/`])\Q'"$orig"'\E(?![\w\-\/])/'"$sib_target"'/g; s/`\Q'"$orig"'\E`/`'"$sib_target"'`/g' ;;
        *)   expr='s/`\Q'"$orig"'\E`/`'"$sib_target"'`/g' ;;
      esac
      find "$target" -name '*.md' -type f -print0 | xargs -0 perl -pi -e "$expr"
    done
  done

  sha="$(git -C "${VENDOR_SKILLS_ROOT}/${repo}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'source=%s\nrevision=%s\n' "${repo}/${dirs[$i]}" "$sha" > "${target}/${MARKER}"
  echo "  generated ${name} <- ${repo}/${dirs[$i]} (${sha})"
done

[ "$refused" -eq 0 ] || { echo "error: some vendored skills were not generated (see above)." >&2; exit 1; }
