# nix roadmap

Planned work, in implementation order. Each item records the decisions already
made so we can build without re-litigating them.

## Guiding principles

- **Exact and forward-only.** nix goes exactly where the user says, fast. No
  fuzzy/frecency/nearest-match navigation, no back-stack/"where did I come
  from" history. If a target doesn't exist the user wants it to *exist* — the
  unknown-alias picker helps *create* it, it never guesses among existing
  aliases.
- **Combining explicit targets is welcome** (groups, fan-out); guessing intent
  is not.
- **Simple, onix-derived formats.** `aliases.toml` / `config.toml` / `usage` /
  segment files keep onix's simple TOML shapes, so a legacy `~/.onix` migrates
  cleanly. New state lives in new files (e.g. `groups.toml`), never by adding
  shapes the simple readers can't handle. nix now homes at `~/.nix` (auto-migrated
  from the legacy `~/.onix`; fallback removed at 1.0).

Status legend: ✅ done · 🚧 in progress · ⬜ not started

---

## 0. Fixes

- ✅ **`absPath` normalizes `.`/`..`** — `o test .` stored `<cwd>/.` because
  `std.fs.path.join` doesn't collapse `.`. Switched to `std.fs.path.resolve`.
  (`src/main.zig`; committed as `52de9e1`.)

---

## 1. Alias groups (multi-alias)  ✅

A group is a named set of aliases, referenced with the `+` sigil, used for
multi-target navigation and for fanning out search/run/yank across projects.

### Locked decisions

- **Sigil:** `+`. Forbidden in alias names (add to `store.validateAliasName`,
  exactly like `@`) so `pa+projects` parses unambiguously. `+` is the only
  candidate that is shell-safe in bash/zsh/PowerShell/cmd **and** doesn't
  collide with nix's existing `@` (segment sigil) / `:` (segment inline value).
- **Grammar:**
  - `+projects` — reference a group.
  - `pa+projects` — add alias `pa` to group `projects` (create if new), then run
    the action (parallels `o <alias> <path>` = register + navigate).
- **Storage:** new `~/.nix/groups.toml`. Members are **alias names**
  (resolve-on-use → single source of truth in `aliases.toml`, auto-follows
  moves, dead members detectable). Format: `projects = ["pa", "pb"]`.
- **Nesting:** allowed. A member may be `+othergroup`; resolution expands
  **recursively** with cycle detection, a depth guard, and dedupe.
- **`o +projects`:** resolve members → `fzf --multi`, rows shown as
  `name -> path`. **Topmost selected row** keeps the current shell (Windows:
  stacked subshell via `runInherit`; POSIX: printed path → `cd`). Each
  **additional** selected row opens a new terminal at its dir. (Topmost = fzf
  list order = `groups.toml` add order; chosen as the easiest, deterministic
  rule.)
- **`o pa+projects`:** add `pa` (idempotent no-op if already a member), then
  navigate the group. If `pa` is unknown, route through the existing es/fd
  unknown-alias picker to register it first, then add + navigate.
- **Dead member** (alias removed but still listed): skip with a note to stderr,
  navigate the survivors.
- **`nix pa --remove` cascade:** also strip `pa` from every group in
  `groups.toml`.
- **Fan-out** (no fzf-multi, no new shells):
  - `sg +projects <pat>` / `ff +projects [pat]` — search across all member
    roots (recursively expanded, deduped) into the existing fzf-preview
    pipeline (`rg`/`rga`/`fd` accept multiple roots natively).
  - `r +projects <cmd>` — run `<cmd>` in each member dir **sequentially, no
    confirm prompt**, with a per-dir header.
  - `y +projects` — yank all member paths (newline-separated) to the clipboard.
- **Terminal launcher:** `[nav] terminal = "…{dir}…"` in `config.toml`
  (`{dir}` placeholder).
  - Windows default: `wt -d {dir}`, fallback `start "" <COMSPEC>` at the dir.
  - Unix: **no probing/defaults** — require `[nav] terminal`; if unset, skip the
    extra selections with a note.
- **Management** (mirror the alias grammar):
  - `nix --groups` — list all groups.
  - `nix +projects --list` — list a group's members.
  - `nix pa+projects --remove` — drop a member.
  - `nix +projects --remove` — delete the group.
- **Out of v1:** ad-hoc comma lists (`sg pa,pb`); named `+groups` only.

### Known caveat

Forbidding `+` in names can reject *re-registering* a pre-existing alias whose
name contains `+` (resolve still works; only the add path validates). Decide on
a grace/migration note when implementing the validator change.

### Implementation order

- ✅ **1a — store + resolver.** `src/groups.zig`: read/write `groups.toml`,
  recursive member expansion (cycle detection, depth guard, dedupe), `+`-prefix
  grammar parsing (`parseRef`), and mutation helpers (add/remove member, remove
  group, cascade-strip). Added `+` to `store.validateAliasName` and exposed
  `store.appendTomlString`. Module tests pass; not yet wired into any command
  (that's 1b–1d). Committed as `58f6622`.
- ✅ **1b — management commands.** `nix --groups`, `nix +g --list`,
  `nix pa+g --remove`, `nix +g --remove`, and the add form `nix pa+g`. `dispatch`
  routes any `+`-bearing first token through the group grammar; `nix <alias>
  --remove` cascade-strips the alias from every group. Verified end-to-end.
- ✅ **1c — fan-out.** `+group` wired into `sg`/`ff`/`r`/`y`.
  - `r +g <cmd>` (run in each member dir, sequential, per-dir header) and `y +g`
    (yank all member paths) via `resolveGroupTargets` (dead members skipped with
    a note); `dispatchGroupRef` scans for the first action flag (reusing
    `aliasAction`) so group actions parse like alias ones.
  - `sg`/`ff +g` multi-root: grep/find refactored to take a target list
    (`grepIn`/`findIn`); for a group each member's rg/rga/fd runs IN the member
    dir via a per-producer pipeline (`proc.runPipelinePrefixed`) that prefixes
    every row with the member's alias, so rows read `alias\rel:line:` instead of
    the absolute root. Selections map back via `expandPrefixedSelection`; the
    preview verbs rebase the alias token (`expandAliasRowPath`). Single-alias
    mode is gated unchanged (one target → cwd-relative, no prefix).
- ✅ **1e — full action coverage (2026-07-02).** Every command except `e` has a
  group form: `s +g [pat]` (fan-out file manager, or file picker → open with
  default apps), `y +g [pat]` (member paths as text, or file picker → CF_HDROP
  file copy), `p +g [name]` (fzf member picker → paste into the ONE chosen
  member), `nix +g --resolve` (member paths one per line). `e +group` was
  deliberately left single-alias.
- ✅ **1d — navigation + launcher.** `o +group` resolves members → `fzf --multi`
  (`name -> path` rows); the topmost selection keeps the current shell (stacks a
  subshell), each other selection opens a new terminal via `launchTerminal`
  (`[nav] terminal` template + `{dir}`; Windows defaults to `wt -d`/`start`, Unix
  requires the config). `member+group` adds then navigates. New `[nav] terminal`
  config (reported by `--doctor`). Builds/tests green; `buildTerminalArgv`/
  `rowPath` unit-tested. The interactive fzf+subshell path can't be driven
  headless (verified by code review + config/argv tests). Two follow-ups tracked
  in the Backlog (POSIX group nav, picker-route for an unregistered add member).

---

## 2. Per-alias actions  ✅

Named shell commands per alias, run with `r <alias> :<name>` — like
`package.json` scripts but language-agnostic. `src/actions.zig` +
`cmdRun`/`cmdGroupRun`.

- **Invocation:** `r <alias> :<name>` — a leading `:` on the run argument marks a
  named action vs a literal command; `r <alias> :` lists them. `:` doesn't
  collide with the segment inline-value `:` (different position) or `@` segments
  (which `test@alias` would have hit).
- **Storage:** project-local `<alias-dir>/.nix/actions.toml` (committed, travels
  with the repo) wins over central `~/.nix/actions/<alias>.toml` (private) — a
  `[actions]` table of `name = "command"`.
- **Execution:** the command is a shell string run via `cmd /c` (Windows) or
  `sh -c`, in the alias dir, so `&&`/pipes/redirects work. `-o` runs it detached.
- **Group fan-out:** `r +<group> :<name>` runs each member's OWN action; a member
  without it is skipped with a note.
- **Project scripts (`.nix/scripts`):** the alias's `.nix/scripts` dir (then
  central `~/.nix/scripts`) is prepended to `PATH` in any alias context
  (`aliasRunEnv`, via env-aware `runInheritEnv`/`runDetachedEnv`). `r <alias>
  build` runs the project's `build` (resolved by `resolveScript` — a direct spawn
  looks argv[0] up against the *real* PATH, not the injected env, so the dir is
  probed explicitly), and **`o <alias>` opens a subshell with the scripts dir on
  PATH** (scoped to that shell), so a project's own `build`/`clean` work as bare
  commands with no global versions. Fans out per member (`r +group build`); the
  env rebuilds from `App.orig_path` each run so a group never stacks dirs. `:`
  stays explicit for actions; this is plain command resolution.

Verified end-to-end (project-over-central, listing, `&&`, unknown action, group
fan-out; scripts resolution project/central/shadow-global + group + no PATH
accumulation). `actions.parse`/`find`/path helpers unit-tested.

---

## 2.5. Agent guide (`~/.nix/AGENTS.md`)  ✅

An agent-facing guide to the installed command surface, so coding agents
suggest `r acme :test` instead of absolute-path instructions. `src/agents.zig`,
written by `snippet.regenerate` (so both `--init` and `--sync` refresh it).

- **Installed artifact, not a repo `AGENTS.md` — locked.** Repo-level agent
  files are auto-read the moment anyone clones, which is the wrong consent
  model for machine-wide instructions (and reads as prompt injection). The
  guide only exists where the owner ran `nix --init`.
- **Generated from config:** the rendered names honour `[shortcuts]` renames
  (unit-tested), so a `s = "show"` machine's agents are told `show acme`.
- **Never auto-wired:** nix does not touch any agent's config. The README
  documents the one-line import users add themselves (e.g. `@~/.nix/AGENTS.md`
  in Claude Code's global `~/.claude/CLAUDE.md`).
- **Content rules:** descriptive and conditional ("the user of this machine…"),
  discover aliases via `nix --list` before suggesting, prefer `.nix/actions.toml`
  actions for repeatable commands, resolve with `nix <alias>` instead of `o` in
  non-interactive shells, never launch the fzf pickers headless.

---

## 3. Export / import  ⬜  (design sketch — open decisions remain)

Portable backup/restore for the alias DB (also serves the `~/.nix` data-loss
recovery need).

### Sketch

- `nix --export [file]` bundles aliases + groups + per-alias actions + config
  into one portable TOML (stdout if no file).
- `nix --import <file>` **merges** by default (never clobbers); `--replace` flag
  for a deliberate full restore.

### Open decisions (resolve before building)

- Exact merge semantics on conflict (skip / overwrite / prompt).
- Whether export includes `usage` ranking data.
- Bundle format (single concatenated TOML vs a small archive).

---

## Backlog

- 💤 **POSIX shell-function parity (low priority — nix is Windows-first).**
  Two `o`-on-POSIX gaps share one root cause: POSIX `o` is a shell function that
  cd's the exe's stdout (no subshell), so (a) `o +group` routes to `--list`
  instead of navigating, and (b) `o <alias>` can't get `.nix/scripts` scoped on
  PATH. Both need a navigate verb the function calls for these cases. Deferred —
  revisit only if non-Windows use becomes important.
- ⬜ **Picker-route for `o pa+group` with an unregistered `pa`.** Today it adds
  `pa` as a (dead) member; the design wants it to route through the unknown-alias
  es/fd picker to register `pa` first, then add + navigate.
- ⬜ **`--doctor --json` machine-readable output.** `cmdDoctor` already accepts
  `--json`/`-q` (so scripts don't break) but emits only the human-readable
  report. Implement a structured JSON form for tooling.
- ✅ **`y` file-copy mode.** `y <alias> <pat>` runs the `ff` picker
  (`findPick`) and copies the selected **files** to the clipboard as a system
  file drop — `clipboard.writeFiles` builds a `DROPFILES`/CF_HDROP payload
  (`dropfilesBuffer`, unit-tested; round-trip verified against Explorer's
  FileDropList). Non-Windows falls back to copying paths as text. `y` modes:
  `y alias` (path text) · `y +group` (all member paths) · `y alias [pat]`
  (pick files → copy files). POSIX `y` snippet now forwards the pattern arg.
