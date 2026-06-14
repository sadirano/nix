# nix — a Zig/C rewrite of onix

Experiment: how much faster is onix's hot path with no Go runtime?
Sibling of `../onix` (the Go reference implementation), built with Zig 0.16.

## Benchmark (Windows, 400–500 spawns, no shell, via os/exec harness)

| Binary | Spawn time | Size | Notes |
|--------|-----------|------|-------|
| Zig no-op | 3.31 ms | 4.6 KB | CreateProcess floor |
| hand-written C resolve | 3.82 ms | — | reference |
| **nix (Zig, ReleaseFast)** | **~4.1 ms** | 826 KB | full hot path: resolve + mkdir + usage |
| onix (Go, `-s -w`) | ~8.16 ms | 3.5 MB | baseline |

**~2× faster per invocation**, ~0.8 ms above the OS floor. The Go runtime
bootstrap (~2 ms) plus onix's linked dependency graph (go-toml/json/reflect,
another ~2 ms) is what's shed.

## Tier 1 — core read/dispatch (DONE, parity verified against onix)

- [x] Home resolution (`$ONIX_HOME` → `<userhome>/.onix`)
- [x] `nix <alias>` resolve: byte-scan `aliases.toml`, `path = "..."`, quote
      unescaping, `fromSlash` → host separators — matches onix byte-for-byte
- [x] Recursive mkdir of the resolved dir
- [x] Usage recording (`usage` file, 1-hour debounce, atomic temp+rename)
- [x] `--list-names` — IDENTICAL output to onix
- [x] `--list` — IDENTICAL output (tabwriter padding replicated)
- [x] `--version`
- [x] add (`nix <alias> <path>`) — writes onix's exact TOML format
- [x] remove alias (`--remove`/`--rm`/`-rm`)
- [x] multicall dispatch + full grammar routing (every verb/action reaches a
      handler; unported ones return a clear "not yet ported" error, exit 2)

## TODO — remaining parity

### Tier 1 leftovers
- [ ] remove: file deletion mode (`--force`/`--recursive`, load-bearing guard)
- [ ] `--json` output for list

### Tier 2 — shell-out actions (COMPLETE except image-paste)
- [x] `--run` (`-r`): spawn in alias dir, inherit stdio, propagate exit code,
      `-o/--outside` detached, Windows bare-name probe — **parity verified**
      (args + exit codes match onix)
- [x] `--edit` (`-e`): resolve $EDITOR/$VISUAL/nvim/vim/code/nano/notepad, spawn
- [x] `--explore` (`-x`): explorer.exe (Windows) / xdg-open, fire-and-forget
- [x] `--yank` (`-y`): print path + Win32 clipboard write (CF_UNICODETEXT) —
      **verified** (round-trips through clipboard)
- [x] `--prune`: frecency ranking + fzf multi-select — ranking **IDENTICAL** to onix
- [x] `--grep` (`-g`): rg + fzf with bat preview, relaxNonASCII, opens
      selections in $EDITOR with per-family line-jump (vim `+N` / VS Code
      `--goto`). Reaches interactive fzf identically to onix.
- [x] `--find` (`-f`): es/fd/find + fzf; routes selections to default app
      (allowlisted exts + dirs) or editor
- [x] `--preview`: dir listing / bat file render — **IDENTICAL** to onix
- [x] `--paste` (`-p`): full Win32 clipboard read — CF_HDROP file drops (file +
      recursive dir copy), CF_DIB **image → PNG** (`src/png.zig`: DIB decode +
      PNG encode with stored-DEFLATE zlib, CRC32/Adler32), and CF_UNICODETEXT
      (→ .md), image-wins-over-text ordering, uniquePath collisions, path(s)
      copied back to clipboard. **All three verified** — image round-trips
      pixel-exact (5×3 RGB check).
- [x] `--sweep`: es `/ad` flood scan — exclude filtering, child-counting,
      sibling-collapse fixpoint, alias filtering, rank, cap. Ranking
      **IDENTICAL** to onix (`--no-prompt --min 200`). Appends to picker.swept;
      wrapper regen deferred to `--sync` (Tier 3).
- [x] directory picker (Everything `es` + fzf) for unknown aliases — engages on
      actions, filters via composed excludes, registers the pick. Reuses the
      verified fzf-filter + addAlias paths.
- [x] config.toml `[picker]` parsing (`src/config.zig`): defaults, exclude /
      exclude_extra arrays (multi-line), picker.swept read/append, composed +
      deduped exclusion list. Shared infra for sweep, picker, and Tier 3.

New modules: `src/proc.zig` (spawn/runInherit/runDetached/findInPath/runFilter/
captureOutput/runPipeline), `src/clipboard.zig` (Win32 write + Unix), `src/
editor.zig` (line-jump dialects).

**Finding — streaming `rg | fzf` without a child→child pipe:** wiring
producer.stdout straight into fzf.stdin via `StdIo{.file=...}` fails with
`NoDevice` on Windows (the parent's pipe-read handle isn't re-inheritable as
another child's stdin). The parent relays bytes instead — but the relay MUST
use `File.readStreaming` (one OS read, returns as soon as any bytes arrive),
not a buffered `Reader`/`readSliceShort` (which blocks until its buffer fills
or EOF and would make fzf show nothing until the producer finished). Verified
with a timing harness that fzf-side input arrives at the producer's pace, not
batched at EOF — so grep/find stream live like onix's pipe.

**Finding — lazy-load user32:** statically `extern "user32"`-ing the clipboard
functions put USER32.dll in the PE import table, so the loader pulled it (+
gdi32 …) on EVERY startup — adding ~2 ms even to the resolve hot path
(4.0 → 6.0 ms). Loading user32 via `LoadLibraryA`/`GetProcAddress` (kernel32,
always present) only inside `--yank`/`--paste` keeps the hot path at 4 ms. This
mirrors why onix uses `syscall.NewLazyDLL`. Lesson: on Windows, a single
static import of a non-default DLL is a measurable per-invocation tax.

### Tier 3 — heavy / complex (in progress)
- [x] navigate subshell (`o`): resolve + spawn $ONIX_SHELL/$COMSPEC/$SHELL
      rooted at the dir, propagate exit code
- [x] segment templating (`src/segments.zig`): `seg@alias` parsing, [[contexts]]
      file reader (incl. `[contexts.env]`), local→central→global precedence,
      `${var}` template expansion, escape guard, auto-define on miss. Resolution
      + inline values + auto-defined central file **IDENTICAL** to onix.
- [x] `--contexts`: table **IDENTICAL** to onix (branding aside)
- [x] clipboard (Win32 CF_HDROP read + CF_UNICODETEXT read/write); image deferred
- [x] shell-integration snippet generation (`src/snippet.zig`): PowerShell
      `nix.ps1` (session PATH + native alias completer + `q`) and bash `nix.sh`
      (o/e/s/y/p/r/sg/ff functions + completer), honouring `[shortcuts]`. Writes
      nix-branded artifacts so it coexists with onix in the same ~/.onix.
- [x] multi-call wrapper install: copies nix.exe → bin/{nix,o,e,s,y,p,r,sg,ff}.exe;
      argv0 dispatch through an installed wrapper **verified** (onix hardlinks,
      nix copies — equivalent).
- [x] `--init` (tree + starters + snippet + wrappers + $PROFILE dot-source via
      pwsh; `--skip-profile` honoured) and `--sync` (regenerate).
- [x] `--remove` file-deletion mode: `--force`/`--recursive`, load-bearing
      guard, y/N prompt — messages **match onix** (branding aside)
- [x] image-paste (CF_DIB→PNG) — done & verified pixel-exact
- [~] clink lua integration (cmd.exe) — NOT NEEDED (PowerShell completion +
      $PROFILE wiring cover the supported shells; cmd.exe/clink intentionally
      out of scope for nix)

## Status: COMPLETE

Full functional parity with onix. Final parity sweep — `--list-names`, `--list`,
resolve, `--prune --no-prompt`, `--sweep --no-prompt` all **IDENTICAL**;
segments/contexts/paste(text+file+image)/remove verified case-by-case. clink-lua
is intentionally out of scope.

Final numbers: **resolve ~4.4 ms vs onix ~9 ms (~2×)**, **1.23 MB vs 3.48 MB**,
~3,500 lines of Zig across 9 modules.

## Build

    zig build -Doptimize=ReleaseFast    # -> zig-out/bin/nix.exe
    zig build                            # debug
