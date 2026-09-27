---
name: Release checklist
about: Manual Windows-only verification for promoting a pre-release to a stable tag
title: "Release vX.Y.Z"
labels: release
---

Candidate: (none yet)

Everything here is Windows-only (the supported platform) and manual: it is
the surface `zig build ci` does not reach yet - interactive pickers, the
clipboard, a real terminal's PATH, the Scoop channels, and the install as it
exists on a machine that has been running an older version.

The stable tag will not publish until every box above the gate marker is
checked. The `Candidate:` line above is written by CI when a pre-release tag
is pushed; verify against THAT build. A new pre-release re-stamps the line and
unticks every gated box, so start again from the build the line names.

**Sandboxing:** steps marked 🧪 must run against a scratch store, never the
real one. In a fresh PowerShell:

```powershell
$env:NIX_HOME = "$env:TEMP\nix-rc"        # scratch store for this shell only
```

Steps touching the **real** `~/.nix` are marked ⚠️ - snapshot first:

```powershell
Copy-Item ~/.nix ~/.nix-pre-release-backup -Recurse
```

---

## 1. Install and upgrade path

- [ ] ⚠️ Take a full snapshot backup (`backup-snapshot`) of the real store and
      check it (`backup-check`: bundles, loose stores and hashed files
      intact). This is the rollback artifact for this release, so it comes
      BEFORE the deploy below, and lives somewhere the release cannot
      overwrite.
- [ ] ⚠️ Deploy over the daily install (`x nix :deploy`, or drop-in +
      `nix --sync`); existing aliases, actions, `[shortcuts]` and
      `[bin]` exports all still resolve.

## 2. PATH in a real terminal

`--init`, the wrapper set, `AGENTS.md` regeneration, `[shortcuts]` renames and
`--sync` over a running wrapper are checked by `zig build e2e` (its "install
lifecycle" section), including that a scratch home leaves the registry PATH
and the PowerShell profiles untouched. What e2e cannot do is open a new
terminal:

- [ ] A brand-new terminal (not a refreshed one) picks up PATH; `o` and `x` work.

## 3. Pickers and the clipboard

- [ ] `o <unknown-alias>` opens the directory picker and registers the pick
      (an alias that exists just navigates), and `nix --actions` opens the
      palette and runs the pick. Both engines: `[picker] engine = "fzf"` and
      `engine = "native"` in config.toml.
- [ ] `f <alias> <pat>` and `s <alias> <pat>` return results and open the picks.
- [ ] `y <alias>` copies the path; `y <alias> <pat>` puts the real FILES on the
      clipboard (paste into Explorer, not just a text field).
- [ ] `p <alias>` saves clipboard text, and an image, into the alias dir.
- [ ] With Everything running, doctor's `es` probe passes; stop Everything and
      it reports the fallback instead of passing falsely.

## 4. Actions, provenance and secrets

- [ ] 🧪 A freshly cloned project's `.nix/actions.toml` asks before its first
      run, and refuses (does not hang) with no console. Two halves, both
      required. On a REAL console `x <alias> :<action>` prints the command
      and its source file and waits for y/N. In a shell with NO console (an
      agent's, or a piped one) it must refuse and exit non-zero - never hang
      waiting on input nobody can supply, never silently run.
      Verify by SIDE EFFECT, not by output: give the action something
      observable (`hello = "cmd /c echo x > BREACH.txt"`) and confirm the
      file does not exist. The refusal quotes the command back at you for
      review, so grepping stdout for it cannot tell "refused" from "ran".
      `.nix/scripts/` files are gated identically: `x <alias> <script-name>`.
- [ ] 🧪 `nix --trust <alias>` approves it; editing the file asks again.
      `--trust` must first LIST what it would approve (each action with its
      command, the scripts they run, env.toml, each context source) and ask
      `y/N/e`; answering `n` must approve nothing, and running it from a
      pipe (`echo | nix --trust <alias>`) must refuse for want of a console.
      After a `y` the same action runs. Then change one character in THAT
      action's command and re-run it: it must ask AGAIN. Approval is per
      action, so an edit elsewhere in the file (a sibling added) leaves this
      one approved - that is intended. Guards the gate keying on identity
      rather than content - approving once must never bless every future
      edit that arrives with a `git pull`.
- [ ] An action beginning with `sudo` raises the UAC prompt and runs elevated
      in its own console. Cannot be run unattended by design, so this one
      needs you at the machine. Confirm the elevated console is a SEPARATE
      window, and that declining the UAC prompt fails the action cleanly
      rather than falling back to running it unelevated.
- [ ] `${secret:NAME}` resolves from Credential Manager and never reaches an
      elevated command line. Store a throwaway one with
      `nix --secret set SMOKE_TEST` yourself - the whole indirection exists so
      the value never enters a transcript or shell history. Then:
      `nix --secret list` shows the NAME only; a plain action using it
      (through env.toml, `KEY = "${secret:SMOKE_TEST}"`) gets the value; the
      same variable in a `sudo` action is withheld, and nix says so; and a
      `sudo` action with `${secret:SMOKE_TEST}` written inline is refused
      before anything runs. Remove it after: `nix --secret rm SMOKE_TEST`.
      The guarantee is narrow: a literal value in env.toml, or a context
      variable not marked `secret:`, is just text to nix.

## 5. `[bin]` exports

- [ ] `nix --sync-bin` installs a project's export into `~/.nix/bin`; the name
      runs from any directory. Declare `[bin] mytool = "zig-out/bin/x.exe"`,
      run `nix --sync-bin`, then invoke `mytool` from an UNRELATED directory -
      an export that only works inside the project dir is the bug. Running
      `nix --sync-bin` is the consent for a file export; an ACTION export
      (`ship = ":deploy"`) from an unapproved project file also needs
      `nix --trust <alias>`. Confirm a fresh clone does not install commands
      as a side effect of merely being registered.
A rebuilt export staying pending until `--sync-bin`, and `--doctor` naming a
hand-edited or no-longer-declared export, are checked by `zig build e2e`.

## 6. `[notify]` hooks

- [ ] `on_finish`, `on_paste` and `on_yank` fire against the real notifier, with
      quoting intact. Quoting is the whole risk: the hook is spawned directly
      rather than through `cmd /c`, because cmd mangles MSVC-escaped quotes.
      So send a message containing SPACES and a quote, and confirm the
      notifier receives it as ONE argument rather than several. Exercise all
      three triggers - a named `x <alias> :action` finishing (a literal
      command does not fire it, and mind `on_finish_min_ms` /
      `on_finish_skip`), a `p`, and a `y` - and confirm on_finish also fires
      for a FAILING action, not only a successful one.

## 7. Doctor on the real machine

- [ ] ⚠️ `nix --doctor` is green; `-q` shows only problems; `--json` parses.
      Against the REAL store, not a scratch one - the point of this step is
      your actual machine's tools and config. Pipe the JSON through a parser
      instead of eyeballing it: `nix --doctor --json | ConvertFrom-Json`.

## 8. Release hygiene

- [ ] Release CI is green on the candidate tag. That run's last steps read the
      release back: the published zip holds the exe it built, which reports
      the tag, and the pre-release is flagged **Pre-release** and is not
      `/releases/latest` (Excavator's checkver reads it). The checklist gate
      runs before the build, so it cannot vouch for this - look at the run.
- [ ] The stable Scoop bucket has **not** moved to the pre.
- [ ] `scoop update nix-nightly` still works.
- [ ] Any upgrade step this release needs from an older version is written
      down, and the release notes lead with an **Upgrading** section if
      anything breaks.

<!-- gate:stop - everything below is confirmed AFTER publishing, so the stable
     tag does NOT wait on it. `status` still lists these, and they are still
     yours to do; they simply cannot block the push that creates the thing they
     describe. Do not move this marker upward: anything above it is what the
     gate actually enforces. -->

## 9. Promote (post-publish, not gated)

- [ ] `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z` (the same commit
      as the candidate unless fixes landed - if they did, cut a new pre and
      re-verify from section 1). The gate refuses on any change to `src/`,
      `build.zig`, `build.zig.zon` or the release workflow since the
      candidate (unless the `release:override` label is set), so an accepted
      push means the source you verified is the source that ships - the
      binary itself is rebuilt, with its own version and date. Docs-only
      commits do not trip it and do not invalidate this checklist.
- [ ] The stable release run is green: its read-back confirms the release is
      **Latest** and the exe reports the tag.
- [ ] Excavator bumps the stable bucket. Do not hand-edit it.
- [ ] `scoop update nix` on the daily machine; `nix --version` matches the tag.

CI closes this issue and copies the completed checklist into the release notes
once the stable tag publishes. Nothing to delete by hand.
