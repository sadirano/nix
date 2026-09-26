# The nix Guide

From the first alias to fully wired workflows: everything nix can do, organized
by how far you want to take it. Each level builds on the one before, but every
level is useful on its own - plenty of people never go past Level 2.

The [README](../README.md) is the reference: exact semantics, edge cases and the
reasoning behind each decision. The [Cookbook](../COOKBOOK.md) collects small
copy-paste recipes. This guide is the path between them: *what to use, when,
and how the pieces combine*.

All examples use an alias named `acme` for a project at `C:\code\acme`.
Commands are shown with their default one-letter names; if you renamed them
under `[shortcuts]` (see [1.9](#19-rename-the-commands)), substitute yours.

---

## Contents

- [0. The mental model](#0-the-mental-model)
- [Level 1 - Daily driving](#level-1---daily-driving)
  - [1.1 Set up once](#11-set-up-once)
  - [1.2 Name your places](#12-name-your-places)
  - [1.3 Jump: `o`](#13-jump-o)
  - [1.4 Open: `e` and `s`](#14-open-e-and-s)
  - [1.5 Search and find: `g` and `f`](#15-search-and-find-g-and-f)
  - [1.6 The clipboard: `y` and `p`](#16-the-clipboard-y-and-p)
  - [1.7 Run something there: `x`](#17-run-something-there-x)
  - [1.8 Close the shell: `q`](#18-close-the-shell-q)
  - [1.9 Rename the commands](#19-rename-the-commands)
  - [1.10 Housekeeping](#110-housekeeping)
- [Level 2 - Saved actions](#level-2---saved-actions)
  - [2.1 Your first actions file](#21-your-first-actions-file)
  - [2.2 Running, listing, picking](#22-running-listing-picking)
  - [2.3 Arguments and `{args}`](#23-arguments-and-args)
  - [2.4 Chains](#24-chains)
  - [2.5 Detached windows: `-o`](#25-detached-windows--o)
  - [2.6 The three layers of actions](#26-the-three-layers-of-actions)
  - [2.7 Shell-specific actions](#27-shell-specific-actions)
  - [2.8 Scripts in `.nix/scripts/`](#28-scripts-in-nixscripts)
  - [2.9 The palette: every action on the machine](#29-the-palette-every-action-on-the-machine)
  - [2.10 Administrator actions](#210-administrator-actions)
- [Level 3 - Per-project environment and secrets](#level-3---per-project-environment-and-secrets)
- [Level 4 - Sub-aliases and computed paths](#level-4---sub-aliases-and-computed-paths)
  - [4.1 Static segments](#41-static-segments)
  - [4.2 Inline values](#42-inline-values)
  - [4.3 Wildcards: the folders decide the path](#43-wildcards-the-folders-decide-the-path)
  - [4.4 Context sources: a script decides the path](#44-context-sources-a-script-decides-the-path)
  - [4.5 Menus](#45-menus)
  - [4.6 Named producers](#46-named-producers)
  - [4.7 The `shared@` drop](#47-the-shared-drop)
- [Level 5 - Global commands (`[bin]` exports)](#level-5---global-commands-bin-exports)
- [Level 6 - Automation and integration](#level-6---automation-and-integration)
  - [6.1 Completion notifications](#61-completion-notifications)
  - [6.2 Pinned shortcuts that don't lie](#62-pinned-shortcuts-that-dont-lie)
  - [6.3 Scripting nix: `--no-prompt`, `--list-names`, `--which`](#63-scripting-nix---no-prompt---list-names---which)
  - [6.4 Path dialects: `--as`](#64-path-dialects---as)
  - [6.5 Your prompt knows where you are](#65-your-prompt-knows-where-you-are)
  - [6.6 The time ledger](#66-the-time-ledger)
  - [6.7 AI coding agents](#67-ai-coding-agents)
- [Level 7 - Complete workflows](#level-7---complete-workflows)
- [The trust model, in one page](#the-trust-model-in-one-page)
- [Maintenance and troubleshooting](#maintenance-and-troubleshooting)
- [Cheat sheet](#cheat-sheet)

---

## 0. The mental model

nix has exactly three ideas:

1. **An alias is a name for a directory.** `acme -> C:\code\acme`. That's all
   `~/.nix/aliases.toml` holds.
2. **Every command takes an alias first.** "Do *this* at *that place*":
   `o acme` (go), `e acme` (edit), `g acme TODO` (search), `x acme :test` (run).
   You never type a path again.
3. **Everything else is layered files keyed by alias.** Actions, environment,
   sub-directories and exports each live in small TOML files, found in up to
   three places:

   | | project (committed, travels with `git clone`) | central (private, `~/.nix/...`) | machine-wide |
   |---|---|---|---|
   | actions | `.nix/actions.toml` | `actions/<alias>.toml` | `actions/_default.toml` |
   | env | `.nix/env.toml` | `env/<alias>.toml` (wins) | - |
   | segments | `.nix/segments.toml` | `segments/<alias>.toml` | `segments.toml` (`scope = "global"`) |
   | scripts | `.nix/scripts/` | `scripts/` | - |

   Anything in the *project* column arrived from someone else's repo, so it
   must be approved before it runs (see [the trust model](#the-trust-model-in-one-page)).

One binary serves every command: `o`, `e`, `s`, `y`, `p`, `x`, `g`, `f`, `q` are
all copies of `nix.exe` in `~/.nix/bin` that know their name. `nix` itself is
the long form and the system-command entry point (`nix --list`, `nix --doctor`).

---

## Level 1 - Daily driving

Nothing to configure: register a few aliases and these commands pay for
themselves the first day.

### 1.1 Set up once

```powershell
scoop bucket add sadirano https://github.com/sadirano/bucket
scoop install nix           # also installs bat, fzf, ripgrep, fd, neovim and runs nix --init
```

Restart the shell once. `~/.nix/bin` is now on your user PATH and the short
commands work in PowerShell, cmd, Windows Terminal, anything.

Optional but worth it:

- `scoop install everything-cli` - gives the `o` picker instant whole-disk reach.
- `ripgrep-all` (`rga`) - lets `g` search inside PDFs, Office docs and archives.
- Set `$EDITOR` if you don't want nix to pick from `nvim`/`vim`/`code`/`nano`/`notepad`.

On Linux/macOS, `nix --init` prints one line to add to `.bashrc`/`.zshrc`; there
`o` is a shell function that `cd`s in place, and Tab completes alias names.

Verify with `nix --doctor`.

### 1.2 Name your places

```powershell
nix acme C:\code\acme            # register
o acme C:\code\acme              # register and jump in one step
cd C:\code\acme; nix acme .      # register the current directory
o notes                          # unknown name -> directory picker -> pick -> registered and entered
```

Good candidates: every repo, but also the places you *keep going back to* -
`dl` for Downloads, `inbox` for a scans folder, `hosts` for
`C:\Windows\System32\drivers\etc`, `vault` for your notes, `logs` for a server
log share.

Rules worth knowing:

- Names are case-insensitive, and can't contain `/ \ @ + space [ ] = #` or quotes.
- Re-pointing an existing alias shows both paths and asks. Unattended, it refuses.
- A missing directory prompts `Create it? [Y/n]`.
- `.nix` is built in and always means nix's own home: `e .nix config.toml`,
  `g .nix TODO`.

### 1.3 Jump: `o`

```powershell
o acme            # new shell rooted at acme; `exit` returns you where you were
o                 # no alias: open ~/.nix in the editor
o docs@acme       # jump to a sub-alias (Level 4)
```

On Windows `o` *stacks* a shell: the project's `.nix/scripts` are on PATH, its
`.nix/env.toml` variables are set, and `NIX_ALIAS`/`NIX_ALIAS_PATH` are
exported. Exit and all of it is gone - scoped per session, like a virtualenv
for any kind of project. (Set `NIX_SHELL` to choose which shell `o` starts.)

**Daily habit:** instead of `cd ..\..\other-repo`, `o other`. Instead of
digging through Explorer to find where a download went, `o dl`.

### 1.4 Open: `e` and `s`

```powershell
e acme                    # the project in your editor
e acme src\main.zig       # one file
e .nix config.toml        # nix's own config

s acme                    # the folder in Explorer
s acme report.pdf         # a file with its default app
s acme invoice            # fzf-pick every file matching "invoice" -> open each
```

`s <alias> <pattern>` is the fastest way to open "that PDF in the contracts
folder" without knowing its exact name.

### 1.5 Search and find: `g` and `f`

```powershell
g acme TODO               # ripgrep -> fzf (live bat preview) -> editor at the line
g acme "fn\s+resolve"     # it's a regex
g acme invoice --all      # also search INSIDE PDFs, docx, xlsx, zip, epub (rga)
f acme config             # fuzzy-find files by name -> open
f acme                    # browse everything
```

Inside the picker: type to narrow further, **Tab** to mark several, **Enter**
to open all marked. Text opens in your editor at the matched line; PDFs,
images and archives open in their default app.

Make document search the default with `[grep] all = true` in
`~/.nix/config.toml`; `-a` then flips a single search back.

**Daily habit:** `g vault "standup"` to find last week's notes;
`g contracts "termination" -a` to search a folder of PDFs by content.

### 1.6 The clipboard: `y` and `p`

`y` copies *out of* a place; `p` pastes *into* it.

```powershell
y acme                    # copy acme's path (and print it)
y acme invoice            # pick files -> copy the FILES (paste them in Explorer, Slack, email)
y acme --as wsl           # copy /mnt/c/code/acme

p acme                    # save the clipboard into acme; copy the saved path back
p acme shot               # ...as shot.png (image) or shot.md (text)
p acme notes.txt          # an explicit extension wins
```

`p` handles whatever is on the clipboard: a screenshot becomes a `.png`, text
becomes a `.md`, and files copied in Explorer are copied in (folders
recursively). Names never collide - `shot.png`, `shot-1.png`, `shot-2.png`.

**Daily habits:**

- `Win+Shift+S`, then `p bugs login-error` - screenshot filed, path on the
  clipboard ready to paste into a ticket.
- Copy an error message, `p scratch trace` - it's saved, not lost to the next copy.
- `y acme` then paste into a "Browse..." dialog instead of clicking through folders.

### 1.7 Run something there: `x`

```powershell
x acme git status                   # run in acme, come back
x acme npm install
x acme -o code .                    # start a program detached and return immediately
```

You stay where you are; the command runs in the alias directory with the
project's environment. This is the "I just need to pull that other repo"
command: `x lib git pull`.

### 1.8 Close the shell: `q`

`q` closes the shell you typed it in. It refuses if the parent isn't actually a
shell (so it can't take down Windows Terminal with all its tabs);
`q --dry-run` shows what it would close.

### 1.9 Rename the commands

Single letters not your thing, or clashing with something? In
`~/.nix/config.toml`:

```toml
[shortcuts]
o = "open"
g = "search"
x = ["x", "r"]    # an array keeps BOTH names
```

Then `nix --sync` and restart the shell. (A single string *replaces* the letter.
Check a name is free first with `Get-Command <name> -All` - a PowerShell alias
always beats an exe.)

### 1.10 Housekeeping

```powershell
nix --list                 # every alias and its path
nix --which                # which alias am I inside?
nix acme                   # print the path
nix acme --remove          # forget an alias (the directory is untouched)
nix --edit                 # open ~/.nix in the editor (aliases.toml is hand-editable)
nix --doctor               # health check
```

---

## Level 2 - Saved actions

The commands you type over and over in a project - build, test, serve,
deploy - saved under short names and runnable *from anywhere*. Think
`package.json` scripts for any language, with descriptions, arguments,
chaining, elevation and notifications built in.

### 2.1 Your first actions file

```powershell
e acme :                  # opens acme's .nix/actions.toml, creating it from a template
e acme :test              # opens it AT the `test` line, seeding a stub if it's new
```

```toml
# C:\code\acme\.nix\actions.toml  - commit this with the project
[actions]
build = "zig build -Doptimize=ReleaseFast"
test  = "zig build test"

# Dev server with hot reload on :5173.
serve = "npm run dev"

# Builds, then mirrors dist/ to the live host. Not reversible - it
# deletes anything on the target that isn't in dist/.
deploy = "npm run build && rsync -a --delete dist/ host:/srv/acme"
```

Values are plain shell command lines: `&&`, pipes and redirects all work. The
`#` comment directly above an action becomes its **description** in every
listing. Tip: use single-quoted TOML strings for anything with backslashes
(`'C:\tools\x.exe'`); double-quoted values are not escape-decoded.

Your own actions in a repo you wrote still pass the approval gate once - run
`nix --trust acme` (or grant standing trust, [below](#the-trust-model-in-one-page)).

### 2.2 Running, listing, picking

```powershell
x acme :test              # run it in acme's dir, here, in the foreground
x acme :                  # list acme's actions and pick one (fzf)
x :test                   # standing inside acme? runs acme's :test
```

`x acme :` shows a table like:

```
ACTION  COMMAND                                      DESCRIPTION
deploy  npm run build && rsync -a --delete dist/...  Builds, then mirrors dist/ to the live host. No...
serve   npm run dev                                  Dev server with hot reload on :5173.
test    zig build test
```

A leading `:` marks a saved action. Without it, `x acme test` runs a *program*
or *script* named `test`.

### 2.3 Arguments and `{args}`

Arguments are appended:

```powershell
x acme :test -- --summary all        # zig build test --summary all
x acme :commit -- -m "two words"     # quoting survives intact
```

The `--` is only needed when an argument looks like a nix flag. When the
arguments belong in the middle, place them with `{args}`:

```toml
[actions]
serve = "npm run dev -- --port {args} --open"
logs  = "docker compose logs -f {args}"
```

```powershell
x acme :serve 8080
x acme :logs api worker
```

### 2.4 Chains

```powershell
x acme :build :test :deploy
```

Runs in order, in this terminal, stopping at the first failure - the `&&` you
would have typed, with a `==> acme :test` header per step so the log reads back
cleanly. Chains take no arguments (which step would get them?); for a chain
you run often, make it an action of its own:

```toml
release = "zig build ci && zig build deploy"
```

### 2.5 Detached windows: `-o`

```powershell
x acme -o :serve          # new console window, in acme's dir; you get the prompt back
```

Use it for anything long-running you want to *watch* but not *wait on*: dev
servers, watchers, `docker compose up`, log tails.

### 2.6 The three layers of actions

| File | Who sees it | Use for |
|---|---|---|
| `<project>/.nix/actions.toml` | everyone who clones | the project's real build/test/serve |
| `~/.nix/actions/acme.toml` | only you, only acme | personal shortcuts for one project (your staging box, your debug flags) |
| `~/.nix/actions/_default.toml` | only you, every alias | habits you want everywhere |

The most specific layer wins by name. Machine-wide actions are available as
`x <any-alias> :name` and, with no alias, `x :name` runs them in the current
directory.

```toml
# ~/.nix/actions/_default.toml   (open with `e :`)
[actions]
st    = "git status -sb"
lg    = "git log --oneline --graph -20"
fresh = "git fetch --all --prune && git status -sb"
todo  = 'rg -n "TODO|FIXME"'
code  = "code ."
claude = "claude"
pause = "pause"
```

Now `x lib :fresh`, `x api :lg`, `x docs :code` work for every alias you have
or will ever register, and none of it leaks into any repo.

### 2.7 Shell-specific actions

`[actions]` uses the platform shell (`cmd` on Windows). For the rest:

```toml
[bash]
lint = "./scripts/lint.sh"

[pwsh]
clean = "Get-ChildItem -Recurse -Include bin,obj | Remove-Item -Recurse -Force"
```

Set the executables in `~/.nix/config.toml` if they aren't on PATH:

```toml
[shells]
bash = 'C:/Program Files/Git/bin/bash.exe'
pwsh = 'C:/Program Files/PowerShell/7/pwsh.exe'
```

### 2.8 Scripts in `.nix/scripts/`

When a one-liner outgrows TOML, put a script in `<project>/.nix/scripts/` (or
`~/.nix/scripts/` for your own) and run it by bare name:

```
C:\code\acme\.nix\scripts\seed-db.ps1   ->   x acme seed-db --small
```

- `.cmd`, `.bat`, `.exe` and `.ps1` are all found by bare name; `.ps1` runs
  through pwsh with `-NoProfile -ExecutionPolicy Bypass`.
- The scripts dir is on PATH in every alias context, so scripts can call each
  other, and **inside an `o acme` shell you just type `seed-db`**.
- Project scripts shadow central ones of the same name.

### 2.9 The palette: every action on the machine

You'll forget *which project* owns a command long before you forget the command.

```powershell
x :                       # every project's actions in one fzf view
x : deploy                # pre-filtered (alias, name, command or description)
nix --actions "not reversible"    # find the dangerous ones by their comments
```

Enter runs the pick in its own directory. **Tab-mark several and they all
start in parallel, each in its own window** - bring up an API, a worker and a
frontend from one picker.

### 2.10 Administrator actions

Prefix the command with `sudo`:

```toml
[actions]
# Rebinds the service account. Needs admin.
install = 'sudo .\scripts\install-service.ps1'
hosts   = 'sudo notepad C:\Windows\System32\drivers\etc\hosts'
```

`x acme :install` shows the exact line, asks, raises UAC and runs in an
elevated console of its own. Listings mark which actions elevate. For fixed
lines you trust, skip nix's question (UAC still asks):

```toml
# ~/.nix/config.toml
[confirm]
trusted = ["hosts"]
```

---

## Level 3 - Per-project environment and secrets

Connection strings, API bases and tokens belong to the *project*, not to
whatever shell you happened to open. nix is direnv for Windows, without
sourcing anything.

```toml
# C:\code\acme\.nix\env.toml   (committed: the defaults that work for everyone)
[env]
DATABASE_URL = "postgres://localhost/acme_dev"
API_BASE     = "https://staging.internal"
ACME_TOKEN   = "${secret:acme-api}"
```

```toml
# ~/.nix/env/acme.toml   (private: YOUR machine's overrides; wins per key)
[env]
DATABASE_URL = "postgres://box.local:5433/acme"
```

Every `o acme`, `x acme <cmd>` and `x acme :action` gets these variables.

**Secrets never sit in a file.** Store them in the Windows Credential Manager:

```powershell
nix --secret set acme-api        # prompts; the value is never echoed
nix --secret list                # names only
nix --secret rm acme-api
```

`${secret:NAME}` is resolved only at the moment a child process is spawned. It
also works inside action command lines:

```toml
[actions]
publish = "npm publish --otp ${secret:npm-otp}"
```

**See exactly what a command will get, and from where:**

```powershell
nix acme --env
```

```
  NAME          FROM     VALUE
  ACME_TOKEN    project  ${secret:acme-api}
  API_BASE      project  https://staging.internal
  DATABASE_URL  central  postgres://box.local:5433/acme
```

Behaviour worth knowing:

- An `x` with an unresolvable secret aborts before running; an `o` warns and
  enters anyway.
- `PATH`, `PATHEXT`, `COMSPEC` and `NIX_*` can't be set here.
- A cloned `env.toml` sets nothing until approved (`nix --trust acme env`); the
  command still runs, and nix tells you the variables were skipped.
- Elevated actions get the env minus anything from a secret (a command line is
  visible to every process on the machine).

**Workflow: dev vs. staging vs. prod.** Keep one alias per target pointing at
the same repo? No need - override one variable for one command instead:

```powershell
$env:API_BASE="https://prod.internal"; x acme :smoke
```

or give each environment its own action:

```toml
[actions]
smoke-staging = "set API_BASE=https://staging.internal&& npm run smoke"
smoke-prod    = "set API_BASE=https://prod.internal&& npm run smoke"
```

---

## Level 4 - Sub-aliases and computed paths

Aliases name projects; **segments** name places *inside* projects, written
`segment@alias`. Every command understands them: `o docs@acme`,
`g src@acme TODO`, `p shots@acme`, `x api@acme npm test`.

### 4.1 Static segments

```toml
# ~/.nix/segments/acme.toml   (or <acme>/.nix/segments.toml to share with the team)
[[contexts]]
segment = "docs"
source-template = "/documentation"

[[contexts]]
segment = "api"
source-template = "/services/api"
```

For segments you want on *every* alias, use the global file and opt in:

```toml
# ~/.nix/segments.toml
[[contexts]]
segment = "src"
scope = "global"
source-template = "/src"

[[contexts]]
segment = "tests"
scope = "global"
source-template = "/tests"
```

Now `o src@acme`, `f tests@lib`, `g src@api "panic"` work everywhere.
Using a segment nobody defined yet seeds a skeleton for you in
`~/.nix/segments/<alias>.toml`. `nix --contexts` lists the global ones.

### 4.2 Inline values

A segment can take a value with `segment:value@alias`, bound as `${segment}`:

```toml
[[contexts]]
segment = "tasks"
scope = "global"
source-template = "/tickets/${tasks}"
```

```powershell
o tasks:432@acme          # -> C:\code\acme\tickets\432
p tasks:432@acme repro    # screenshot filed straight into the ticket folder
```

Variables resolve from, in order: the inline value, a script's output (next
section), the process environment, then the context's `[contexts.vars]`
defaults. So `region=eu o logs@api` can override a default for one command.

Segments nest, innermost first: `o client:bob@projb`.

### 4.3 Wildcards: the folders decide the path

When the thing you'd look up is already the folder layout - tickets under
clients, ticket numbers unique - no script is needed. Put `*` in the template:

```toml
# ~/.nix/segments/tasks.toml
[[contexts]]
segment = "client"
source-template = "/${client}"

[[contexts]]
segment = "ticket"
source-template = "/${ticket}"

# the shortcut: find the client by searching
[[contexts]]
segment = "t"
source-template = "/${client=*}/${t=*}"
```

```powershell
o ticket:1@client:A@tasks    # explicit, as before
o t:1@tasks                  # -> tasks\A, client found for you
o t@tasks                    # every ticket in every client, as a menu
o t:3*@tasks                 # the typed value is a pattern: 3, 30, 3-login...
x t:1@tasks claude           # start an agent there; $client is set to A
```

- `*` matches directory names, one level per component (`1-*` works too).
- `**` matches any number of levels, for clients that nest differently
  (`tasks/A/1`, `tasks/B/2024/2`): `source-template = "/**/${t=*}"`. It never
  descends into a match, stops at `depth` levels (default 4; set
  `depth = "2"` on the context to tighten it), and gives up with a message
  after opening 5,000 folders rather than hanging on a stray `node_modules`.
- `${name=*}` captures: the matched name becomes a variable in the shell or
  command, like a context source's output.
- One match navigates, several open a picker, none is an error naming the
  pattern. Unattended, several matches print and exit non-zero.
- Dot-directories (`.nix`, `.git`) never match `*`; links aren't followed; it
  runs nothing, so it needs no `--trust`.

Reach for a script (next section) only when the answer is *not* on disk.

### 4.4 Context sources: a script decides the path

When the path depends on something you'd have to *look up* - which client owns
ticket 123, which sprint folder is current - let a script answer:

```toml
[[contexts]]
segment = "task"
run = "set_vars ${task}"                    # a script in .nix/scripts or ~/.nix/scripts
source-template = "/${client_name}/${task}"
cache = "1h"
```

```powershell
# ~/.nix/scripts/set_vars.ps1
param([string]$Task)
$client = (Invoke-RestMethod "https://tracker/api/ticket/$Task").client
Add-Content $env:NIX_CONTEXT_OUT "client_name=$client" -Encoding ascii
```

```powershell
o task:123@work           # looks up 123 -> acme -> C:\work\acme\123
x task:123@work claude    # same place, run a command there
```

The contract: append `KEY=VALUE` lines to the file named by
`$NIX_CONTEXT_OUT`; stdout is only shown, never parsed; a non-zero exit aborts.
`secret:KEY=value` marks a credential (never cached, withheld from elevated
commands). Results are cached for `cache` (`"30s"`, `"10m"`, `"2h"`, `"1d"`,
`"0"`). Full samples: [`assets/samples/context-source/`](../assets/samples/context-source/).

### 4.5 Menus

If the script answers with several blocks separated by `---`, the segment
becomes a picker:

```
_display=PROJ-123  Fix login flow
task=123
client_name=acme
---
_display=PROJ-140  Rate limiter
task=140
client_name=initech
```

```powershell
o task@work               # fzf over your open tickets; the pick is the destination
o task:140@work           # inline value: no menu, straight there
```

One block navigates silently, several open the menu, none is an error. Great
sources: your open tickets, PR worktrees, today's log directories, the
customers you're on call for.

### 4.6 Named producers

Separate "the lookup" from "the shape of the path", so one script serves many
projects that lay out their folders differently:

```toml
# ~/.nix/segments.toml
[[producers]]
name = "ticket"
run = "set_vars ${task}"
cache = "1h"
```

```toml
# projA/.nix/segments.toml                # projB/.nix/segments.toml
[[contexts]]                              [[contexts]]
segment = "task"                          segment = "task"
uses = "ticket"                           uses = "ticket"
source-template = "/${client_name}/${task}"   source-template = "/tickets/${task}-${client_name}"
```

The cache is shared - ticket 123 is looked up once, whichever project asks.
A project file that only `uses` a producer needs no approval.

### 4.7 The `shared@` drop

Built in for every alias: `shared@acme` is `<acme>/.nix/shared/`, a handoff
folder between you and your tools/agents. Add `.nix/shared/` to your global
gitignore.

```powershell
p shared@acme spec        # drop clipboard text for an agent to read
o shared@acme             # see what it left you
```

---

## Level 5 - Global commands (`[bin]` exports)

Turn a project's tool, or a saved action, into a command on your PATH - no PATH
edits, no loose `.cmd` files rotting in some folder.

**Export a file:**

```toml
# C:\code\hoot\.nix\actions.toml
[bin]
hoot = "zig-out/bin/hoot.exe"      # exes are copied
gw   = "scripts/gw.cmd"            # .cmd/.bat get a forwarder (edits are live)
fmt  = "scripts/fmt.ps1"           # .ps1 gets a trampoline, works from cmd too
```

**Export an action** - it keeps running in *its* project dir, with its env,
`{args}`, elevation and notifications:

```toml
[actions]
deploy = "./scripts/build.sh && rsync -a dist/ host:/srv"

[bin]
ship = ":deploy"
```

```powershell
nix --sync-bin            # install/refresh (asks per new name and per new version)
ship --prod               # from anywhere = x acme :deploy -- --prod
```

**Personal globals with no project** - put them in `_default.toml`; they run
in the *current* directory:

```toml
# ~/.nix/actions/_default.toml
[actions]
gs   = "git status -sb"
sudo = "sudo {args}"
cc   = "cd | clip"
ps1  = 'pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File {args}'

[bin]
gs  = ":gs"
su  = ":sudo"
cc  = ":cc"
ps1 = ":ps1"
```

```powershell
su notepad C:\Windows\System32\drivers\etc\hosts
cc                        # copy the current directory
```

This one file replaces your PowerShell profile functions *and* your cmd
doskeys, and works identically in both. The [Cookbook](../COOKBOOK.md) has more.

Rules of the road:

- Nothing is installed on your behalf: `--sync` only lists new names/versions;
  `--sync-bin` is the explicit "yes". Rebuilding an exe? Append
  `&& nix --sync-bin` to the project's `:build`.
- Remove the `[bin]` line (or the alias) and the next sync removes the command.
- `--sync-bin` warns when an export name shadows something else on PATH.
- Don't hand-edit `~/.nix/bin`; nix restores edited exports, and
  `[bin] foreign = "purge"` deletes files it didn't install.
- An exported action gets `NIX_EXPORT` = the name it was called by.

---

## Level 6 - Automation and integration

### 6.1 Completion notifications

Every foreground `:action` can report how it ended - most usefully, when it
*failed* while you were in another window:

```toml
# ~/.nix/config.toml
[notify]
on_finish        = 'hoot send "{message}" --tag {alias} --level {level}'
on_finish_min_ms = 2000                # quiet for fast successes (failures always report)
on_finish_skip   = ["st", "acme:lint"] # never report these
on_paste = 'hoot send "{message}" --tag {alias}'
on_yank  = 'hoot send "{message}" --tag {alias}'
```

Placeholders: `{alias} {action} {exit} {status} {duration} {level} {message}`.
The hook also sees `NIX_ACTION`, `NIX_ACTION_EXIT`, `NIX_ACTION_DURATION_MS`.
Any notifier works - a toast tool, `curl` to a webhook, a script in
`.nix/scripts`. Prefix `cmd /c` if you need shell operators.

A zero-dependency Windows toast via a central script:

```toml
on_finish = 'toast {status} "{message}"'
```

```powershell
# ~/.nix/scripts/toast.ps1
param($Status, $Message)
Add-Type -AssemblyName System.Windows.Forms
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = [System.Drawing.SystemIcons]::Information
$n.Visible = $true
$n.ShowBalloonTip(5000, "nix: $Status", $Message, 'Info')
Start-Sleep 6; $n.Dispose()
```

### 6.2 Pinned shortcuts that don't lie

Make a Windows shortcut (Desktop, Start, taskbar, a Stream Deck button) whose
target is:

```
C:\Users\you\.nix\bin\x.exe acme :build :test
```

or an exported action (`ship.exe`). If anything fails, the console **stays
open** with the error ("press Enter") instead of flashing and vanishing.
Success closes it. To hold on success too, end the chain with `:pause`.

### 6.3 Scripting nix: `--no-prompt`, `--list-names`, `--which`

nix never blocks a script: without a console, or with `--no-prompt`, every
picker prints its table and exits instead of asking.

```powershell
nix --list-names                          # one alias per line
nix acme                                  # just the path

# pull every repo you have registered
nix --list-names | % { x $_ git pull --ff-only }

# does anything still have a TODO?
nix --list-names | % { "== $_"; x $_ rg -c TODO }

nix --no-prompt --actions                 # the palette as a table
nix --doctor && echo healthy              # non-zero exit on a core problem
```

`--json` / `-j` asks for machine-readable output where a command has it.

### 6.4 Path dialects: `--as`

The same directory, spelled for whichever tool is about to read it:

```powershell
nix acme --as wsl         # /mnt/c/code/acme
nix acme --as gitbash     # /c/code/acme
nix acme --as slash       # C:/code/acme
nix acme --as uri         # file:///C:/code/acme
y acme --as wsl           # ...and copy it

wsl -e bash -c "cd $(nix acme --as wsl) && make"
```

### 6.5 Your prompt knows where you are

Every shell and command nix starts has `NIX_ALIAS` and `NIX_ALIAS_PATH`. For
shells nix *didn't* start, `nix --which` answers from the current directory
(read-only, cheap, non-zero when outside every alias):

```powershell
# $PROFILE
function prompt {
  $a = if ($env:NIX_ALIAS) { $env:NIX_ALIAS } else { nix --which 2>$null }
  $tag = if ($a) { "[$a] " } else { "" }
  "$tag$($PWD.Path)> "
}
```

The same works for Starship custom modules, oh-my-posh segments or a tmux
status line.

### 6.6 The time ledger

Every `o` session, foreground `x` command and `:action` appends a line to
`~/.nix/time`:

```
acme 1754200000 3600 session
acme 1754203700 42 action
```

(`alias`, start as Unix time, seconds, kind.) nix writes it and never shows it -
it's yours to report on. A weekly summary:

```powershell
$since = [DateTimeOffset]::Now.AddDays(-7).ToUnixTimeSeconds()
Get-Content ~/.nix/time | ForEach-Object {
  $a, $start, $secs, $kind = $_ -split ' '
  if ([long]$start -ge $since) { [pscustomobject]@{ Alias=$a; Hours=[double]$secs/3600 } }
} | Group-Object Alias | ForEach-Object {
  [pscustomobject]@{ Alias=$_.Name; Hours=[math]::Round(($_.Group | Measure-Object Hours -Sum).Sum, 1) }
} | Sort-Object Hours -Descending
```

Save it as `~/.nix/scripts/week.ps1`, declare `week = "week"` under `[actions]`
and `week = ":week"` under `[bin]` in `_default.toml`, run `nix --sync-bin`, and
`week` is a command.
Note that a shell left open overnight is logged at its true length.

### 6.7 AI coding agents

`nix --init` writes `~/.nix/AGENTS.md`, teaching agents your command surface
(with your renamed shortcuts). Wire it up yourself, e.g. for Claude Code in
`~/.claude/CLAUDE.md`:

```
@~/.nix/AGENTS.md
```

Agents then run `x acme :test` instead of guessing build commands, resolve
paths with `nix <alias>`, save repeatable commands as actions, and can read
full specs with `nix --agent <topic>` or `<cmd> --agent`.

Two things to expect: an agent's shell has no console, so it cannot approve
project files (you run `nix --trust`), and every picker degrades to a printed
table. Pair it with `shared@<alias>` for handing files back and forth, and a
`_default` action like `claude = "claude"` so `x anyproj :claude` starts a
session in the right place.

---

## Level 7 - Complete workflows

Recipes that combine the levels above into a way of working.

### Workflow A - The morning start

```toml
# ~/.nix/actions/_default.toml
[actions]
fresh = "git fetch --all --prune && git status -sb"
```

```powershell
nix --list-names | % { x $_ :fresh }      # what moved overnight, everywhere
x :                                       # Tab-mark api :serve, web :serve, worker :run -> all start
o api                                     # and get to work
```

### Workflow B - The inner dev loop

```toml
# api/.nix/actions.toml
[actions]
# Format, lint, unit tests. Run before every commit.
check = "cargo fmt --check && cargo clippy -q && cargo test -q"
# Full stack in the background.
up    = "docker compose up"
db    = "psql %DATABASE_URL%"
```

```powershell
x api -o :up          # stack in its own window
o api                 # work in a shell that has DATABASE_URL etc.
x :check              # before each commit (from inside the alias)
g api "unwrap()"      # find the thing
x api :db             # poke the data with the project's own connection string
```

With `[notify] on_finish` set, a 3-minute `:check` pings you when it breaks.

### Workflow C - Ticket-driven work

1. A wildcard segment (Level 4.3) or a context source (4.4) maps a ticket to
   its client folder; with no value it's a menu of your tickets (4.5).
2. `o task@work` - pick today's ticket; you land in its folder.
3. `p task:123@work repro` - screenshots and logs filed as you go.
4. `g task:123@work "exception" -a` - search the customer's attached PDFs and
   zips.
5. `x task:123@work claude` - start an agent *in* that folder, with the
   ticket's variables (`task`, `client_name`) in its environment.
6. `y task:123@work repro` - copy the files to attach to the ticket reply.

### Workflow D - Onboarding a cloned repo

```powershell
git clone https://github.com/org/acme C:\code\acme
nix acme C:\code\acme
x acme :                   # what can this project do? (read-only listing)
nix --trust acme           # review every action, script, env.toml and context source; approve once
nix --sync-bin             # install anything it exports, after review
nix acme --env             # see what it will set; override privately in ~/.nix/env/acme.toml
```

For a repo you write yourself, `nix --trust acme --always` stops asking for
good.

### Workflow E - Shipping a project to its users

As a maintainer, commit `.nix/actions.toml`, `.nix/env.toml` and
`.nix/scripts/` so every contributor (and their agents) gets the same
`x acme :test`, `:serve`, `:release`:

```toml
[actions]
# Everything CI runs, in CI's order.
ci      = "zig build ci"
# Portable release build: no native CPU extensions.
release = "zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows -Dcpu=baseline"

[bin]
acme = "zig-out/bin/acme.exe"
```

nix's own repo does exactly this - see its `.nix/actions.toml`.

### Workflow F - A research / documents folder

```powershell
nix papers D:\Research
g papers "attention mechanism" -a     # search inside every PDF
s papers transformer                  # pick PDFs by name -> open in the viewer
y papers vaswani                      # copy the files to send
p papers notes-2026-09                # paste highlights from the clipboard as .md
```

### Workflow G - A multi-service platform

One alias for the monorepo, segments for each service, one chain per story:

```toml
# ~/.nix/segments/plat.toml
[[contexts]]
segment = "api"
source-template = "/services/api"
[[contexts]]
segment = "web"
source-template = "/apps/web"
```

```toml
# plat/.nix/actions.toml
[actions]
gen   = "make proto"
build = "make build"
e2e   = "make e2e"
```

```powershell
x plat :gen :build :e2e       # the whole story, stop at first failure
x api@plat -o npm run dev     # a service in its own window
g web@plat "useAuth"          # search just one app
```

### Workflow H - Machine admin without admin habits

```toml
# ~/.nix/actions/_default.toml
[actions]
hosts    = 'sudo notepad C:\Windows\System32\drivers\etc\hosts'
flushdns = "sudo ipconfig /flushdns"
sudo    = "sudo {args}"

[bin]
su = ":sudo"
```

```toml
# ~/.nix/config.toml
[confirm]
trusted = ["hosts", "flushdns"]   # fixed lines: skip nix's question, UAC still asks
```

`x :hosts`, `x :flushdns`, `su <anything>` - every elevated command is declared
in one reviewable file.

### Workflow I - Team conventions with personal overrides

- The repo commits `.nix/actions.toml` (build/test/serve), `.nix/env.toml`
  (dev defaults, `${secret:...}` references) and `.nix/segments.toml`
  (`docs`, `api`, ...).
- Each person adds `~/.nix/actions/acme.toml` (their own shortcuts; same names
  override theirs only), `~/.nix/env/acme.toml` (their DB, their region) and
  secrets via `nix --secret set`.
- Nobody commits a `.env`, nobody's local tweaks show up in `git status`.

### Workflow J - Clipboard as an inbox

```powershell
nix inbox D:\Inbox
p inbox                  # anything copied during the day: images, text, Explorer files
s inbox                  # triage later
f inbox                  # or fuzzy-open
```

With `[notify] on_paste` pointing at a log, you also get a record of every
paste.

---

## The trust model, in one page

Some files arrive with `git clone`; running them because you typed a *name* is
not consent to the *command*. So:

| Arrived with the repo | First run without approval |
|---|---|
| `.nix/actions.toml` action | shows command + the scripts it runs, asks `y/N/e` (e = open them in the editor) |
| `.nix/scripts/*` | same as its actions file |
| `.nix/env.toml` | variables are skipped (with a notice); the command still runs |
| `.nix/segments.toml` `run` line | refuses until approved |
| `[bin]` export of a project action | withheld from `--sync-bin` until approved |

- Approval is of the **exact bytes** - of the declaring file *and* the scripts
  it names. A `git pull` that changes either asks again. Per action, so editing
  `:deploy` doesn't re-arm `:build`.
- `nix --trust acme` reviews and approves everything at once;
  `nix --trust acme env` / `nix --trust acme <segment>` just one part.
- `nix --trust acme --always` - standing trust for repos *you* write (stored in
  `[trust] always`). Edits, including an agent's, never ask again.
- Without a console (scripts, agents, `--no-prompt`) nothing can be approved,
  including by `--trust` itself.
- Your own files (`~/.nix/...`) and literal commands you type are never gated.
- Elevated (`sudo`) actions always show their line and ask; only
  `[confirm] trusted` waives that, and never for project files.
- `nix --doctor` lists what's waiting for approval and which aliases have
  standing trust.

---

## Maintenance and troubleshooting

| Symptom | Do this |
|---|---|
| Anything odd | `nix --doctor` (tools found, PATH, wrappers, env layers, exports, pending approvals) |
| Renamed a shortcut / changed `[picker]` | `nix --sync`, restart the shell |
| Rebuilt or upgraded nix, exports ask again | `nix --sync-bin` - the fingerprint covers the binary, by design |
| `o <name>` picker slow or missing dirs | install `everything-cli`, or set `[picker] search_roots`; tune `exclude_extra` |
| An action "succeeds" but only prints a `.ps1` | a `.ps1` named in `[actions]` opens via file association; use `.nix/scripts/` or the `ps1` recipe |
| `\\` in a command reaches it doubled | use single-quoted TOML strings and forward slashes |
| `exit` in an action does nothing | an action runs in a child shell; use the built-in `q` |
| A short name doesn't answer in PowerShell | a pwsh alias shadows it: `Get-Command <name> -All` |
| An agent can't run a project action | expected: you run `nix --trust <alias>` (or `--always`) |
| Stale segment answer | lower its `cache`, or delete `~/.nix/contexts-cache.toml` (safe any time) |
| Testing configs without touching your real setup | `$env:NIX_HOME = "$env:TEMP\nix-scratch"` |

Files under `~/.nix` you might edit by hand: `aliases.toml`, `config.toml`,
`actions/*.toml`, `env/*.toml`, `segments.toml`, `segments/*.toml`,
`scripts/`. Leave `bin/`, `exports.toml`, `trusted.toml`, `usage`, `time` and
`contexts-cache.toml` to nix. `AGENTS.md` is regenerated by `--sync`.

---

## Cheat sheet

```text
REGISTER / INSPECT
  nix acme C:\path          register            nix --list / --list-names
  o acme C:\path            register + jump     nix --which [path]
  nix acme --remove         forget              nix acme [--as wsl|gitbash|slash|uri|win]

DAILY                                           ACTIONS
  o acme        jump (shell with env+scripts)     x acme :test           run saved action
  e acme [f]    editor                            x acme :               pick acme's actions
  s acme [pat]  explorer / open files             x :   (x : deploy)     palette, all projects
  y acme [pat]  copy path / copy files            x acme :a :b :c        chain, stop on failure
  p acme [name] clipboard -> file                 x acme :t -- args      pass arguments
  g acme pat    search (-a: inside docs)          x acme -o :serve       own window
  f acme [pat]  fuzzy-find files                  x acme git status      literal command
  x acme cmd    run command there                 x acme myscript        .nix/scripts/myscript.*
  q             close this shell                  e acme : / e :         edit project / machine actions

SEGMENTS                                        ENV & SECRETS
  o docs@acme            static                   nix acme --env
  o task:123@acme        inline value             nix --secret set|rm|list NAME
  o task@acme            menu from a script       ${secret:NAME} in env.toml / actions
  o t:1@tasks            wildcard /${client=*}/${t=*}
  o shared@acme          built-in handoff dir

SYSTEM
  nix --init | --sync | --sync-bin | --doctor | --actions [pat] | --contexts
  nix --trust <alias> [env|segment] [--always]  | --agent [topic] | --edit | --version
  global flags: --no-prompt  --json/-j  --as <dialect>

FILES (~/.nix)
  aliases.toml  config.toml  actions/_default.toml  actions/<alias>.toml
  env/<alias>.toml  segments.toml  segments/<alias>.toml  scripts/
PROJECT (<dir>/.nix)
  actions.toml ([actions] [bash] [pwsh] [bin])  env.toml  segments.toml  scripts/  shared/
```
