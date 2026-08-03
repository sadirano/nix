<#
  set_vars.ps1 - a nix context source, PowerShell flavour.

  Place at <project>\.nix\scripts\set_vars.ps1 and declare it in
  <project>\.nix\segments.toml:

    [[contexts]]
    segment = "task"
    run = "set_vars ${task}"
    source-template = "/${client_name}/${task}"
    cache = "1h"

  Then `o task:123@project` lands in <project>\acme\123.

  nix invokes .ps1 through pwsh (else powershell) with -NoProfile
  -ExecutionPolicy Bypass -File, so no execution-policy setup is needed.

  Contract:
    in   arguments from the `run` line; $env:NIX_SEGMENT, NIX_SEGMENT_VALUE,
         NIX_ALIAS, NIX_ALIAS_PATH are also set
    out  KEY=VALUE lines appended to the file named by $env:NIX_CONTEXT_OUT,
         optionally several blocks separated by a `---` line - one per
         candidate, offered as a menu
    exit non-zero aborts resolution and nothing is cached

  Write-Host output is relayed to stderr for the user; it can never be mistaken
  for a returned value.
#>

param(
    [string] $Task
)

$ErrorActionPreference = 'Stop'

# Add-Content with an explicit ASCII/UTF8NoBOM encoding throughout: Windows
# PowerShell 5.1's `Out-File -Encoding utf8` emits a BOM, which would otherwise
# ride along into the first key name. (nix strips a leading BOM defensively,
# but being explicit here keeps the file readable in any editor.)
function Emit([string] $line) {
    Add-Content -Path $env:NIX_CONTEXT_OUT -Value $line -Encoding ascii
}

# No ticket named: answer with the candidates instead of failing. One block per
# ticket, separated by `---`; `_display` is the row the user picks by and never
# becomes a variable. Nix shows a picker only when more than one block comes
# back, so a lookup that finds exactly one still navigates straight there - the
# menu is a property of the answer, not a mode to declare.
if ([string]::IsNullOrWhiteSpace($Task)) {
    Write-Host 'Listing open tickets...'
    # --- Replace with the real query, one block per result. -----------------
    foreach ($t in @(
            @{ id = '123'; client = 'acme'; title = 'Fix login flow' },
            @{ id = '140'; client = 'initech'; title = 'Rate limiter' })) {
        Emit "_display=PROJ-$($t.id)  $($t.title)"
        Emit "task=$($t.id)"
        Emit "client_name=$($t.client)"
        Emit '---'
    }
    exit 0
}

Write-Host "Looking up ticket $Task..."

# --- Replace this block with the real lookup. -------------------------------
# $client = (Invoke-RestMethod "https://tracker/api/ticket/$Task").client
$client = 'acme'
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($client)) {
    Write-Error "ticket $Task has no client"
    exit 1
}

Emit "client_name=$client"

exit 0
