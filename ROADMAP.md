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
  nix homes at `~/.nix` (the transitional `~/.onix` migration and
  `ONIX_HOME`/`ONIX_SHELL` fallbacks were removed after v0.9.0).
- **Read-only queries stay read-only.** `--resolve` (alias and group forms)
  prints paths without creating directories; only navigation and actions
  materialize missing dirs.
- **nix never rewrites files it doesn't own.** `--init` never touches shell
  profiles — on Windows the wrappers on PATH are the whole integration (the
  retired `nix.ps1` snippet is deleted by `--sync`), and on POSIX the rc line
  is printed for the user to add. Every store nix does own is written via
  atomic temp+rename (`util.writeFileAtomic`).

---

## Shipped — locked decisions

### Alias groups (`+` multi-alias)

- **Sigil `+`, forbidden in alias names** (like `@`) so `pa+projects` parses
  unambiguously; `member+group` adds a member (creating the group),
  paralleling `o <alias> <path>` = register + navigate.
- **Members are alias names, resolved on use** — single source of truth in
  aliases.toml, groups auto-follow moves, dead members are detectable (skipped
  with a stderr note, never a hard failure); `nix <alias> --remove`
  cascade-strips the alias from every group. Nested `+group` members expand
  recursively (cycle/depth-guarded, deduped).
- **Dead `+sub` references get the dead-member policy too:** a member naming a
  deleted group is skipped with a note naming the missing group and its
  referrer (`skipping unknown group "+work" (referenced by "+all")`) — only
  the top-level group must exist. A group fails hard only when NOTHING
  resolves.
- **`o +group`:** the topmost fzf selection keeps the current shell; each
  additional one opens a new terminal via `[nav] terminal` (Windows defaults
  `wt -d` then `start`; Unix requires the config — no probing).
- **Deliberate fan-out exceptions:** `e` stays single-alias; `p +group` picks
  ONE member (a paste has one destination).
- **Out of v1:** ad-hoc comma lists (`sg pa,pb`); named `+groups` only.
- **Unregistered members route through the picker:** `pa+group` with an
  unknown `pa` goes through the unknown-alias directory picker (register
  first, then add) instead of recording a dead member; `-q`/`--no-prompt`
  errors instead.

### Per-alias actions (`r <alias> :<name>`)

- **A leading `:` marks a named action** vs a literal command, so `r` stays
  unambiguous. Actions run as a shell string (`cmd /c` / `sh -c`) so
  `&&`/pipes/redirects work.
- **Project-local wins over central:** `<alias-dir>/.nix/actions.toml` is
  committed and travels with the repo; `~/.nix/actions/<alias>.toml` stays
  private per-machine. Group fan-out runs each member's OWN action; members
  without it are skipped with a note.
- **Scripts shadow by PATH order** (project `.nix/scripts`, then central);
  the env rebuilds from the original PATH each run, so group fan-out never
  stacks dirs.

### Agent guide (`~/.nix/AGENTS.md`)

- **Installed artifact, not a repo `AGENTS.md` — locked.** Repo-level agent
  files are auto-read the moment anyone clones, which is the wrong consent
  model for machine-wide instructions. The guide only exists where the owner
  ran `nix --init`; nix never wires it into any agent's config (the README
  shows the one-line import).
- **Generated from config** by `--init`/`--sync` (`src/agents.zig`), so the
  rendered names honour `[shortcuts]` renames.

### main.zig split (module layout)

- **Command modules import `app.zig`/`resolve.zig`, never main.zig or each
  other's internals** — `app.zig` holds the App context + tiny shared
  helpers; `resolve.zig` the alias→path entry point (segment eval, picker
  handoff, registration) and group-target expansion; `open.zig` the shared
  picker-row/open plumbing. main.zig keeps dispatch/grammar, the alias-store
  commands, and the thin resolve-and-delegate entries (`navigate`, p/y).
- **Group fan-out (`cmd_groups.zig`) sits on top** of grep/find/run/nav/paste
  — it was extracted last because it calls into every family.
- **Tests live with their code**; main.zig's root test block references every
  module so `zig build test` collects them all.

### E2E harness (`zig build e2e`)

- **Drives the real exe against a scratch `NIX_HOME`** (`src/e2e.zig`; CI,
  nightly, and release all gate on it) — add/resolve/remove, groups,
  actions, segments, export→import, the read-only `--resolve` guarantee, and
  the `--doctor` output modes.
- **Out of scope by design:** `--init` (it edits the real user PATH via the
  registry) and every interactive path (fzf pickers, navigation subshells).

### `--doctor` output modes

- **Rows are buffered, then rendered** — the full report, `-q`/`--quiet`
  (warn/fail rows + summary only; silence means healthy), and `--json`/`-j`
  all read the same data, so the JSON mirrors the human rows one-to-one:
  `{version, built, failures, warnings, sections[].rows[]{status, label,
  detail, notes[]}}`. `--json` wins when both flags are given.
- **Exit code unchanged in every mode:** 1 iff any core check fails, so
  `nix --doctor -q && …` and JSON consumers agree.

### Export / import (`--export` / `--import`)

- **Single TOML document, not an archive** — greppable and stdout-friendly;
  config comments are preserved losslessly.
- **Merge by default, never clobbers:** only adds names not already present
  and never overwrites a local config.toml, so re-importing is safe;
  `--replace` is the deliberate full restore. Both modes non-interactive.
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
