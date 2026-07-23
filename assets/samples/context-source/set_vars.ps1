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
    out  KEY=VALUE lines appended to the file named by $env:NIX_CONTEXT_OUT
    exit non-zero aborts resolution and nothing is cached

  Write-Host output is relayed to stderr for the user; it can never be mistaken
  for a returned value.
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $Task
)

$ErrorActionPreference = 'Stop'

Write-Host "Looking up ticket $Task..."

# --- Replace this block with the real lookup. -------------------------------
# $client = (Invoke-RestMethod "https://tracker/api/ticket/$Task").client
$client = 'acme'
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($client)) {
    Write-Error "ticket $Task has no client"
    exit 1
}

# Add-Content with an explicit ASCII/UTF8NoBOM encoding: Windows PowerShell
# 5.1's `Out-File -Encoding utf8` emits a BOM, which would otherwise ride along
# into the first key name. (nix strips a leading BOM defensively, but being
# explicit here keeps the file readable in any editor.)
Add-Content -Path $env:NIX_CONTEXT_OUT -Value "client_name=$client" -Encoding ascii

exit 0
