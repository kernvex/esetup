# Adding a personal skill

Skills are added **only** in your own bucket so upstream merges never conflict (Rule A/B).
This page is for skills you write. A skill from someone else's repo is vendored instead:
see `vendor-skills.md`.

## Loop

1. **Create the folder** in the fork submodule:
   ```bash
   cd skills/skills/6eniu5
   mkdir my-skill && cd my-skill
   ```

2. **Write `SKILL.md`** with frontmatter `name` + `description`, then the body. Choose how it's
   invoked:
   - **Model-invoked** (auto-fires): omit `disable-model-invocation`. Put rich trigger phrases
     in the `description` so Claude knows when to reach for it.
   - **User-invoked** (`/my-skill` only): set `disable-model-invocation: true`. A plain one-line
     description is fine.

   ```markdown
   ---
   name: my-skill
   description: One-line summary with trigger phrases so the model knows when to use it.
   ---

   # My skill
   …instructions…
   ```

   For longer skills, use upstream's **progressive-disclosure** pattern: keep `SKILL.md` short
   and point to sibling `.md` files that load on demand. Style reference:
   `skills/skills/productivity/writing-great-skills/SKILL.md` in the fork.

3. **Do NOT edit** `README.md` / `.claude-plugin/plugin.json` / `CLAUDE.md` (Rule B). The
   installer auto-discovers your skill by globbing `skills/6eniu5/*/SKILL.md`.

4. **Re-link** so it goes live in `~/.claude/skills`:
   ```bash
   bash scripts/install-claude-skills.sh
   ```

5. **Commit + push the fork:**
   ```bash
   git -C skills add skills/6eniu5/my-skill
   git -C skills commit -m "feat: add my-skill"
   git -C skills push origin main
   ```
   Then optionally bump the submodule pointer in esetup so other machines get the same SHA:
   ```bash
   git add skills && git commit -m "chore: bump skills submodule"
   ```

## Name collisions

`~/.claude/skills/` is **flat**, keyed by folder name. Keep your skill folder names unique vs
every installed bucket (engineering, productivity, misc).
