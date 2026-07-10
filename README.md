# nix

A directory alias manager for the command line. Give a project a short name once, then jump to it, search it, run commands in it, or move files in and out of it from any prompt — `o acme` and your shell is at the project root.

One TOML file holds every alias, one binary serves every command. State lives in `~/.nix` (`aliases.toml`, `groups.toml`, `config.toml`, usage data, and the segment / action / script files); override the location with `$NIX_HOME`.

## Demos

**Jump to any project.** `o acme` stacks a shell rooted at the alias directory; `o newproj C:\path` registers a new alias and jumps there in one step (the directory is auto-created).

![o navigation](assets/navigate.gif)

**Search inside PDFs, office docs and archives.** `sg <alias> <pat> --all` runs the search with [ripgrep-all](https://github.com/phiresky/ripgrep-all) — matches found *inside* documents become individual, content-filterable fzf rows; pick one and it opens in your editor (text) or its default app (PDF).

![sg --all (ripgrep-all document search)](assets/sg-all.gif)

**Clipboard → file from any prompt.** `p <alias> [name]` drops the clipboard into the alias directory — a screenshot saves as `.png`, text as `.md`, Explorer-copied files/folders copy in recursively — and copies the saved path back out.

![p paste (clipboard to file)](assets/paste.gif)

## Install

### Windows (Scoop)

```powershell
scoop bucket add sadirano https://github.com/sadirano/bucket
scoop install nix
```

The Scoop package pulls in the tools the interactive commands lean on (`bat`, `fzf`, `ripgrep`, `fd`, `neovim`) and runs `nix --init` for you on install. `scoop update nix` tracks new releases; `scoop install sadirano/nix-nightly` tracks a daily build of `main` instead.

[Everything](https://www.voidtools.com/)'s `es` CLI is an optional extra (`scoop install everything-cli`): with it the `o <name>` picker gets instant, whole-system reach across every drive; without it the picker walks your drives with `fd` (tunable under `[picker]`).

### Prebuilt binaries

Each tagged release publishes a Windows `.zip` on the [Releases](https://github.com/sadirano/nix/releases) page — download, unpack, put `nix.exe` on your `PATH`, then run `nix --init`.

### Build from source

Requires [Zig 0.16+](https://ziglang.org/download/).

```powershell
zig build -Doptimize=ReleaseFast    # -> zig-out\bin\nix.exe
zig-out\bin\nix.exe --init
```

On Windows, prefer the portable build helper — a native build bakes the dev machine's CPU extensions into the binary and crashes with an illegal instruction on any machine lacking them:

```powershell
.\nix-build.cmd        # zig build … -Dtarget=x86_64-windows -Dcpu=baseline, then --sync
```

`nix --init` creates `~/.nix/`, installs the `.exe` command wrappers into `~/.nix/bin`, and adds that dir to your user PATH — restart your shell once and the short commands below are live in every shell (PowerShell, cmd, anything). It never touches your shell profile. A snippet is also written to `~/.nix/shell/` for the one thing PATH can't give you — alias tab completion in PowerShell — and `--init` prints the one-liner to dot-source it from `$PROFILE` if you want that. (On Unix-likes the snippet *is* the integration — shell functions that cd in place — so there you add the printed line to `.bashrc`/`.zshrc` yourself.)

## Use

```powershell
nix acme C:\Users\dev\projects\acme        # register an alias (auto-creates the dir if missing)
o acme                                     # jump to it
o acme C:\Users\dev\projects\acme          # register + jump in one step (dir auto-created)
o                                          # no args: open ~/.nix in your editor
e acme                                     # open it in your editor
s acme                                     # open it in Explorer
s acme report.pdf                          # open a file with its default app (PDF→viewer, .zip→archiver…)
s acme invoice                             # pick files (fzf) → open each with its default app
y acme                                     # print the path and copy it to the clipboard
y acme invoice                             # pick files (fzf) → copy the FILES to the clipboard
p acme                                     # save clipboard content into the alias dir, copy the saved path back
p acme shot                                # …with a name (image→shot.png, text→shot.md)
r acme zig build test                      # run a command at that path
sg acme TODO                               # ripgrep search under the dir → fzf → open the hit in your editor
sg acme invoice --all                      # search inside PDFs/office docs/archives too (ripgrep-all)
ff acme config                             # fuzzy-find files under the dir → fzf → open the selection
o docs@acme                                # jump to a sub-alias segment (see Sub-aliases below)
nix --list                                 # show every alias
nix --which                                # print the alias containing the cwd (reverse of resolve)
nix --edit                                 # open ~/.nix in your editor
nix acme --remove                          # forget the alias
```

An unknown name after `o` runs the directory picker (`es`/`fd` + fzf): pick a directory and it's registered and entered in one step.

On Windows every command is a standalone `.exe` wrapper, so they all work from any prompt with no shell glue; `o` stacks a new shell rooted at the target (with the project's `.nix/scripts` on PATH — exit it to land back where you were). On Unix-likes `o` is a shell function that cd's your current shell in place.

Clipboard fine print: `y <alias> <pat>` copies the picked files as a real file drop (Windows `CF_HDROP`; elsewhere it falls back to paths as text) — the inverse of `p`. `p` gives Explorer-copied files priority over text/image content (directories copy recursively), honours an explicit extension on `<name>`, and auto-increments on collision (`shot.png`, `shot-1.png`) so nothing is ever clobbered.

## Search and find

`sg` streams every ripgrep match into fzf as its own content-filterable row, with a live `bat` preview; Tab marks several, Enter opens the selection(s) in your editor at the matched line. `sg <alias> <pat> --all` (or `-a`) searches with [ripgrep-all](https://github.com/phiresky/ripgrep-all) (`rga`) instead, so matches reach **inside PDFs, office documents, archives, ebooks, and more** — the preview shows the extracted text, and a document hit opens in its default app (its "line" is really a page, not an editor position). Set `[grep] all = true` in `config.toml` to make `rga` the default for every `sg`.

`ff` shares the same fzf-with-preview picker, choosing its file lister by what's available — Everything's `es` on Windows, else `fd`, else `find`. Enter opens directories and default-app file types (PDF, images, archives, …) with the OS handler, everything else in your editor.

## Configuration

Aliases live in `~/.nix/aliases.toml`. The format is one TOML table per alias:

```toml
[acme]
path = "C:/Users/dev/projects/acme"
```

You can hand-edit the file (`nix --list` and resolve pick up changes immediately) or use `nix <name> <path>` to register and `nix <name> --remove` to forget. Alias lookups are case-insensitive.

Editor is taken from `$EDITOR`, then `$VISUAL`, then the first of `nvim`, `vim`, `code`, `nano`, or `notepad` found on PATH. Override the home location with `$NIX_HOME`.

`~/.nix/config.toml` holds the optional sections.

`[shortcuts]` renames the built-in command functions. The keys are the built-in names (`o`, `e`, `s`, `y`, `p`, `r`, `sg`, `ff`); the value is the name you'd rather type:

```toml
[shortcuts]
s = "show"     # type `show acme` instead of `s acme`
ff = "fzf"
```

`[grep]` sets the `sg` default — `all = true` makes every search run `rga`; the per-run `--all`/`-a` flag flips a single search either way:

```toml
[grep]
all = true
```

`[picker]` filters the unknown-alias directory picker (Everything `es` + fzf), which `o` runs in-process when you navigate to a name that isn't an alias yet. By default it excludes any path component starting with `.`, `_`, or `[`, plus dependency/build/cache trees (`node_modules`, `site-packages`, `cache`, `bin`, `obj`, `build`, `dist`, …), the Windows system trees (`C:\Windows\`, `C:\Program Files`, `AppData`, …), and store-owned install trees (`scoop\apps`, `steamapps`) — so the result cap is spent on directories worth picking.

Setting `exclude` replaces the default list entirely (`exclude = []` turns filtering off); `exclude_extra` extends it — the place for machine-specific noise (TOML literal strings save the backslash-doubling):

```toml
[picker]
exclude_extra = ['\XboxGames\', '\Engine\']
```

Without a working `es` (not installed, or the Everything service isn't running), the picker falls back to walking a set of roots with `fd` (then POSIX `find`), listing directories whose path contains the typed name — a dead `es` falls through transparently. `search_roots` lists those roots (`~` is expanded); unset, it defaults to **every fixed drive** on Windows (your home directory elsewhere), pruning the OS trees so a whole-drive walk stays quick. Point it at the trees your projects actually live in to narrow and speed it up:

```toml
[picker]
search_roots = ['~/projects', 'D:\work']
```

After editing, run `nix --sync` and restart your shell to pick up renamed shortcuts or picker changes.

## Sub-aliases (`@`-segments)

Append subdirectory shortcuts to any alias with `@`. Each segment is defined as a `[[contexts]]` entry, resolved by searching three places, first match wins:

1. **Per-alias, local:** `<alias-path>/.nix/segments.toml`
2. **Per-alias, central:** `~/.nix/segments/<alias>.toml`
3. **Global:** `~/.nix/segments.toml` — but only entries marked `scope = "global"` are visible here.

```powershell
o docs@acme              # cd into <acme-path>/documentation
e src@acme               # editor at <acme-path>/source
o tasks:432@acme         # inline value: cd into <acme-path>/tickets/432
o client:bob@projb       # multi-segment, innermost first
```

```toml
# ~/.nix/segments.toml — entries in the global file must opt in with scope = "global"
[[contexts]]
segment = "docs"
scope = "global"
source-template = "/documentation"   # leading `/` makes it a subdirectory

[[contexts]]
segment = "tasks"
scope = "global"
source-template = "/tickets/${tasks}"   # ${tasks} binds to the inline value
```

Per-alias files need **no** `scope` — every entry there is implicitly scoped to that alias. Only the shared global file requires the opt-in.

A segment resolves through its `source-template`: a string with `${VAR}` references. For each `${name}`, nix looks up, in order, (1) the segment's inline value (`seg:value`), bound under `${<segment>}` — or `${param}` if the context sets `param`; (2) the context's `env` map; (3) the process environment. Templates own their separators — `"/foo"` appends as a subdirectory, `"_${task}.md"` appends as a filename suffix.

Encountering an unknown segment defines it for you (seeded with a `[[contexts]]` skeleton in the central per-alias file). Lookups are case-insensitive, and `nix --contexts` prints the contexts defined in the global `~/.nix/segments.toml`.

## Groups (`+` multi-alias)

A **group** is a named set of aliases, kept in `~/.nix/groups.toml`. Use it to jump to several projects at once, or to fan a search/run/yank across all of them. Groups are referenced with the `+` sigil — and because of that, `+` is not allowed in alias names.

```powershell
o pa+work                # add alias `pa` to group `work` (creates it), then navigate
o +work                  # pick members in fzf: the first selection cd's the current
                         #   shell, each additional selection opens a new terminal
sg +work TODO            # ripgrep across every member's dir, into one fzf picker
                         #   rows read `member\rel\path`, not the absolute root
ff +work config          # fuzzy-find files across every member
r  +work git pull        # run a command in each member dir (per-dir header)
s  +work                 # open every member dir in the file manager
s  +work invoice         # pick files across every member → open with default apps
y  +work                 # copy every member path to the clipboard
y  +work invoice         # pick files across every member → copy the FILES
p  +work                 # pick ONE member (fzf) → paste the clipboard there
nix +work --resolve      # print every member path, one per line
nix --groups             # list all groups
nix +work --list         # list a group's members (each resolved to its path)
nix pa+work --remove     # drop a member
nix +work --remove       # delete the group
```

Members are **alias names**, resolved on use — move an alias and its groups follow; a member whose alias was removed is skipped with a note (and `nix <alias> --remove` strips it from every group). A group may contain another group as a `+other` member, expanded recursively (cycles and runaway nesting are guarded). The file is flat and hand-editable:

```toml
work = ["pa", "pb"]
all  = ["+work", "pc"]   # nested
```

When `o +group` opens more than one selection, the **first** keeps the current shell and the rest each launch a new terminal via `[nav] terminal` in `config.toml` — a command template with a `{dir}` placeholder. On Windows this defaults to `wt -d {dir}` (falling back to a `start` console window); elsewhere set it explicitly:

```toml
[nav]
terminal = "wezterm start --cwd {dir}"
```

## Per-alias actions

Save named commands per alias and run them from anywhere with `r <alias> :<name>` — like `package.json` scripts, but language-agnostic. Actions are plain shell strings (so `&&`, pipes, and redirects work), run in the alias directory.

```toml
# <alias-dir>/.nix/actions.toml   (commit it with the project)
[actions]
test   = "zig build test"
serve  = "npm run dev"
deploy = "./scripts/build.sh && rsync -a dist/ host:/srv"
```

```powershell
r acme :test         # run acme's `test` action in acme's dir
r acme :             # list acme's actions
r acme -o :serve     # run the action detached, in a new window
r +work :test        # run each member's own `test` action (members without it are skipped)
```

Actions resolve from two places, **project-local winning**: `<alias-dir>/.nix/actions.toml` (travels with the repo) overrides `~/.nix/actions/<alias>.toml` (private, per-machine). A leading `:` is what marks a saved action — without it, `r <alias> <cmd>` still runs `<cmd>` literally.

For full scripts rather than one-liners, drop an executable in the alias's `.nix/scripts/` (or the central `~/.nix/scripts/`) and run it by bare name — `r acme build` runs `<acme>/.nix/scripts/build.cmd`. The scripts dir is put on `PATH` in any alias context, so a project `build` shadows a global one, scripts can call each other, and — best of all — **inside an `o acme` shell the project's own `build`/`clean`/… just work as commands**, with no global versions and scoped to that shell (exit it and they're gone). It fans out too: `r +work build` runs each member's own script. Project-local first, then central; on Windows the extension (`.cmd`/`.bat`/`.exe`/`.ps1`) is resolved for you.

## Tab completion

Every command that takes an alias (`o`, `e`, `s`, `y`, `p`, `r`, `sg`, `ff`) supports tab-completion of alias names. The completer calls `nix --list-names` under the hood — a dedicated path that bypasses TOML parsing so Tab stays instant.

Completion is opt-in and PowerShell-only: dot-source `~/.nix/shell/nix.ps1` from your `$PROFILE` (the `--init` output shows the exact line). The commands themselves work in any shell via PATH.

## AI agents

`nix --init` also writes `~/.nix/AGENTS.md`, a short guide that teaches coding agents your command surface — so they say "run it with `r acme :test`" instead of quoting absolute paths, register repeatable commands as actions, and know to resolve with `nix <alias>` rather than `o` in their own non-interactive shells. `nix --sync` regenerates it, so the guide always shows your effective `[shortcuts]` names.

nix never registers the file with any agent itself — wiring it up is a deliberate, per-user step. For Claude Code, import it from your global memory file, `~/.claude/CLAUDE.md`:

    @~/.nix/AGENTS.md

Other tools can point at the same file wherever they take custom instructions.

## Commands

`nix --init` (covered under Install) is idempotent — re-run it any time. `nix --sync` regenerates the shell snippet, the agent guide, and the command wrappers after you move the binary or edit `config.toml`. `nix --version` prints the build version and OS/arch. `nix --help` lists everything.

`nix --prune` cleans a crusty alias list: an fzf multi-select of every alias ranked prune-first — dead targets (directory gone), then never-used, then least-recently used. Tab marks, Enter removes the marked aliases, Esc cancels; `--no-prompt` just prints the ranking. The ranking comes from `~/.nix/usage`, a small file the resolve paths maintain automatically (debounced to at most one write per alias per hour; delete it any time to start fresh). Group fan-outs are charged to the group itself — a `+name` key in the same file — never to the members, so an alias's own frecency only moves when you use it directly. Prune still won't ambush you: members of a recently used group inherit its recency in the ranking, marked `(via +group)`, so an alias you only ever reach through `r +work …` doesn't rank as never-used.

`nix --sweep` finds picker noise you didn't think of: it scans the whole Everything index for directories with 100+ unfiltered subfolders (`--min N` tunes the threshold) and offers the worst offenders in an fzf multi-select. Enter appends the marked subtrees to `~/.nix/picker.swept` (a third exclusion layer, one fragment per line); `--no-prompt` just prints the ranking. Directories containing a registered alias target are never offered.

`nix --export [file]` writes a portable backup of your aliases, groups, `config.toml`, and central per-alias actions as one TOML document (to stdout when no file is given; the machine-local `usage` ranking is left out). `nix --import <file>` restores one: by default it **merges**, adding only alias/group/action names you don't already have and never overwriting your `config.toml`, so re-importing is safe. `nix --import <file> --replace` does a deliberate full restore instead — aliases, groups, and config are replaced from the file, and each alias's central actions file is overwritten. Together they cover backup, moving your setup to a new machine, and recovering after a `~/.nix` mishap.

`nix --doctor` (`-D`) is a read-only health check for when the `o <name>` picker misbehaves: build and wrapper state (stale wrappers, `~/.nix/bin` missing from PATH), which finder the picker will actually use and why, the resolved search roots, the optional tools (`bat`/`rg`/`rga`/editor), and your config/alias state. It exits non-zero if any core check fails, so `nix --doctor && …` works in scripts.

`nix --which [path]` (`-w`) is resolve in reverse: it prints the alias whose directory contains the path (default: the current directory), deepest registered dir winning — made for prompts and status-line scripts that want to show "where am I, in alias terms". It's strictly read-only (no usage recording, no dir creation) and exits non-zero with empty stdout when no alias contains the path, so it's cheap and safe to poll. Often you don't even need it: every alias context nix starts — the `o <alias>` subshell, `r <alias> <cmd>`, a `:action`, group fan-outs — already carries `NIX_ALIAS` (the alias name) and `NIX_ALIAS_PATH` (its directory) in the environment, computed once at launch.

## License

MIT.
