# release-readback.ps1 - checks the release GitHub actually published, not the
# one the workflow meant to publish: the asset downloads, holds exactly nix.exe,
# that exe is the one built (when -Exe names it) and reports the tag, and the
# release is flagged the way Excavator and Scoop depend on.
#
#   release-readback.ps1 -Tag v0.12.0-pre1 [-Exe zig-out/bin/nix.exe] [-Repo owner/name]
#
# A tag with a `-` suffix (-pre1, -rc1, ...) must be a pre-release and never
# /releases/latest; any other tag must be the latest, non-draft, non-pre. It
# only reads, so it is as safe to run by hand as from the release workflow.

param(
    [Parameter(Mandatory)] [string] $Tag,
    [string] $Exe = '',
    [string] $Repo = $env:GITHUB_REPOSITORY
)

$ErrorActionPreference = 'Stop'
$failures = 0
function Fail([string] $msg) { Write-Host "FAIL $msg"; $script:failures++ }
function Pass([string] $msg) { Write-Host "ok   $msg" }

if (-not $Repo) { $Repo = (gh repo view --json nameWithOwner --jq .nameWithOwner) }
$asset = "nix-$Tag-windows-amd64.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) ("nix-readback-" + [guid]::NewGuid())
New-Item -ItemType Directory $work | Out-Null
try {
    gh release download $Tag --repo $Repo --pattern $asset --dir $work
    if ($LASTEXITCODE -ne 0) { throw "could not download $asset from $Tag" }

    Expand-Archive (Join-Path $work $asset) (Join-Path $work 'x')
    $members = @(Get-ChildItem -Recurse -File (Join-Path $work 'x') | ForEach-Object { $_.Name })
    if ($members.Count -eq 1 -and $members[0] -eq 'nix.exe') { Pass "the zip holds exactly nix.exe" }
    else { Fail "the zip holds: $($members -join ', ')" }

    $published = Join-Path $work 'x/nix.exe'
    if (Test-Path $published) {
        if ($Exe) {
            $want = (Get-FileHash $Exe -Algorithm SHA256).Hash
            $got = (Get-FileHash $published -Algorithm SHA256).Hash
            if ($want -eq $got) { Pass "the published exe is the one built ($got)" }
            else { Fail "the published exe $got is not the one built $want" }
        }
        $baked = (((& $published --version) | Select-Object -First 1) -split '\s+')[1]
        if ($baked -eq $Tag) { Pass "the published exe reports $Tag" }
        else { Fail "the published exe reports '$baked', not $Tag" }
    }

    $pre = $Tag.Contains('-')
    # GitHub can take a moment to settle which release is latest.
    for ($try = 1; $try -le 6; $try++) {
        $rel = gh api "repos/$Repo/releases/tags/$Tag" | ConvertFrom-Json
        $latest = gh api "repos/$Repo/releases/latest" --jq .tag_name
        $isLatest = $latest -eq $Tag
        if ($rel.prerelease -eq $pre -and -not $rel.draft -and $isLatest -ne $pre) { break }
        if ($try -lt 6) { Start-Sleep -Seconds 5 }
    }
    if ($rel.draft) { Fail "$Tag is still a draft" } else { Pass "$Tag is published, not a draft" }
    if ($rel.prerelease -eq $pre) { Pass "$Tag prerelease=$pre" }
    else { Fail "$Tag prerelease=$($rel.prerelease), expected $pre" }
    if ($pre -and $isLatest) { Fail "$Tag is /releases/latest - Excavator would move the stable bucket to it" }
    elseif ($pre) { Pass "/releases/latest is $latest, not the pre-release" }
    elseif ($isLatest) { Pass "$Tag is /releases/latest" }
    else { Fail "/releases/latest is $latest, not $Tag" }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "release readback: $failures failed"; exit 1 }
Write-Host "release readback: all passed"
