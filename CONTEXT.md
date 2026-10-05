# esetup

A macOS bootstrap script that brings a fresh machine to a known state: Homebrew packages,
language toolchains, dotfiles, and Claude Code skills. Reruns must be safe.

## Language

### Dotfiles vs installer

**Installer**:
What esetup *is* — the bootstrap that installs Homebrew, runtimes, and secrets, then clones the
Dotfiles Repo and runs its installer. esetup no longer holds config files itself. See
[[docs/adr/0004]].
_Avoid_: dotfiles manager

**Dotfiles Repo**:
The standalone `kernvex/dotfiles` repo, cloned to `~/kernvex/dotfiles`. The single home for
everything the machine *is*: Stow Packages, Artifact Areas, and the `nvim`/`tmux-sessionizer`
submodules. Self-installing (`./install`), so it deploys without esetup.
_Avoid_: target dotfiles, deploy target (the old orphan throwaway this replaces)

**Stow Package**:
A top-level directory in the Dotfiles Repo that GNU stow symlinks into `$HOME` (e.g. `fish`,
`wezterm`, `bin`). Stowed `--no-folding` so target directories stay real, not folded into the repo.

**Artifact Area**:
A top-level directory in the Dotfiles Repo that is *not* a Stow Package — config the installer
*applies* rather than symlinks (`keyboard/` SmartSet layouts, `raycast/` export). Absent from the
stow package list.

**Salvage**:
Folding a config from a stray or older source (loose files, the `f412h4d/.dotfiles` repo, the live
`~/.config`) into the Dotfiles Repo, keeping the union of features so nothing is lost. Judged
against the live config, which is authoritative for "what I run now."

**Generator**:
A standalone repo that *generates* config into a target rather than shipping static files —
`karabiner-manager` (`rules.ts` → `karabiner.json`), `obsidian-habit-tracker` (`habits.md` → the
Habits vault), `obsidian-lingo` (`lingo.yaml` → the Lingo vault scaffold), and `identity`
(`identities/*.conf` → the routing files). Wired in by an `optional_*` or `setup_*` step (a
Non-Artifact); the generated output is data the installer produces, not part of the Declared Set.
How the repo arrives — vendored as a submodule, or cloned conditionally because it is private —
is a separate property and not part of being a Generator.
_Avoid_: Submodule Generator (the earlier name; `identity` is a Generator and is deliberately
not a submodule)



### Identity

**Identity**:
One "who am I here" — a name, an email, an SSH key, and an account per Routed Tool. Owns a
directory; every repo under it resolves to that Identity, and everything outside every such
directory resolves to the personal one. The folder is the only switch, so an Identity is never
selected by which shell, account or flag was used. Declared as one file in the private
`identity` Generator; everything that routes it is generated. See [[docs/adr/0007]].
_Avoid_: account (an Identity has several), profile (a Routed Tool's own term for something
weaker)

**Slug**:
An Identity's short name, and the stem of every name derived from it — its config file, its
`.inc`, and one config directory per Routed Tool. Full company name, not initials, so that a
directory encountered in an environment dump identifies itself.

**Routed Tool**:
A CLI whose active account is selected per folder by an environment variable — `gh`, `gcloud`,
`az`, `aws`. Unlike git it has no native folder awareness, which is the gap the shell hooks
exist to close. Each is one row in the Tool Registry.

**Tool Registry**:
The table naming, for each Routed Tool, its environment assignments, a verify command and a
login command. The reason adding a tool is a row rather than a rewrite: the hooks, the checker
and the restore path all read it.

**Vault**:
An `ansible-vault`-encrypted SSH private key, tracked in the private `identity` repo. Protected
by both repository access and a per-Identity passphrase. Restoring one needs that passphrase, so
it is always Manual — never something a run converges.

### Code layout

**Module**:
A sourced per-tool file under `modules/` (`rust.sh`, `node.sh`, `voiceink.sh`, …) holding one
tool's leaf install routine(s). `source`d into the single `setup.sh` process — never executed
standalone — so it shares every global, helper, ownership array, the Plan, and the accumulating
Manual list. `main()` calls its functions in explicit order; sourcing only *defines* them.
Modules are enumerated by explicit `source` lines (like the Declared Set, *not* discovered by
glob) and carry no shebang and no exec bit. The shared machinery — logging, ownership, the Plan,
the brew Steps (`_formula_step`/`_cask_step`), preflight, and `main()` — stays in `setup.sh`.
_Avoid_: script (a Module is not standalone-runnable, unlike the executables in `scripts/`)

### The install surface

**Declared Set**:
The artifacts `setup.sh` promises to put on a machine. Enumerated in the script itself, not
discovered from the machine.
_Avoid_: package list, manifest

**Artifact**:
One member of the Declared Set that carries a version: a brew formula, a brew cask, or Rust.
Not every Artifact yields a binary — fonts and apps do not.
_Avoid_: package, dependency

**Non-Artifact**:
A step in `setup.sh` that changes the machine but has no version to diff: stowing, `chsh`,
applying caveat actions, the Karabiner build, the VoiceInk Source Build. Never part of a Plan.
Under `--upgrade` the idempotent ones run and the destructive ones are suppressed into Manual.

**Source Build**:
A Non-Artifact that clones an upstream GPL repo, compiles it locally, and installs the
resulting app — chosen where the brew cask is paid or license-gated. VoiceInk is the first:
its cask is a paywalled pre-built binary, but the GPL-3.0 source builds free (`make local`,
ad-hoc signed). "Free" is not inherent to the source — the *same* source is trial-gated
unless compiled with the `LOCAL_BUILD` flag, which `make local` sets and which hardcodes
`licenseState = .licensed` (`LicenseViewModel.swift`). Compiled without it (the official
release), that source runs a 7-day trial. So the trap is a signature mismatch: the free
Source Build is **ad-hoc signed** (`codesign` shows `Signature=adhoc`, no authority);
the paid/trial binary is **Developer ID signed + notarized** (Authority: Prakash Joshi,
stapled ticket). If `/Applications/VoiceInk.app` shows a Developer ID, you're running the
trial binary, not your build, regardless of what setup intended. Carries an upstream version
but no Plan; updated by re-running the build (`git pull`), never `brew upgrade`. Heavy and
destructive, so like the Karabiner build it is suppressed into Manual under `--upgrade`.
_Avoid_: Artifact (no brew receipt, no Version Diff)

### Ownership

Three predicates that the script has historically conflated. They disagree, and the gap between
them is where reruns corrupt a machine.

**Brew-owned**:
Homebrew has a receipt for this Artifact. `brew list --formula X` or `brew list --cask X`.
This, and only this, is what "installed" means when building a Plan.
_Avoid_: installed, present

**Shadowed**:
An Artifact that *is* Brew-owned, but whose binary resolves outside `$(brew --prefix)` — so the
command you run is not the one Homebrew can upgrade. `claude-code` is shadowed by
`~/.local/bin/claude`. Detected after acting, from brew's own artifact list.

**Foreign**:
An Artifact that is *not* Brew-owned, yet something of that name is already on PATH — installing
would create a second copy and let PATH order pick the winner. Detected before acting, by name.
_Avoid_: shadowed (the reverse case), unmanaged

**Unowned App**:
An `/Applications/X.app` bundle exists for a cask that is not Brew-owned. Installing over it
fails; brew cannot upgrade it. The cask flavour of Foreign.

### The plan

**Plan**:
The memoized result of one `brew update && brew outdated --json=v2 --greedy`, consulted to decide
each Artifact's Action. A lookup table, not a schedule — it does not reorder or reschedule the
steps of `setup.sh`, and an Artifact that is never installed is never looked up.

**Action**:
What the Plan decides for one Artifact. Exactly one of `install`, `upgrade`, `skip`, `manual`,
or `failed`.

**Failed**:
An Action that was attempted and errored. Transient, unlike Manual — it makes the run exit
nonzero, because something broke rather than something being knowingly left alone.

**Manual**:
An Action meaning the script will not converge this Artifact, and will name it in the end-of-run
report along with a Reason. The predicate is Shadowed ∪ Foreign ∪ Unowned App ∪ Pinned, plus any
decision `--upgrade` suppressed rather than asked.

**Reason**:
Why an Artifact was classified Manual. Carried through to the report; a Manual entry without a
Reason is a bug.

### Version handling

**Version Diff**:
The fact that an Artifact's installed version differs from its available version. **No code in
this project computes one.** Homebrew computes it inside `brew outdated`; rustup computes its own
inside `rustup check`. We read verdicts, never compare version strings — so ordering, semver, and
strings like `py314_26.5.3-1` never enter the design.
_Avoid_: version comparison, semver check

### Claude skills

**Vendored Skill**:
A third-party skill generated into `~/.claude/skills` from a `vendor-skills/` submodule, as a
copy under a per-repo prefix (`emil-`, `taste-`) carrying a `.vendor-skill` marker. Distinct from
a fork skill (symlinked out of the `skills` submodule) and a shadow (linked last, from
job-skills). Not an Artifact: no version, nothing for the Plan to see. See
`docs/claude-skills/vendor-skills.md`.
_Avoid_: external skill, imported skill

**Skill Manifest**:
`vendor-skills/MANIFEST`, the register of Vendored Skills: one line per skill naming its
submodule, folder, target name and flags. The word "manifest" is otherwise avoided for the
Declared Set; this is the one thing in the repo that is a manifest, and it is not a Declared Set
(its members are generated files, not Artifacts).
_Avoid_: vendor list, skill list
