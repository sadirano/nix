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
$env:NIX_HOME = "$env:TEMP\nix-demo"
nix --init
# register a couple of demo aliases pointing at a sample project + a docs folder
nix acme  C:\demo\acme
nix docs  C:\demo\acme\documentation
```

Use a clean prompt and a legible theme (the docs assume the default Tokyo Night
fzf colors). Clear the screen before each take.

## Storyboard

The hero clips (`navigate.gif`, `sg-all.gif`, `paste.gif`) are captured and
embedded in the README's Demos section. One clip is still planned:
`segments.gif` — `o docs@acme` and `o tasks:432@acme` resolving `@`-segments.
It embeds in the same Demos section with descriptive alt text (accessibility +
shows if the image fails to load).
