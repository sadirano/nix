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
- **Read-only queries never write.** `--resolve` (alias and group forms)
  prints paths without creating directories; only navigation and actions
  materialize missing dirs. A context source's `run` is the deliberate
  exception to "does nothing": executing it is how the path is *computed*, so
  `--resolve` runs it on a cache miss like every other form. It still writes
  nothing but the result cache.
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
- **Project-local wins over central, central over machine-wide:**
  `<alias-dir>/.nix/actions.toml` is committed and travels with the repo;
  `~/.nix/actions/<alias>.toml` stays private per-machine;
  `~/.nix/actions/_default.toml` holds personal cross-project actions usable
  from any alias (`_default` is a reserved name — never registrable, so the
  file can share the central dir and export/import as a normal action set).
  Group fan-out runs each member's OWN action (defaults included); members
  resolving nothing are skipped with a note.
- **Scripts shadow by PATH order** (project `.nix/scripts`, then central);
  the env rebuilds from the original PATH each run, so group fan-out never
  stacks dirs.

### `[bin]` exports (`--sync-bin`)

- **Project-local `[bin]` in the committed `.nix/actions.toml` only** — the
  file travelling with the repo is what gives an export provenance, and it
  keeps `[bin]` out of `--export`/`--import` (which round-trip only central
  `[actions]`). Central/private `[bin]` can come later if wanted.
- **Copy exes, forward scripts.** A copy survives rebuilds while the tool is
  running and adds no indirection; `.cmd`/`.bat` get a one-line forwarder so
  edits take effect live; `.ps1` gets a `.cmd` trampoline (pwsh, else
  powershell) because PATHEXT rarely includes `.PS1`. Other types are refused
  (a bin holds runnables, not data — the Noir `user\` lesson).
- **Membership is declarative via the `~/.nix/exports.toml` manifest**
  (`<installed file> = "<owning alias>"`). Sync only ever deletes files the
  manifest owns; dropping the `[bin]` line or the alias prunes the file on the
  next sync. An alias dir that is merely UNREACHABLE (unplugged drive) keeps
  its exports — unknown is not undeclared; uninstalling follows an explicit
  act only.
- **New exports need an explicit `--sync-bin`; `--sync` only refreshes.**
  `--sync` runs the bin sync in implicit mode: manifest-owned exports are
  refreshed/pruned, but a name not yet in the manifest is only listed for
  review — so registering a repo can never install commands on PATH as a side
  effect. Installing also warns when the name resolves elsewhere on PATH
  (shadowing is legitimate, surprising is not; doctor keeps a note-level row).
- **Collisions refuse loudly, nobody wins:** a name declared by two aliases is
  reported and left uninstalled until one renames. Wrapper names — builtin
  slots, `[shortcuts]` renames, `nix` itself — and DOS device names
  (`nul`, `con`, `com1`…) are reserved.
- **Doctor reports drift, sync repairs it:** gone alias, gone source, stale
  copy, undeclared file in `~/.nix/bin`. The drift logic lives in
  bin_exports.zig next to the sync so the two can't disagree.

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

### Secret placeholders in actions (`${secret:NAME}`)

- **Windows Credential Manager only, no cross-platform seam.** Per the
  Windows-first stance, v1 skips macOS Keychain / Linux Secret Service
  entirely rather than building an abstraction for backends nobody's using
  yet. Generic credentials under a flat `nix/<NAME>` target-name namespace,
  `CRED_PERSIST_LOCAL_MACHINE`. advapi32 is lazy-loaded (`LoadLibraryA`/
  `GetProcAddress`, like winpath.zig's registry calls and clipboard.zig's
  user32 calls) so the rare `--secret` call doesn't tax every invocation's
  startup.
- **One choke point, not one per call site.** Expansion happens inside
  `run.zig`'s `runShellString`, which both `cmdRun` (`r <alias> :name`) and
  the group fan-out (`cmd_groups.zig`) funnel through — foreground and
  `--outside` alike — so every named-action path is covered by a single
  `expandSecrets` call. Literal ad-hoc commands (`r <alias> <cmd>` without a
  leading `:`) are deliberately untouched; placeholders are a named-actions
  concept.
- **Placeholder-safety needed no extra code.** Listings (`r <alias> :`),
  `--export`/`--import`, and `[notify]` messages all read the raw action
  string or build their own message text — none of them touch
  `expandSecrets` — so they show the literal `${secret:NAME}` text or nothing
  at all, by construction, not by a special case.
- **Interactive no-echo prompt only** for `nix --secret set NAME` — no
  stdin/pipe input path in v1. Requires a real console (`GetConsoleMode`
  failing, e.g. piped stdin, is a hard error, not a silent fallback).
- **Deferred:** a `--doctor` check for actions referencing a missing secret —
  `doctor.zig` doesn't walk per-alias `.nix/actions.toml` files today, so
  this is new surface, not a small addition.

### Context sources (`run` in `[[contexts]]`)

- **One `[[contexts]]` key, no discriminator.** `run = "set_vars ${task}"` is
  self-describing; a `source = "script"` alongside it would be a key with one
  legal value. A second source kind can add the discriminator later — the
  segments reader is lenient, so new keys are additive.
- **The script returns through `$NIX_CONTEXT_OUT`, never stdout.** A `.cmd`
  without `@echo off`, or any tool it invokes printing a banner, would
  otherwise inject variables — and these variables become a directory that
  gets built in. stdout is relayed to stderr instead, which also keeps the
  resolved path on nix's own stdout clean for shell wrappers. (GitHub Actions
  made this same migration away from `::set-env`.) A leading UTF-8 BOM is
  stripped, because Windows PowerShell 5.1's `Out-File -Encoding utf8`
  writes one.
- **Two variable phases, one precedence order.** The `run` line sees the inline
  value, the environment, and `[contexts.vars]`; `source-template` additionally
  sees what the script produced. This is what lets `run = "set_vars ${task}"`
  receive the `123` in `task:123@project`. Both phases resolve names the same
  way (`resolve.SegLookup` and `context.expandArgv` are kept in step
  deliberately) — a name meaning one thing in the command and another in the
  path it produces would be a vicious bug. Tokens split before `${}` expands
  (as in `nav.buildTerminalArgv`), so a value with spaces stays one argument
  and cannot inject extra ones.
- **`[contexts.vars]` ranks BELOW the environment**, so a default can be
  overridden per shell (`region=us-east o thing@proj`) without editing config.
  The accepted cost is that a leftover environment variable silently changes
  where you land; the guidance is to keep var names specific and avoid ones the
  OS already defines.
- **`run` is a bare script name**, resolved through `run.resolveScript`
  (project `.nix/scripts`, then central) so a context script is just a project
  script, with `.ps1` wrapping inherited for free.
- **Cache key = `sha(expanded argv) + sha(script)`.** Every input that mattered
  is in the expanded argv by construction — no dependency declarations, and it
  self-maintains when the run line changes. Deliberately NOT keyed on the
  alias, so the same lookup from two projects is one answer; that also keeps
  the key correct when named producers land (issue #3). Per-context `cache`
  TTL, default 10m, `"0"` disables. A cache that cannot be written is not
  fatal.
- **Trust is content, not filename.** A `.nix/segments.toml` arrives with a
  `git clone`, so a context declared outside `~/.nix` may not execute until
  `nix --trust <alias> [segment]` records `sha(declaration) + sha(script)`.
  Hashing BOTH closes the hole where a pull rewrites only the script and the
  approved filename still points at it. Implicit trust only when declaration
  AND script both live under `~/.nix` — a central declaration pointing at a
  cloned script is still cloned code. Refusal prints what to review and exits;
  it never prompts inline, since resolution happens inside fzf pickers and
  agent `--resolve` calls.
- **Only produced variables export to the child**, not `[contexts.vars]` —
  those stay template inputs, as they were before this feature.
- **Trust is checked BEFORE the cache.** A cached value is legitimate (an
  approved run of that exact command produced it), but letting a hit skip the
  gate would make refusal depend on cache state — the same untrusted
  declaration working or not depending on what you looked up earlier. The gate
  has to mean one thing. `locate` already hashes both files for the cache key,
  so the check costs one extra read of `trusted.toml`.

### Named producers (`[[producers]]` + `uses`, issue #3)

- **Splits the two jobs a context block was doing:** producing facts (org-wide,
  the same lookup from every repo) and shaping a path (project-local). Named
  producers make the reusable half reusable; without it, a second project meant
  duplicating the `run` line and the script wiring.
- **The producer owns the command, the context owns the values.** A producer's
  `run = "set_vars ${task}"` expands in the CALLING context's variable scope,
  so no parameter-passing mechanism was needed. A context's `cache` overrides
  the producer's; an inline `run` wins over `uses`, so a command written on the
  context is never silently ignored.
- **`Source` is the one shape.** An inline `run` and a producer collapse to
  `{label, run, cache, origin}` in context.zig, so locate/run/trust have a
  single code path and the split added no second one.
- **Trust follows the PRODUCER's declaring file**, since that is what holds the
  command. A project file containing only `segment`/`uses`/`source-template` is
  inert data — it can only invoke producers the machine owner declared, with
  values the user typed, into a path `guardFragment` fences — so it needs no
  approval. A repo shipping its own `[[producers]]` with a `run` line still
  goes through the ledger.
- **The cache is shared across aliases** as a direct consequence of keying on
  the expanded command line rather than the alias: two projects asking the same
  question pay for one lookup.
- **Still deferred:** `uses = [...]` (multiple producers per context) and var
  accumulation along a segment chain (`task:123@sprint:7@project`). The latter
  stays speculative until a real two-axis workflow shows up; it can land later
  as pure behaviour with no schema change.

---

## Backlog

Nothing queued right now.
