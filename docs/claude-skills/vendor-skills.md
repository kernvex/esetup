# Vendored third-party skills

Skills from other people's repos, installed beside the fork's, each under a prefix that says
where it came from. Three today:

| Submodule | Upstream | Prefix | What it is |
|---|---|---|---|
| `vendor-skills/emil-skills` | [emilkowalski/skills](https://github.com/emilkowalski/skills) | `emil-` | animation and UI craft, 14 skills that hand off to each other |
| `vendor-skills/taste-skill` | [leonxlnx/taste-skill](https://github.com/leonxlnx/taste-skill) | `taste-` | frontend design direction; 7 of its 13 are taken |
| `vendor-skills/agent-reach` | [Panniantong/agent-reach](https://github.com/Panniantong/agent-reach) | none | one skill in front of a Python CLI that fetches X, Reddit, YouTube, ... |

## The two files that matter

- **`vendor-skills/MANIFEST`** lists every skill that gets installed: its submodule, its folder,
  the name it gets locally, and flags (`user-only`, `requires-bin=`, `source=`). A skill not on
  the manifest is not installed, however many the submodule ships. The file's comments say why
  each omission was made.
- **`scripts/install-vendor-skills.sh`** reads the manifest and generates
  `~/.claude/skills/<target name>/`. `install-claude-skills.sh` calls it after the fork's
  symlinks and before the job-skills shadow pass, so the order is fork, vendor, private shadows
  win. `--check` verifies without writing.

## Why copies, not symlinks

Claude Code keys a skill on its frontmatter `name`; the directory name is only an alias. A
prefix that lives only in a symlink's name shows up nowhere, and Emil's `name: prototype` would
collide with Matt's. So each skill is copied and its `name` line rewritten. The text differs
from upstream in exactly four mechanical ways: the `name`, an optional
`disable-model-invocation: true` (the `user-only` flag), an optional description from
`vendor-skills/overrides/<target name>.description`, and references to sibling skills of the
same repo, rewritten to their prefixed names so "hand off to `animate`" still resolves. The
directory also gains the `.vendor-skill` marker and, where `source=` picked a locale file, keeps
only that one as `SKILL.md`.
Backticked sibling names are always rewritten; bare ones only when they contain a hyphen,
because `animate` and `prototype` are also English words the bodies use freely.

Every generated directory carries a `.vendor-skill` marker recording its source and the
submodule revision. A real directory without one is somebody else's and the script refuses to
touch it. See [ADR-0008](../adr/0008-third-party-skills-as-prefixed-generated-copies.md).

## agent-reach

The skill is dead weight without its CLI and would still trigger, so the manifest marks it
`requires-bin=agent-reach`: generated only when the binary is on PATH, removed again if the
binary goes. `optional_agent_reach()` in `modules/claude.sh` installs the binary with
`uv tool install` **from the submodule path**, so its version is the pinned SHA. Its upstream
description claimed every "research this" request; the override narrows it to named platforms
and URLs, leaving general research to Matt's `research` skill. The English `SKILL_en.md` is the
source (`source=` flag); upstream's default `SKILL.md` is Chinese.

Only the binary is installed by esetup. The per-platform tools it routes to are agent-reach's
own business: `agent-reach install --env=auto` is a read-only report of what is missing.

## Loops

**Add a skill from a repo already vendored:** add a manifest line, run
`bash scripts/install-vendor-skills.sh`.

**Add a new repo:**

```bash
git submodule add https://github.com/<owner>/<repo>.git vendor-skills/<name>
# add its lines to vendor-skills/MANIFEST, pick a prefix, then
bash scripts/install-vendor-skills.sh
```

**Update a repo to its current upstream:**

```bash
git submodule update --remote vendor-skills/<name>
git -C vendor-skills/<name> log --oneline HEAD@{1}..HEAD -- skills   # what changed
bash scripts/install-vendor-skills.sh                              # regenerate
git add vendor-skills/<name> && git commit -m "chore: bump <name>"
```

For agent-reach, re-run `setup.sh` (or `optional_agent_reach` by hand) after the bump so the
binary converges onto the new SHA before the skill regenerates.

**Drop a skill:** delete its manifest line, then remove `~/.claude/skills/<target name>` by
hand; the generator never deletes a copy whose manifest line is gone, only one whose
`requires-bin` went missing.

## Name collisions

`~/.claude/skills` is flat. The prefixes are what keep three repos' `prototype`-style names
apart, so a new repo gets its own prefix even if its names look unique today.
