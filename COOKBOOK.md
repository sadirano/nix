# Cookbook

Recipes for `~/.nix/actions/_default.toml` and `~/.nix/config.toml` — the two
files that make a machine yours. Everything here is copy-pasteable and needs no
nix changes.

The pattern behind most of it: an action under `[actions]`, exported as a global
command under `[bin]`. `nix --sync-bin` installs it into `~/.nix/bin`, which is
already on your PATH, so one declaration replaces a shell alias, a PowerShell
function, and a manual PATH entry — and works the same in cmd and PowerShell.

- [Recipes](#recipes)
  - [`sudo` — run anything elevated](#sudo--run-anything-elevated)
  - [`q` — close the shell you typed it in](#q--close-the-shell-you-typed-it-in)
  - [`ps1` — run a PowerShell script](#ps1--run-a-powershell-script)
  - [`cc` — copy the current directory](#cc--copy-the-current-directory)
  - [`pause` — hold a window open](#pause--hold-a-window-open)
  - [Stop nix asking about a vetted elevated command](#stop-nix-asking-about-a-vetted-elevated-command)
- [Things that will bite you](#things-that-will-bite-you)

## Recipes

### `sudo` — run anything elevated

nix's `sudo` marker elevates a *declared* action, but a typed command line
(`r acme sudo whoami`) isn't one. `{args}` closes the gap: the action becomes
whatever you hand it.

```toml
# ~/.nix/actions/_default.toml
[actions]
sudo = "sudo {args}"

[bin]
su = ":sudo"
```

```
su notepad C:\Windows\System32\drivers\etc\hosts
```

The elevated command opens in a console of its own — UAC hands back a process
under a different token, and it cannot write into your terminal.

**Bare `su` will not work.** With no arguments the command is just `sudo`, and a
bare marker with nothing after it isn't a marker. For "an elevated shell here",
declare it separately:

```toml
[actions]
suhere = "sudo cmd"
[bin]
suh = ":suhere"
```

### `q` — close the shell you typed it in

An action runs in a *child* of your shell, and a child cannot make its parent
`exit` — only kill it. Which means finding it first.

The chain under an exported action is:

```
pwsh.exe     <- the script
cmd.exe      <- nix's `cmd /c` wrapper
q.exe        <- the export: a copy of nix, renamed
cmd.exe      <- your shell                  <- close this
```

So walk up to the export and take the process above it. `NIX_EXPORT` carries the
name nix was invoked under, so nothing is hardcoded and renaming the `[bin]` key
keeps working.

Save as `~/.nix/scripts/qkill.ps1`:

```powershell
param([string]$Export = $env:NIX_EXPORT, [switch]$DryRun)
if (-not $Export) { Write-Error "q: no NIX_EXPORT - run this as a [bin] export"; exit 1 }

function Get-ParentOf($proc) {
    try { if ($proc.Parent) { return $proc.Parent } } catch { }
    $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue).ParentProcessId
    if ($ppid) { return Get-Process -Id $ppid -ErrorAction SilentlyContinue }
    return $null
}

$cur = Get-Process -Id $PID
$base = [IO.Path]::GetFileNameWithoutExtension($Export)
$found = $null
for ($i = 0; $i -lt 8 -and $cur; $i++) {
    if ($cur.ProcessName -ieq $base) { $found = $cur; break }
    $cur = Get-ParentOf $cur
}
if (-not $found) { Write-Error "q: did not find $Export above this process"; exit 1 }

$target = Get-ParentOf $found
if (-not $target) { Write-Error "q: nothing above $Export to close"; exit 1 }

# The guard, not decoration: from Windows Terminal, VS Code or a .lnk the parent
# can be WindowsTerminal.exe / Code.exe / explorer.exe, and killing that takes
# the whole application down rather than one shell.
if (@('cmd','powershell','pwsh','bash','sh') -notcontains $target.ProcessName.ToLower()) {
    Write-Error "q: refusing - the process above is $($target.ProcessName), not a shell"
    exit 1
}

if ($DryRun) { "q: would close $($target.ProcessName) (PID $($target.Id))"; exit 0 }
Stop-Process -Id $target.Id -Force
```

```toml
[actions]
q = 'pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%USERPROFILE%/.nix/scripts/qkill.ps1" {args}'

[bin]
q = ":q"
```

`q -DryRun` prints the target without touching it. Two things to know: it is a
hard kill, so a shell holding unflushed state (clink's history, for one) may lose
it; and from PowerShell it closes your PowerShell, which is usually what you want
but is the case where a mistake costs most.

### `ps1` — run a PowerShell script

```toml
[actions]
ps1 = 'pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File {args}'

[bin]
ps1 = ":ps1"
```

```
ps1 tools/build.ps1 --release
```

**Check whether you need this first.** A script in a project's `.nix/scripts/`
already runs by bare name with those flags supplied for you, picking `pwsh` when
present and Windows PowerShell when it isn't:

```
<project>/.nix/scripts/build.ps1     ->     r acme build --release
```

The recipe is for scripts you'd rather keep at their natural place in the repo
(`tools/`, `scripts/`) than move under `.nix/`.

Do not call it `ps` — that is PowerShell's alias for `Get-Process` and would
never win there.

### `cc` — copy the current directory

```toml
[actions]
cc = "cd | clip"

[bin]
cc = ":cc"
```

A machine-wide export runs in *the current* directory, which is what makes this
work from anywhere. (For an alias's path rather than the cwd, `y <alias>` already
does it, and `y <alias> <pat>` copies the files themselves.)

### `pause` — hold a window open

```toml
[actions]
pause = "pause"
```

Meant as the last link of a chain launched from a shortcut, where the console is
destroyed the moment the command exits: `r nix :build :sync :pause`. A chain
stops at the first failure, so this runs only when everything before it
succeeded — to read an *error*, launch via `cmd /k`, which holds either way.

### Stop nix asking about a vetted elevated command

An elevated action confirms every time, because the UAC dialog names the *shell*
rather than the command line it was handed. That is worth it for a passthrough
like `sudo {args}`, which runs anything, and worth nothing for a fixed line you
wrote once and re-read every time you type its name.

```toml
# ~/.nix/config.toml
[confirm]
# elevate these without nix asking first; UAC still does
trusted = ["hosts", "env"]
```

It waives nix's prompt and nothing else: UAC still asks, an unattended run still
refuses, and a listed name is ignored the moment the command touches project
files — so listing `deploy` exempts yours, never a cloned repo's.

## Things that will bite you

**nix does not interpret TOML escapes.** Action values are literal, so `\\`
stays doubled and reaches the command as two backslashes. Use a single-quoted
literal string and forward slashes:

```toml
good = 'pwsh -File "%USERPROFILE%/.nix/scripts/thing.ps1"'
bad  = "pwsh -File \"%USERPROFILE%\\.nix\\scripts\\thing.ps1\""
```

**A `.ps1` named in an action opens in your editor.** Action commands go to
`cmd /c`, which uses the file association — so `build = "build.ps1"` renders the
script's source and exits 0, looking like success. Use `.nix/scripts/` and a bare
name, or the `ps1` recipe above.

**`exit` in an action exits nix's child shell, not yours.** `q = "exit"` looks
reasonable and does nothing at all. See the `q` recipe for why.

**Check a name before you take it.** `ps` is `Get-Process` in PowerShell and `r`
is `Invoke-History`; a shell's own alias always wins over an exe on PATH:

```
Get-Command <name> -All
```

`nix --sync-bin` warns when an export collides with something else on PATH, and
`nix --doctor` reports drift, but a shell builtin is invisible to both.

**Rebuilding nix re-arms consent for exports.** An export's fingerprint covers
the binary, so `zig build deploy` (or any nix upgrade) makes `--sync-bin` ask
again. That is the gate working; run `nix --sync-bin` and it clears.
