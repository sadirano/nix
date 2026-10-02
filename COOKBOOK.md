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
- [Common mistakes](#common-mistakes)

## Recipes

### `sudo` — run anything elevated

nix's `sudo` marker elevates a *declared* action, but a typed command line
(`x acme sudo whoami`) isn't one. `{args}` closes the gap: the action becomes
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

Nothing to write: `q` is a built-in command. It terminates the process that
started it, refusing unless that process really is a shell (cmd, powershell,
pwsh, bash, sh, zsh, fish, nu) - from Windows Terminal, an IDE or a shortcut the
process above can be the terminal host itself, and closing that would take every
other tab with it. `q --dry-run` names the target without touching it.

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
<project>/.nix/scripts/build.ps1     ->     x acme build --release
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
destroyed the moment the command exits: `x acme :build :test :pause`. A chain
stops at the first failure, so this runs only when everything before it
succeeded — to read an *error*, launch via `cmd /k`, which holds either way.

### Stop nix asking about a vetted elevated command

An elevated action confirms every time, because the UAC dialog names the *shell*
rather than the command line it was handed. For a fixed line you wrote yourself,
you can skip nix's question:

```toml
# ~/.nix/config.toml
[confirm]
# elevate these without nix asking first; UAC still does
trusted = ["hosts", "env"]
```

It waives nix's prompt and nothing else: UAC still asks, an unattended run still
refuses, and a listed name is ignored the moment the command touches project
files — so listing `deploy` exempts yours, never a cloned repo's.

## Common mistakes

**nix does not interpret TOML escapes.** Action values are literal, so `\\`
stays doubled and reaches the command as two backslashes. Use a single-quoted
literal string and forward slashes:

```toml
good = 'pwsh -File "%USERPROFILE%/.nix/scripts/thing.ps1"'
bad  = "pwsh -File \"%USERPROFILE%\\.nix\\scripts\\thing.ps1\""
```

**`exit` in an action exits nix's child shell, not yours.** `q = "exit"` does
nothing: an action runs in a child, and a child cannot make its parent return. That is what the built-in `q` is for.

**Check a name before you take it.** `ps` is `Get-Process` in PowerShell and `r`
is `Invoke-History`; a shell's own alias always wins over an exe on PATH:

```
Get-Command <name> -All
```

`nix --sync-bin` warns when an export collides with something else on PATH, and
`nix --doctor` reports drift, but a shell builtin is invisible to both.

**Rebuilding a file export re-arms consent.** A file export's fingerprint is the
source file's bytes, so a rebuilt `.exe` makes `--sync-bin` ask again; run it
and it clears. An action export is fingerprinted by its command text, so it
only asks again when that changes.
