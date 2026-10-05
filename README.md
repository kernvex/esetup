# esetup

Interactive macOS bootstrap: Homebrew, CLI tools, fnm/bun, optional Miniconda, SDKMAN!, Google Cloud SDK and the .NET SDK (which provides NuGet), optional Karabiner Elements (via the `karabiner-manager` submodule), and the standalone self-installing dotfiles repo cloned to `~/kernvex/dotfiles` by default (override with env `TARGET_DOTFILES`).

Optional artifacts are opt-in: they are prompted for on an interactive run, and `--upgrade` will converge one that is already installed but never introduce one you declined.

### .NET: which flavour, and MAUI

Two packagings, chosen per machine with `ESETUP_DOTNET_FLAVOR` (unset asks):

| | `cask` (`dotnet-sdk`) | `formula` (`dotnet`) |
|---|---|---|
| Source | Microsoft's official `.pkg` | Homebrew source build (dotnet/dotnet VMR) |
| Installs to | `/usr/local/share/dotnet` (asks for sudo) | the brew prefix (no sudo) |
| **MAUI** | **supported** | **not a supported configuration** |

**A machine that builds MAUI wants `ESETUP_DOTNET_FLAVOR=cask`.** MAUI is supported on Microsoft's own SDK build; on a source-built SDK it is not. Note the formula gives you no upfront signal — `dotnet workload search maui` still lists all eight MAUI workloads there and their manifests still install, so trouble surfaces later in a build and looks like a broken project rather than a wrong SDK. That is why the flavour is a deliberate choice at install time.

On the cask, setup then offers `dotnet workload install maui`, which needs a full Xcode (checked upfront) and sudo when the SDK root is root-owned.

Both flavours symlink a `dotnet` into the brew prefix, so they collide. Setup refuses to install one over the other and reports it instead of letting Homebrew lose the race.

### Toolchain shell environment

`scripts/apply-toolchain-env.sh` writes the fish config that installed toolchains need — `DOTNET_ROOT`, and gcloud's `path.fish.inc` so `gcloud components install` binaries land on PATH. It runs as the last step of `setup.sh` and is standalone-runnable:

```bash
./esetup/scripts/apply-toolchain-env.sh --dry-run   # preview
./esetup/scripts/apply-toolchain-env.sh             # apply
```

It detects toolchains by binary on disk rather than by Homebrew receipt, so it is correct however they arrived, and it generates the file wholesale: install a toolchain and re-run to add its config, remove one and re-run to retract it. Output goes to the fish stow package in the Dotfiles Repo (commit it) and is symlinked live; with no Dotfiles Repo present it writes `~/.config/fish/conf.d/` directly.

## Usage

From the repo root:

```bash
./esetup/setup.sh
```

Non-interactive / skip conflict checks (CI or advanced):

```bash
./esetup/setup.sh --skip-preflight
```

### Preflight (conflicts)

Before installing casks, the script checks for common issues:

- **Docker Desktop vs OrbStack** — both provide a Docker engine/CLI; you get a menu to skip OrbStack, install anyway, or abort.
- **Both stacks installed** — warns if Docker.app and OrbStack are present.
- **Rancher Desktop / Colima** — warns about overlapping container tooling.
- **`docker info` fails** — warns if the CLI exists but the daemon/context is broken.
- **`~/kernvex/dotfiles`** (or `TARGET_DOTFILES`) — warns if the path exists but is not the dotfiles git clone (setup leaves it alone).
- **Two Homebrew installs** — warns if both `/opt/homebrew` and `/usr/local` have `brew`.

Dotfiles are a **standalone repo** ([`kernvex/dotfiles`](https://github.com/kernvex/dotfiles)); esetup clones it to `~/kernvex/dotfiles` (default; override with `TARGET_DOTFILES`), runs its self-installer (`./install`, `stow --no-folding`), and applies the non-stowed artifact areas (`raycast/`, `keyboard/`). See [docs/adr/0004](./docs/adr/0004-dotfiles-extracted-to-standalone-self-installing-repo.md).

## Karabiner Elements and Raycast

The repo includes a **git submodule** at [`karabiner-manager`](./karabiner-manager) ([`kernvex/karabiner-manager`](https://github.com/kernvex/karabiner-manager)): TypeScript (`rules.ts`) generates `karabiner.json` and writes it to `~/.config/karabiner/karabiner.json` (override with env `KARABINER_CONFIG_PATH` when running `yarn build`).

**Clone with submodules** (or initialize later):

```bash
git clone --recurse-submodules https://github.com/kernvex/esetup.git
# or, from an existing clone:
git submodule update --init --recursive
```

**Verify the submodule remote** (requires [GitHub CLI](https://cli.github.com/)):

```bash
gh repo view kernvex/karabiner-manager
git submodule status
```

During `./esetup/setup.sh`, after the fnm Node step, you can opt in to install **Karabiner Elements**, **Raycast**, and **Rectangle** (used by window-management shortcuts), back up any existing `~/.config/karabiner/karabiner.json`, run `yarn install` / `yarn build` in `karabiner-manager`, and kickstart the Karabiner user daemon so the new JSON loads.

Rebuild by hand after editing rules:

```bash
cd karabiner-manager && yarn install && yarn build
launchctl kickstart -k "gui/$(id -u)/org.pqrs.karabiner.karabiner_console_user_server"
```

**Raycast follow-up:** many Hyper-key bindings open `raycast://…` deep links (built-in Raycast commands plus third-party extensions such as Toothpick, Silent Mention, and custom script commands). Until those extensions or scripts are installed, some shortcuts may do nothing or show an error in Raycast. A future pass can document required extensions or trim `rules.ts` to match what you actually install.

## Obsidian Habits

The repo includes a **git submodule** at [`obsidian-habit-tracker`](./obsidian-habit-tracker) ([`kernvex/obsidian-habit-tracker`](https://github.com/kernvex/obsidian-habit-tracker)): a generator that turns `habits.md` into a full Obsidian **Habits** vault (daily-note template, Bases views, heatmaps, streak dashboard). Same pattern as `karabiner-manager`. See [docs/adr/0005](./docs/adr/0005-obsidian-habit-tracker-submodule.md).

During `./esetup/setup.sh`, after the Karabiner step, you can opt in to
`optional_obsidian_habit_tracker`: it initializes the submodule, installs the
**Obsidian** cask, runs `bun install && bun run sync`, and deploys the vault into
the Obsidian iCloud container (override with `OBSIDIAN_HABITS_VAULT`), then copies
in the `.obsidian` config + pinned plugins from the dotfiles `obsidian` package.

**Obsidian ≥ 1.12.4 required** on Mac *and* iPhone — Bases (the dashboard engine)
does not exist before then. Rebuild/redeploy by hand after editing habits:

```bash
cd obsidian-habit-tracker && bun run add-habit   # or: edit habits.md && bun run sync && bun run deploy --apply
```

## Obsidian Lingo

A second generator submodule at [`obsidian-lingo`](./obsidian-lingo) ([`kernvex/obsidian-lingo`](https://github.com/kernvex/obsidian-lingo)): a config-driven generator for the **Lingo** language-learning vault — language-agnostic Concepts + per-language flashcards reviewed with obsidian-spaced-repetition (FSRS). Same submodule pattern as `obsidian-habit-tracker`; adding a language is one command (`bun run add-language Spanish`). See [docs/adr/0006](./docs/adr/0006-obsidian-lingo-submodule.md).

During `./esetup/setup.sh`, `optional_obsidian_lingo` (after the Habits step)
inits the submodule, runs `bun install && bun run sync`, deploys the scaffold
(templates + `.obsidian/types.json`) into the iCloud container
(`OBSIDIAN_LINGO_VAULT`), and copies the `.obsidian` config + spaced-repetition
plugin from the dotfiles `obsidian/lingo` package. Your cards are content and sync
via iCloud; the generator never touches them.

## Scripts

Standalone helpers under [`scripts/`](./scripts) (executable, run directly — not sourced like `modules/`):

- [`migrate-to-fish.sh`](./scripts/migrate-to-fish.sh) — one-shot zsh → fish default-shell migration.
- [`install-claude-skills.sh`](./scripts/install-claude-skills.sh) — link the Claude skills submodule into `~/.claude/skills` (see [docs/claude-skills](./docs/claude-skills)).
- [`install-vendor-skills.sh`](./scripts/install-vendor-skills.sh) — generate the third-party skills listed in [`vendor-skills/MANIFEST`](./vendor-skills/MANIFEST) (Emil Kowalski's, taste-skill, agent-reach) into `~/.claude/skills` under per-repo prefixes (see [docs/claude-skills/vendor-skills.md](./docs/claude-skills/vendor-skills.md)). Called by `install-claude-skills.sh`; `--check` verifies.
- [`update-github-remotes.sh`](./scripts/update-github-remotes.sh) — repoint git remotes after a GitHub handle rename (see below).
- [`update-github-handle-refs.sh`](./scripts/update-github-handle-refs.sh) — rewrite GitHub handle references (URLs + repo slugs) inside file contents after a rename, preserving filesystem paths (see below).

### update-github-remotes.sh

After renaming your GitHub account, existing clones keep pointing at the old handle. GitHub redirects them for a while, then **stops without warning** and pushes start failing. This sweeps every git repo under `~` and repoints only the remotes that still reference the old handle — repos with multiple remotes keep their other remotes untouched. It matches both SSH (`git@github.com:old/…`) and HTTPS (`https://github.com/old/…`) URLs.

```bash
scripts/update-github-remotes.sh            # dry run: preview what would change
scripts/update-github-remotes.sh --apply    # rewrite the matching remotes
scripts/update-github-remotes.sh --verify   # git ls-remote each new remote to confirm access
```

The handles default to this repo's own migration (`6eniu5` → `kernvex`); override for a future rename:

```bash
OLD_HANDLE=oldname NEW_HANDLE=newname scripts/update-github-remotes.sh --apply
```

Every run writes a timestamped report to `~/.github-remote-updates/`. Dry run and `--verify` never change anything; rewriting is idempotent and safe to re-run. `--verify` uses `BatchMode`/`GIT_TERMINAL_PROMPT=0`, so an unreachable remote is logged as `FAIL` instead of hanging on a credential prompt. Other flags: `--help`; env `ROOT` and `MAXDEPTH` tune the search (default `~`, 5 levels deep).

> Note: submodule remotes (`karabiner-manager`, `obsidian-*`, dotfiles' `nvim`) are stored as `.git` **files**, not directories, so this script skips them. Update those with `git config -f .gitmodules` + `git submodule sync`, or in the submodule's own checkout.

### update-github-handle-refs.sh

`update-github-remotes.sh` fixes git *remotes*; this fixes the handle written into **file contents** — clone commands in docs, submodule URLs in `.gitmodules`, and default URLs in setup scripts.

It rewrites the handle in two forms: inside a **GitHub URL** (`github.com/OLD`, `github.com:OLD`) and as a bare **repo slug** (`OLD/repo`, e.g. `` `OLD/dotfiles` ``, `gh repo view OLD/x`). It never touches the handle when it is a **filesystem path**: any `OLD/` preceded by `/` or `~` (`~/kernvex/dotfiles`, `$HOME/kernvex/…`) is left alone, because the personal folder was itself named after the handle — only renaming the directory can safely change those (that rename has since happened: `~/6eniu5` → `~/kernvex`). It also ignores non-slug bare uses (git identity, the ssh key filename `OLD_id_ed25519`, the Bonjour hostname, the `gh` account) — each a separate, deliberate change. Use `--scan` to audit everything it leaves.

```bash
scripts/update-github-handle-refs.sh            # dry run: show refs (old -> new)
scripts/update-github-handle-refs.sh --apply    # rewrite them (backs up every file first)
scripts/update-github-handle-refs.sh --scan     # audit ALL bare OLD occurrences it won't touch
```

Backups for each `--apply` go to `~/.github-remote-updates/backups-<timestamp>/` (mirroring the original paths), plus a timestamped report. Skips history/app-state/build noise (`.git`, `.claude`, `.cursor`, `node_modules`, `target/dist/build`, shell histories, transcripts). Handles/root are env-overridable (`OLD_HANDLE`, `NEW_HANDLE`, `ROOT`). Needs ripgrep with PCRE2 (`rg -P`) for the path-vs-slug lookarounds.

> Caveat: because the local directory shares the handle's name, a bare `OLD/dotfiles` that actually means the *local path* (not the GitHub repo) is indistinguishable from a repo slug by regex — review those after `--apply`. Also run `git submodule sync` in any repo whose `.gitmodules` changed so the new URL reaches each submodule's `.git/config`.

## Requirements

- macOS
- Network for Homebrew and git submodules (SSH keys for GitHub)

## Dotfiles

Dotfiles live in their own self-installing repo, [`kernvex/dotfiles`](https://github.com/kernvex/dotfiles),
cloned to `~/kernvex/dotfiles`. Stow packages (`fish`, `starship`, `wezterm`, `tmux`,
`tmux-sessionizer-config`, `bin`, `atuin`, `git`, `htop`, `nvim`) plus the `nvim`/`tmux-sessionizer`
submodules and the `keyboard/`/`raycast/` artifact areas. esetup just clones and runs its `./install`;
the repo also deploys standalone (`git clone … && ./install`). See [docs/adr/0004](./docs/adr/0004-dotfiles-extracted-to-standalone-self-installing-repo.md).

## Go

`setup.sh` installs `go` and `tree-sitter-cli` via Homebrew; fish adds `~/go/bin` to PATH.
In Neovim, Mason auto-installs `gopls` and `goimports` on first `.go` file; format-on-save uses goimports + gofmt.

## Rust

`setup.sh` installs the toolchain via the **official rustup installer** (`run_rustup_default_toolchain`), not Homebrew — see lesson below. fish already has `~/.cargo/bin` on PATH and sources `~/.cargo/env.fish`, so no shell changes are needed. `rustfmt` + `clippy` ship with the stable profile. In Neovim, Mason auto-installs `rust_analyzer` on first `.rs` file; format-on-save uses `rustfmt`.

### Lessons learned

- Use the **official rustup installer** (`curl https://sh.rustup.rs | sh`), not `brew install rustup`. The Homebrew formula is keg-only and keeps its proxies in the keg — it leaves `~/.cargo/bin` **empty**, so nothing lands on the PATH the fish config expects. The official installer populates `~/.cargo/bin` and writes `~/.cargo/env.fish` (the exact layout config.fish was already wired for).

## Go lessons learned

- The CLI is the Homebrew formula **`tree-sitter-cli`**, not `tree-sitter` (that one is library-only, no binary). nvim-treesitter's `main` branch needs it to compile parsers, else builds fail with `ENOENT: 'tree-sitter'`.
- nvim-treesitter is pinned to `branch = 'main'`. Use its API (`require('nvim-treesitter').install(parsers)`), **never** `require('nvim-treesitter.configs').setup{}` — that module exists only on the old `master` branch and errors on `main` (`attempt to call field 'install' (a nil value)` shows the reverse: a stale `master` checkout under a `main` spec). Fix a stale checkout: `cd ~/.local/share/nvim/lazy/nvim-treesitter && git fetch origin main && git checkout main && git reset --hard origin/main`.
- The nvim config is a submodule of `kernvex/kickstart.nvim` (default branch `master`); push there for new machines. It is now a submodule of the standalone [`kernvex/dotfiles`](https://github.com/kernvex/dotfiles) repo — commit dotfiles changes there and push (it has a remote), unlike the old local-only stow target.
