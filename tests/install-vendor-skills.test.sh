#!/usr/bin/env bash
# Exercises scripts/install-vendor-skills.sh against a fixture vendor tree and a throwaway
# skills dir. Run: bash tests/install-vendor-skills.test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO}/scripts/install-vendor-skills.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# ---- fixture ---------------------------------------------------------------
VENDOR="${TMP}/vendor"
DEST="${TMP}/claude-skills"
mkdir -p "${VENDOR}/fake-repo/skills/alpha" "${VENDOR}/fake-repo/skills/beta" \
         "${VENDOR}/fake-cli/skill/references" "${VENDOR}/overrides" "$DEST"

cat > "${VENDOR}/fake-repo/skills/alpha/SKILL.md" <<'MD'
---
name: alpha
description: >
  First line of a folded description.
  Second line, mentions `beta` and should survive untouched. For reviews use beta-name instead.
---

# Alpha

Hands off to `beta-name` when done, and never to `beta` the folder. Code: `Animated.View`.
Bare hyphenated beta-name is rewritten; beta-name-extended and skills/beta-name/x are not; beta alone is prose.
MD
cat > "${VENDOR}/fake-repo/skills/beta/SKILL.md" <<'MD'
---
name: beta-name
description: Single-line description.
---

# Beta

Pairs with `alpha`.
MD
cat > "${VENDOR}/fake-repo/skills/beta/EXTRA.md" <<'MD'
Sibling file also points at `alpha`.
MD
cat > "${VENDOR}/fake-cli/skill/SKILL.md" <<'MD'
---
name: fake-cli
description: Chinese description.
metadata:
  homepage: https://example.invalid
---
中文 body
MD
cat > "${VENDOR}/fake-cli/skill/SKILL_en.md" <<'MD'
---
name: fake-cli
description: >
  MUST USE for everything.

  Really everything, after a blank line inside the folded block.
metadata:
  homepage: https://example.invalid
---
English body. See [refs](references/one.md).
MD
echo "ref one" > "${VENDOR}/fake-cli/skill/references/one.md"
echo "Only for named platforms." > "${VENDOR}/overrides/fake-cli.description"

cat > "${VENDOR}/MANIFEST" <<'M'
# comment line
fake-repo  skills/alpha  pre-alpha
fake-repo  skills/beta   pre-beta-name  user-only

fake-cli   skill         fake-cli  source=SKILL_en.md  requires-bin=fake-cli-bin
M

run() { VENDOR_SKILLS_ROOT="$VENDOR" CLAUDE_SKILLS_DIR="$DEST" bash "$SCRIPT" "$@"; }

# ---- 1. generation, renaming, sibling rewrite, user-only ---------------------
run >/dev/null
[ -d "${DEST}/pre-alpha" ] || fail "pre-alpha not generated"
[ ! -L "${DEST}/pre-alpha" ] || fail "pre-alpha must be a real directory, not a symlink"
grep -q '^name: pre-alpha$' "${DEST}/pre-alpha/SKILL.md" || fail "alpha name not rewritten"
grep -q 'First line of a folded description' "${DEST}/pre-alpha/SKILL.md" || fail "alpha description lost"
grep -q 'Hands off to `pre-beta-name` when done' "${DEST}/pre-alpha/SKILL.md" || fail "frontmatter-name sibling ref not rewritten"
grep -q 'never to `pre-beta-name` the folder' "${DEST}/pre-alpha/SKILL.md" || fail "folder-name sibling ref not rewritten"
grep -q '`Animated.View`' "${DEST}/pre-alpha/SKILL.md" || fail "unrelated backticks were touched"
grep -q 'For reviews use pre-beta-name instead' "${DEST}/pre-alpha/SKILL.md" || fail "bare hyphenated sibling name in description not rewritten"
grep -q 'Bare hyphenated pre-beta-name is rewritten; beta-name-extended and skills/beta-name/x are not; beta alone is prose' "${DEST}/pre-alpha/SKILL.md" || fail "bare rewrite over- or under-matched"
grep -q 'disable-model-invocation' "${DEST}/pre-alpha/SKILL.md" && fail "alpha got user-only without the flag"
pass "alpha generated with rewritten name and sibling references"

grep -q '^name: pre-beta-name$' "${DEST}/pre-beta-name/SKILL.md" || fail "beta name not rewritten"
grep -q '^disable-model-invocation: true$' "${DEST}/pre-beta-name/SKILL.md" || fail "user-only flag not applied"
grep -q 'Pairs with `pre-alpha`' "${DEST}/pre-beta-name/SKILL.md" || fail "beta sibling ref not rewritten"
grep -q 'points at `pre-alpha`' "${DEST}/pre-beta-name/EXTRA.md" || fail "sibling .md file not rewritten"
[ -f "${DEST}/pre-beta-name/.vendor-skill" ] || fail "marker file missing"
pass "beta generated as user-only, sibling file rewritten, marker present"

# ---- 2. requires-bin gates generation ---------------------------------------
[ ! -e "${DEST}/fake-cli" ] || fail "fake-cli generated although its binary is absent"
pass "requires-bin skips a skill whose binary is missing"

mkdir -p "${TMP}/bin" && printf '#!/bin/sh\n' > "${TMP}/bin/fake-cli-bin" && chmod +x "${TMP}/bin/fake-cli-bin"
PATH="${TMP}/bin:${PATH}" run >/dev/null
[ -f "${DEST}/fake-cli/SKILL.md" ] || fail "fake-cli not generated with binary present"
grep -q '^English body' "${DEST}/fake-cli/SKILL.md" || fail "source=SKILL_en.md not honoured"
[ ! -e "${DEST}/fake-cli/SKILL_en.md" ] || fail "SKILL_en.md should not be copied alongside"
grep -q '^description: Only for named platforms.$' "${DEST}/fake-cli/SKILL.md" || fail "description override not applied"
grep -q 'MUST USE\|Really everything' "${DEST}/fake-cli/SKILL.md" && fail "old folded description lines survived"
grep -q '^  homepage: https://example.invalid$' "${DEST}/fake-cli/SKILL.md" || fail "metadata block after description was eaten"
[ -f "${DEST}/fake-cli/references/one.md" ] || fail "references/ not copied"
pass "requires-bin, source= and description override"

# ---- 3. idempotent re-run, symlink replaced, foreign real dir refused ---------
PATH="${TMP}/bin:${PATH}" run >/dev/null
grep -q '^name: pre-alpha$' "${DEST}/pre-alpha/SKILL.md" || fail "re-run broke pre-alpha"
pass "re-run is idempotent"

rm -rf "${DEST}/pre-alpha"; ln -s "${VENDOR}/fake-repo/skills/alpha" "${DEST}/pre-alpha"
run >/dev/null
[ ! -L "${DEST}/pre-alpha" ] || fail "stale symlink not replaced"
pass "a symlink at the target is replaced"

rm -rf "${DEST}/pre-alpha"; mkdir "${DEST}/pre-alpha"; echo "mine" > "${DEST}/pre-alpha/SKILL.md"
if run >"${TMP}/out" 2>&1; then fail "a real directory without the marker must make the run fail"; fi
grep -q '^mine$' "${DEST}/pre-alpha/SKILL.md" || fail "foreign directory was clobbered"
grep -q 'pre-alpha' "${TMP}/out" || fail "refusal did not name the skill"
pass "a foreign real directory is refused, not overwritten"

# ---- 4. --check reports what a run would leave stale ------------------------
rm -rf "${DEST}/pre-alpha"
if VENDOR_SKILLS_ROOT="$VENDOR" CLAUDE_SKILLS_DIR="$DEST" bash "$SCRIPT" --check >"${TMP}/chk" 2>&1; then
  fail "--check must fail when a manifest skill is missing"
fi
grep -q 'pre-alpha' "${TMP}/chk" || fail "--check did not name the missing skill"
run >/dev/null
VENDOR_SKILLS_ROOT="$VENDOR" CLAUDE_SKILLS_DIR="$DEST" bash "$SCRIPT" --check || fail "--check failed on a fresh install"
pass "--check"

echo "all tests passed"
