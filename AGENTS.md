# AGENTS.md

Contributor guide for working on nix, a directory alias manager (Zig 0.16+,
Windows-first). Not the generated `~/.nix/AGENTS.md`, whose template lives in
`src/agents.zig`. Architecture detail (multicall, the single-source tables,
config layers, load-bearing modules) is in `docs/agent-notes.md`: read the
relevant section before changing a subsystem.

## Build and test

- `x nix :deploy` builds and syncs into `~/.nix/bin`. `zig build` alone never
  reaches the binary you run, because the wrappers are copies.
- **Portable flags for anything a user runs:**
  `-Doptimize=ReleaseFast -Dtarget=x86_64-windows -Dcpu=baseline`.
- **`zig build ci` is the gate** (fmt, release selftests, unit, e2e, portable
  build, linux canary). Run it before pushing. build.zig and
  `.github/workflows/ci.yml` move together.
- For a single module: `zig test src/env.zig --test-filter "merge"`.
- **Never test against the real `~/.nix`.** Set
  `$env:NIX_HOME = "$env:TEMP\nix-scratch"`. `--init`, `--sync`, `--sync-bin`
  and `--secret` touch the real PATH and Credential Manager. Set
  `$NIX_CLIPBOARD_FILE` for anything that yanks.

## Invariants

- Adding a command means touching `grammar.zig` (every flag), `agentdocs.zig`
  (the spec per topic) and, for the machine guide, `agents.zig`, not just the
  dispatcher.
- Command modules take `*App` and import `app.zig`, never `main.zig` and never
  each other. `grammar.zig` imports only `std`.
- Anything arriving with a clone passes `provenance.zig`, and without a
  console it refuses. `--trust` is the user's, never yours.
- `run.aliasRunEnv` is the one env-injection choke point. Each injection is
  removed before the next.
- TOML goes only through `toml.zig`: `unquote` for strings, `unquoteLoose`
  for command lines (backslashes stay literal).

## Conventions

**Docs and comments state facts, never stories.** Write what nix does and the
rule behind it. No anecdotes ("broke a Scoop install once"), no invented or
one-off numbers ("43 of 100 rows"), no rhetoric ("the fastest known way
to..."), no history of what the code used to do. A claim the code or a test
can't back gets cut, not softened.

ASCII in anything emitted (the README and COOKBOOK are exempt). Comments
explain the decision. Commit subjects are a sentence about behavior
(`feat: ...`, `(#NN)` when closing an issue). Work on `main`. Design lives in
GitHub issues. Releases use the fail-closed checklist
(`bash .github/scripts/release-checklist.sh status`).
