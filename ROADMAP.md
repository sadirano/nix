# nix roadmap

Two things live here: the **locked design decisions** behind shipped features
(so we can extend them without re-litigating) and the **backlog** of planned
work. Fix history and implementation play-by-play live in `git log`, not here.

## Guiding principles

- **Exact and forward-only.** nix goes exactly where the user says, fast. No
  fuzzy/frecency/nearest-match navigation, no back-stack/"where did I come
  from" history. If a target doesn't exist the user wants it to *exist* — the
  unknown-alias picker helps *create* it, it never guesses among existing
  aliases.
- **Combining explicit targets is welcome** (groups, fan-out); guessing intent
  is not.
- **Simple, onix-derived formats.** `aliases.toml` / `config.toml` / `usage` /
  segment files keep onix's simple TOML shapes. New state lives in new files
  (e.g. `groups.toml`), never by adding shapes the simple readers can't handle.
  nix homes at `~/.nix` (auto-migrated from the legacy `~/.onix`; fallback
  removed at 1.0).
- **Read-only queries stay read-only.** `--resolve` (alias and group forms)
  prints paths without creating directories; only navigation and actions
  materialize missing dirs.
- **nix never rewrites files it doesn't own.** `--init` prints the $PROFILE
  one-liner instead of appending it; every store nix does own is written via
  atomic temp+rename (`util.writeFileAtomic`).

---

## Shipped — locked decisions

### Alias groups (`+` multi-alias)

- **Sigil:** `+`, forbidden in alias names (like `@`) so `pa+projects` parses
  unambiguously. `+group` references a group; `member+group` adds a member
  (creating the group), paralleling `o <alias> <path>` = register + navigate.
- **Storage:** `~/.nix/groups.toml`, flat `projects = ["pa", "pb"]`. Members
  are **alias names**, resolved on use — single source of truth in
  aliases.toml, auto-follows moves, dead members detectable (skipped with a
  stderr note). `nix <alias> --remove` cascade-strips the alias from every
  group.
- **Nesting:** a member may be `+othergroup`; expansion is recursive with
  cycle detection, a depth guard, and dedupe.
- **`o +group`:** fzf multi-select of members (`name -> path` rows). The
  **topmost** selection keeps the current shell (stacked subshell); each
  additional selection opens a new terminal via `[nav] terminal` in
  config.toml (`{dir}` placeholder; Windows defaults `wt -d` then `start`,
  Unix requires the config — no probing).
- **Fan-out:** `sg`/`ff` search all member roots as one picker (rows read
  `alias\rel`, mapped back on selection); `r` runs sequentially per member
  with a per-dir header, no confirm; `s`/`y` open/copy all members (or run the
  file picker with a pattern); `p` picks ONE member then pastes. `e` is
  deliberately single-alias.
- **Management:** `nix --groups`, `nix +g --list`, `nix pa+g --remove`,
  `nix +g --remove`.
- **Out of v1:** ad-hoc comma lists (`sg pa,pb`); named `+groups` only.

### Per-alias actions (`r <alias> :<name>`)

- **Invocation:** a leading `:` marks a named action vs a literal command;
  `r <alias> :` lists them. Runs as a shell string (`cmd /c` / `sh -c`) in the
  alias dir so `&&`/pipes/redirects work; `-o` runs detached.
- **Storage:** project-local `<alias-dir>/.nix/actions.toml` (committed,
  travels with the repo) wins over central `~/.nix/actions/<alias>.toml`
  (private) — a `[actions]` table of `name = "command"`.
- **Group fan-out:** `r +<group> :<name>` runs each member's OWN action;
  members without it are skipped with a note.
- **Project scripts:** the alias's `.nix/scripts` (then central
  `~/.nix/scripts`) is prepended to PATH in any alias context, so
  `r <alias> build` and the `o <alias>` subshell resolve the project's own
  scripts, shadowing globals. The env rebuilds from the original PATH each
  run, so group fan-out never stacks dirs.

### Agent guide (`~/.nix/AGENTS.md`)

- **Installed artifact, not a repo `AGENTS.md` — locked.** Repo-level agent
  files are auto-read the moment anyone clones, which is the wrong consent
  model for machine-wide instructions. The guide only exists where the owner
  ran `nix --init`; nix never wires it into any agent's config (the README
  shows the one-line import).
- **Generated from config** by `--init`/`--sync` (`src/agents.zig`), so the
  rendered names honour `[shortcuts]` renames.

### Export / import (`--export` / `--import`)

- **Single TOML v1**, not an archive — greppable and stdout-friendly. Flat
  sub-tables: `[aliases]`, `[groups]`, `[config]`/`[config.*]` (comments
  preserved losslessly), `[actions.<alias>]` (central per-alias actions).
- **Merge by default, never clobbers:** only adds names not already present
  and never overwrites a local config.toml; `--replace` does the deliberate
  full restore. Both modes non-interactive.
- **`usage` excluded** (machine-local churn); project-local
  `.nix/actions.toml` files travel with their repos and are out of scope.

---

## Backlog

- 💤 **POSIX shell-function parity (low priority — nix is Windows-first).**
  POSIX `o` is a shell function that cd's the exe's stdout (no subshell), so
  (a) `o +group` routes to `--list` instead of navigating, (b) `o <alias>`
  can't get `.nix/scripts` scoped on PATH, and (c) since `--resolve` went
  read-only, a registered-but-deleted dir no longer reappears on `o`. All
  need a navigate verb the function calls for these cases. Deferred —
  revisit only if non-Windows use becomes important.
- ⬜ **Picker-route for `o pa+group` with an unregistered `pa`.** Today it adds
  `pa` as a (dead) member; the design wants it to route through the
  unknown-alias es/fd picker to register `pa` first, then add + navigate.
- ⬜ **`--doctor --json` machine-readable output.** `cmdDoctor` already accepts
  `--json`/`-q` (so scripts don't break) but emits only the human-readable
  report. Implement a structured JSON form for tooling.
- ⬜ **Split `src/main.zig` (post-0.9.0).** At ~4k lines it holds dispatch,
  groups, doctor, picker, sweep, paste, init/sync, import/export, and
  navigation. The section markers are the seams (`doctor.zig`, `picker.zig`,
  `cmd_groups.zig`, `init.zig`, …) with `App` as the shared context.
  Deliberately deferred until v0.9.0 ships — a mechanical 4k-line move right
  before a release would reset the soak.
- ⬜ **Scripted end-to-end harness.** The historical "verified end-to-end
  against a scratch NIX_HOME" runs were manual. A script that builds, points
  `NIX_HOME` at a temp dir, and drives the real exe through
  add/resolve/remove/groups/actions/export→import would lock those behaviors
  in CI — most historical bugs lived at the dispatch/IO seam the unit tests
  can't reach.
- ⬜ **Legacy `.onix/` project-dir nudge.** After the rename, a project with
  `.onix/actions.toml` but no `.nix/` silently loses its actions (this repo
  had exactly that). When the actions/scripts loader finds the legacy dir and
  no new one, print a one-line warning.
- ⬜ **Grace note for pre-existing `+` alias names.** Forbidding `+` in names
  can reject *re-registering* an old alias whose name contains `+` (resolve
  still works; only the add path validates). Decide whether that needs a
  migration hint in the error message.
