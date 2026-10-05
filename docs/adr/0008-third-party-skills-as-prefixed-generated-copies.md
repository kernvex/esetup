---
status: accepted
---

# Third-party skills as prefixed, generated copies from vendored submodules

Skills from other people's repos (`emilkowalski/skills`, `leonxlnx/taste-skill`,
`Panniantong/agent-reach`) are wanted beside the fork's, and the set will keep growing. Three
ways in were on the table:

1. **Copy the folders into the fork's personal bucket** (`skills/skills/6eniu5/`), the documented loop
   for own skills. Loses provenance and has no update path; 28 vendored folders would bury the
   handful of skills actually written here.
2. **Submodules inside the fork.** Nests submodules three deep and breaks the one-bucket-of-
   `SKILL.md`-folders shape every linker globs.
3. **Submodules of esetup under `vendor-skills/`, with a manifest-driven generator.** The
   repos arrive the same way `karabiner-manager` and the Obsidian vaults do, as submodules,
   but they are not Generators in the `CONTEXT.md` sense: they are inputs, and the generator is
   esetup's own script. The fork stays "upstream plus one bucket" (Rule B of
   `docs/claude-skills/architecture.md`).

## Decision

Option 3. Two consequences of how Claude Code loads skills shaped the generator:

- **Copies, not symlinks.** A skill is keyed on its frontmatter `name`; the directory is only an
  alias. The per-repo prefix the owner wants (`emil-`, `taste-`) therefore has to be written
  into the file, and so does the fix for `name: prototype` existing both upstream and in Emil's
  repo. The copy is mechanical: `name`, optional `disable-model-invocation`, optional description
  override, and sibling references rewritten to the prefixed names. Everything else is upstream
  byte-for-byte; the directory additionally carries a `.vendor-skill` marker saying which
  revision, and drops the unused locale file when `source=` chose one.
- **An explicit manifest, not a glob.** taste-skill ships superseded variants (v1, a GPT one) and
  four image-generation prompts Claude Code cannot use; agent-reach's skill is a trap without
  its binary. Which skills, under which name, with which invocation mode, is a decision per
  skill, so it is a line per skill with the reasons in the same file.

agent-reach's binary is installed by `uv tool install` from the submodule path, pinned to the
same SHA the skill is generated from, and its description is overridden to stop it claiming
every research request from Matt's `research` skill.

## Consequences

- `install-claude-skills.sh` now runs three passes in a fixed order: fork symlinks, vendored
  copies, job-skills shadows. A vendored name is never one that a shadow has to win against,
  which is what the prefixes buy.
- Updating is a submodule bump plus a re-run; nothing updates behind the owner's back, and
  `git log` on the submodule shows what changed before it lands.
- The generator edits upstream text. The edits are listed in one place
  (`docs/claude-skills/vendor-skills.md`) and are the whole list; anything further becomes a
  fork and belongs in `job-skills` or the personal bucket instead.
