# nix demo assets

Screen recordings and stills that showcase nix's capabilities, embedded in the
top-level `README.md` once captured.

These are **recorded by hand** (interactive fzf pickers, the Windows clipboard,
and Explorer don't reproduce faithfully under headless/scripted capture). The
recommended tool is [ScreenToGif](https://www.screentogif.com/) on Windows.

## Conventions

- **Format:** GIF for motion, PNG for stills.
- **Names:** kebab-case, matching the storyboard below (e.g. `sg-all.gif`).
- **Size:** record a terminal at ~**100×28** cells, export at **≤ 900 px** wide.
- **Frame rate:** 12–15 fps is plenty for a terminal and keeps files small.
- **Length:** keep each clip **under ~12 s** — one capability per clip.
- **Weight:** aim for **< 2 MB** per GIF (ScreenToGif → Save → reduce frame
  rate / remove duplicate frames / lossy-2). Large GIFs make the README crawl.

Set up a throwaway home first so nothing touches your real aliases:

```powershell
$env:ONIX_HOME = "$env:TEMP\nix-demo"
nix --init
# register a couple of demo aliases pointing at a sample project + a docs folder
nix acme  C:\demo\acme
nix docs  C:\demo\acme\documentation
```

Use a clean prompt and a legible theme (the docs assume the default Tokyo Night
fzf colors). Clear the screen before each take.

## Storyboard

Capture these, in rough priority order. The first three are the hero clips.

| File | Capability | What to show |
|------|------------|--------------|
| `navigate.gif` | `o` navigation | `o acme` cds in place; then `o newproj C:\demo\newproj` registers + cds in one step (dir auto-created); then `o somenoise` falls through to the directory picker. |
| `sg-all.gif` | **`sg --all` (ripgrep-all)** | `sg docs invoice --all` — fzf rows are individual matches *from inside a PDF*; arrow through them and show the preview re-focusing per match; press Enter on a PDF hit and it opens in the default viewer; contrast with a plain-text hit opening in the editor at the line. |
| `paste.gif` | `p` clipboard paste | Copy a screenshot (PrintScreen), run `p acme shot`; show `shot.png` written into the dir and its path copied back to the clipboard. Then copy a file in Explorer and `p acme` to show the cross-folder copy channel. |
| `sg.gif` | `sg` plain search | `sg acme TODO` → ripgrep matches stream into fzf with the bat preview; narrow by typing; Enter opens the hit in `$EDITOR` at the line. |
| `ff.gif` | `ff` fuzzy-find | `ff acme config` → es/fd into fzf; preview a file; Enter opens it. |
| `prune.gif` | `nix --prune` | The fzf multi-select ranked dead → never-used → least-recent; Tab to mark, Enter to remove. |
| `segments.gif` | sub-aliases | `o docs@acme` and `o tasks:432@acme` resolving `@`-segments. |
| `yank.png` | `y` (still) | `y acme` printing the path + "copied to clipboard". |

## Wiring into the README (do this once files exist)

Add a **Demos** section just under the intro paragraph in the top-level
`README.md`. Suggested embed (GitHub renders relative paths):

```markdown
## Demos

| | |
|---|---|
| **Jump to any project** — `o acme` | ![o navigation](assets/navigate.gif) |
| **Search inside PDFs & docs** — `sg docs invoice --all` | ![sg --all](assets/sg-all.gif) |
| **Clipboard → file from any prompt** — `p acme shot` | ![p paste](assets/paste.gif) |
```

Keep alt text descriptive (accessibility + shows if the image fails to load).
