# AGENTS.md

Contributor guide for working **on** nix - build, test, and the architecture that
takes several files to see. Coding agents read this file automatically; humans
are the other audience, and nothing here is written only for a machine.

> Not to be confused with `~/.nix/AGENTS.md`, which nix *generates* on
> `--init`/`--sync` (see `src/agents.zig`). That one teaches an agent the
> command surface of a machine where the user installed nix. This one is scoped
> to this repository and travels with it, the way any contributor doc does.

## What this is

`nix` is a directory alias manager for the command line (Zig 0.16+, Windows-first).
One TOML file holds every alias; one binary serves every command. State lives in
`~/.nix` (override with `$NIX_HOME`).

## Build, test, run

The repo is registered as a nix alias itself, so the saved actions in
`.nix/actions.toml` are the shortest forms (`r <alias> :build`, `:sync`, `:ci`,
`:checklist`). The raw commands:

```powershell
zig build                                  # -> zig-out\bin\nix.exe (native)
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows -Dcpu=baseline
zig build test                             # unit tests (both modules)
zig build e2e                              # end-to-end harness vs the built exe
zig build ci                               # everything CI runs, in CI's order
zig build deploy                           # build, then --sync into ~/.nix/bin
zig build run -- --list                    # run the freshly built exe
```

- **Always use the portable flags for anything a user will run.** A native build
  bakes the dev machine's CPU extensions in and dies with an illegal instruction
  elsewhere; that is what broke a Scoop install once.
- **`zig build ci` is the gate**, and `.githooks/pre-push` calls it
  (`git config core.hooksPath .githooks` enables it; `NIX_SKIP_PREPUSH=1` skips
  one push). It runs, in order: `zig fmt --check`, the release-script selftests,
  unit tests, e2e, the portable build, and a linux cross-compile canary. Run it
  before pushing so `fix: zig fmt` never becomes a commit again.
- `.github/workflows/ci.yml` deliberately has a single `zig build ci` step. If a
  check moves, build.zig and the workflow move together or it stops being a gate.

### Running a subset of tests

`zig build test` has no filter wired. For a single module, run its test block
directly - every module except `main.zig` and `doctor.zig` is free of the
`build_options` import and compiles standalone:

```powershell
zig test src/env.zig
zig test src/env.zig --test-filter "merge"
```

`zig build e2e` has no filter at all; it drives the real exe as a child process
against a scratch `NIX_HOME` under `%TEMP%\nix-e2e-<ms>`.

### Never test against the real `~/.nix`

Manual runs mutate the user's live aliases, wrappers, and PATH. Point them at a
scratch home first (`$env:NIX_HOME = "$env:TEMP\nix-scratch"`). `--init`,
`--sync`, `--sync-bin` and `--secret` touch the real user PATH, `~/.nix/bin`, and
the Windows Credential Manager, which is why the e2e harness excludes them.

## Architecture

### Multicall binary

The same exe is installed into `~/.nix/bin` under every command name (`o`, `e`,
`s`, `y`, `p`, `r`, `sg`, `ff`) plus any `[shortcuts]` rename, and recovers the
action from `argv[0]` (`main.multicallAction`). With `~/.nix/bin` on the
persistent user PATH there is no shell snippet on Windows; POSIX still gets shell
functions from `snippet.zig`. Consequence for the dev loop: **`zig build` alone
never reaches the binary you actually run** - the wrappers are independent
copies. Use `zig build deploy` (or `:build` then `:sync`).

### Single-source-of-truth tables

Three files exist specifically so parallel copies of the same knowledge cannot
drift. Adding a command means touching them, not just the dispatcher:

- `grammar.zig` - every flag nix accepts, one row per command, feeding both the
  parser and `--help`. `verb` is an enum the dispatcher switches over
  exhaustively, so a row without a handler is a compile error. It imports
  nothing but `std` and must stay at the bottom of the import graph.
- `agentdocs.zig` - one `Spec` per topic renders at three depths: the `--help`
  line, `~/.nix/AGENTS.md`, and `<cmd> --agent` / `nix --agent <topic>`. Every
  grammar row declares which spec topic covers it (`spec: ""` means "help line
  only"), and a test checks both directions.
- `agents.zig` - renders `~/.nix/AGENTS.md` at `--init`/`--sync` time. That
  guide describes a whole *machine*, so it stays an installed artifact and is
  never shipped in a repo: instructions for driving someone's machine have no
  business arriving in a clone. Edit the template here, never the installed file.

### The shared seam

`app.zig` holds `App`, the process-wide context handed to every command
(arena, `Io`, writers, env, home, `--json`/`--no-prompt`/`--force`, plus the
lazily-populated PATH and injected-variable bookkeeping). **Command modules take
`*App` and import `app.zig`, never `main.zig` and never each other.** `main.zig`
is the dispatcher; `root.zig` is the library surface (`refAllDecls` compile-checks
it in `zig build test`) and the exe does not import it.

### Layered configuration, project layer last and gated

Nearly every feature reads three layers, project-local first:

| Feature | project (committed) | central (private) | machine-wide |
|---|---|---|---|
| actions | `<dir>/.nix/actions.toml` | `~/.nix/actions/<alias>.toml` | `~/.nix/actions/_default.toml` |
| env | `<dir>/.nix/env.toml` | `~/.nix/env/<alias>.toml` (wins) | - |
| segments | `<dir>/.nix/segments.toml` | `~/.nix/segments/<alias>.toml` | `~/.nix/segments.toml` (`scope = "global"` only) |

Anything that arrives with a `git clone` - `.nix/actions.toml`, `.nix/scripts/`,
`.nix/env.toml`, a context source's `run` line - passes `provenance.zig` first:
the first run shows the command and asks, and **without a console it refuses**.
An agent's shell is such a console-less case, so an action you just wrote will
not run for you until the user runs `nix --trust <alias>`. That is the gate
working. `--trust` and `--force` are never yours to add.

### Other load-bearing modules

`resolve.zig` (alias -> path, `@`-segments, `+` group expansion) is the hot path
every command enters through. `run.zig` owns `aliasRunEnv`, the single choke
point where env layers, context variables, `NIX_ALIAS`/`NIX_ALIAS_PATH` and the
scripts-dir PATH prepend are injected - and where each is removed before the next
injection so a group fan-out cannot leak one member's environment into the next.
`store.zig` keeps `aliases.toml` byte-for-byte compatible with the older Go
`onix`; groups, actions and env live in their own files rather than polluting it.

## Conventions

- **ASCII punctuation only** in anything a program emits or generates: CLI text,
  help, generated files, commit messages. A Windows console on a legacy code page
  renders an em dash as `ΓÇö`. (The README and COOKBOOK are the exception - they
  are read on GitHub.)
- **Comments explain the decision, not the mechanism.** The existing density is
  high and deliberate: nearly every non-obvious branch carries the failure that
  motivated it. Match it.
- **Commit subjects read as a sentence about behavior**, not a component name:
  `feat: an exported action learns the name it was invoked under`, `fix:
  registering a path never destroys an alias by accident`. Conventional-commit
  prefix, lowercase, backticks around literal syntax, `(#NN)` when it closes an
  issue.
- Work happens directly on `main`; no feature branches. Design decisions live in
  GitHub issues (there is no ROADMAP.md).
- Release: a pre-release tag (`v0.11.0-pre1`) opens the checklist issue, a stable
  tag refuses to publish until every box is ticked (fail-closed, no issue means
  no release), and publishing archives it. `bash .github/scripts/release-checklist.sh status`
  shows what is still open.
