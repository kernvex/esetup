# Claude Code skills — architecture

We self-host a personal fork of [`mattpocock/skills`](https://github.com/mattpocock/skills)
and expose a curated subset to Claude Code via symlinks. This doc is the mental model.

## Three distinct things (don't conflate them)

| # | Thing | What it is | Where it lives | When it runs |
|---|-------|-----------|----------------|--------------|
| 1 | **Machine install** | Init the submodule + symlink skills into `~/.claude/skills`, then generate the vendored third-party skills (`vendor-skills.md`) and apply the job-skills shadows. | `scripts/install-claude-skills.sh` (this repo) | On any machine, as part of `setup.sh` |
| 2 | **Per-repo setup** | Upstream's `/setup-matt-pocock-skills` *skill* — configures a project's issue tracker/labels. | Inside whatever project you're working in | Once per project, on demand |
| 3 | **Upstream dev tooling** | `package.json`, Changesets, `scripts/link-skills.sh` in the fork. | Inside the fork | Never, for us — consumption needs **zero Node deps**. Do not `npm install`. |

## How skills are consumed

Claude Code loads skills from `~/.claude/skills/<skill-name>/SKILL.md`. We **symlink** each
chosen skill folder out of the submodule into that directory. This decouples repo location
from consumption — the fork can live anywhere; the symlinks always point at `~/.claude/skills`.

We use symlinks, **not** the Claude Code plugin marketplace, on purpose: plugin registration
lives in `.claude-plugin/plugin.json`, an upstream-tracked file — editing it would conflict on
every upstream pull. Symlinking auto-discovers our bucket and never touches upstream files.

Third-party skills are the exception: they are **generated copies**, not symlinks, because the
per-repo prefix has to be written into the frontmatter `name` Claude Code keys on. See
`vendor-skills.md`; the order is fork symlinks, then vendored copies, then job-skills shadows.

## Where things live

- **Fork:** `github.com/kernvex/skills` (origin) — forked from `mattpocock/skills` (upstream).
- **Submodule:** `skills/` at the root of this esetup repo (sibling to `karabiner-manager`),
  SSH URL, no branch pin — matching the existing submodule convention.
- **Personal bucket:** `skills/skills/6eniu5/` inside the fork (the only path we add upstream).
- **Vendored third-party skills:** `vendor-skills/<repo>` submodules of esetup (https URLs:
  public, read-only, nobody's fork), generated into `~/.claude/skills` under a per-repo prefix
  by `scripts/install-vendor-skills.sh` from `vendor-skills/MANIFEST`. See `vendor-skills.md`.
- **Live symlinks:** `~/.claude/skills/<name>` → `…/esetup/skills/skills/<bucket>/<name>`.
- **These docs:** `docs/claude-skills/` in esetup (kept here so the fork stays pristine).

## The `ALLOWED_BUCKETS` knob

`scripts/install-claude-skills.sh` only links buckets in `ALLOWED_BUCKETS`
(default: `engineering productivity misc 6eniu5`). This mirrors upstream's curated
`plugin.json` set (engineering + productivity), plus `misc` extras and our own bucket.
Matt's `personal/`, `in-progress/`, and `deprecated/` are intentionally **not** linked, and
future upstream buckets won't auto-install until added here. Tighten/loosen in that one array.

## Conflict-free design (two rules)

- **Rule A — personal skills live in their own bucket** (`skills/6eniu5/`). Never reuse Matt's
  `personal/`.
- **Rule B — never edit an upstream-tracked file** (`README.md`, `.claude-plugin/plugin.json`,
  `CLAUDE.md`, `CONTEXT.md`, bucket READMEs, `package.json`, `scripts/*`).

Result: the fork is exactly "upstream + one extra bucket." Every upstream update is a clean
merge. See `updating-the-fork.md`.
