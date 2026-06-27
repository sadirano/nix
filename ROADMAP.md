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
- **onix byte-compatibility.** `aliases.toml` / `config.toml` / `usage` /
  segment files stay byte-for-byte compatible with onix. New state lives in new
  files (e.g. `groups.toml`), never by adding shapes onix's loader can't read.

Status legend: ✅ done · 🚧 in progress · ⬜ not started

---

## 0. Fixes

- ✅ **`absPath` normalizes `.`/`..`** — `o test .` stored `<cwd>/.` because
  `std.fs.path.join` doesn't collapse `.`. Switched to `std.fs.path.resolve`.
  (`src/main.zig`; committed as `52de9e1`.)

---

## 1. Alias groups (multi-alias)  ⬜

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
- **Storage:** new `~/.onix/groups.toml`. Members are **alias names**
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
  - `sg`/`ff +g` multi-root: grep/find refactored to take a roots list
    (`grepIn`/`findIn`); for a group the member dirs are passed to rg/rga/fd as
    absolute search paths, so they emit absolute file paths into one unified fzf
    picker (preview + open already accept absolute paths). Single-alias mode is
    gated unchanged (`roots.len == 1` → cwd-relative, no path args).
- ✅ **1d — navigation + launcher.** `o +group` resolves members → `fzf --multi`
  (`name -> path` rows); the topmost selection keeps the current shell (stacks a
  subshell), each other selection opens a new terminal via `launchTerminal`
  (`[nav] terminal` template + `{dir}`; Windows defaults to `wt -d`/`start`, Unix
  requires the config). `member+group` adds then navigates. New `[nav] terminal`
  config (reported by `--doctor`). Builds/tests green; `buildTerminalArgv`/
  `rowPath` unit-tested. The interactive fzf+subshell path can't be driven
  headless (verified by code review + config/argv tests).
  - Follow-up: POSIX `o +group` currently lists (the shell-function model needs a
    navigate verb to pick+cd); group nav is Windows-effective today.
  - Follow-up: `o pa+group` with an unregistered `pa` adds it as a (dead) member
    rather than routing through the unknown-alias picker first.

---

## 2. Per-alias actions  ⬜  (design sketch — open decisions remain)

Project-local, tool-agnostic named commands (like `package.json` scripts but
language-agnostic), runnable from anywhere.

### Sketch

- Storage parallels segments: project-local `<alias>/.onix/actions.toml` (travels
  with the repo) and central `~/.onix/actions/<alias>.toml` (private).
  ```toml
  [actions]
  test = "zig build test"
  serve = "npm run dev"
  ```
- Invocation must be explicit (silently treating a literal `r alias cmd` arg as
  an action name would be intent-guessing). Leading candidates: `r alias :test`
  vs `r test@alias`. Leaning `:test` since `@alias` reads as a *location*
  everywhere else.

### Open decisions (resolve before building)

- Invocation syntax (`:test` vs `test@alias` vs other).
- Storage location precedence (project-local vs central, and which wins).
- Whether actions participate in fan-out (`r +group :test`).

---

## 3. Export / import  ⬜  (design sketch — open decisions remain)

Portable backup/restore for the alias DB (also serves the `~/.onix` data-loss
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

- ⬜ **`--doctor --json` machine-readable output.** `cmdDoctor` already accepts
  `--json`/`-q` (so scripts don't break) but emits only the human-readable
  report. Implement a structured JSON form for tooling.
- ⬜ **`y` file-copy mode.** `y <alias> <pat>` works like `ff` (es/fd → fzf,
  multi-select) but copies the selected **files** to the clipboard as a
  system-level file drop (Windows `CF_HDROP` / `DROPFILES`), so a paste in
  Explorer drops the real files. Inverse of `p`. `clipboard.zig` already *reads*
  CF_HDROP; this needs the *write* side. Windows first; Mac/Linux can fall back
  to copying paths as text. Final `y` modes: `y alias` (path text) ·
  `y +group` (all member paths) · `y alias [pat]` (pick files → copy files).
