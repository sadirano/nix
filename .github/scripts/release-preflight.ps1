param(
    [Parameter(Mandatory)] [string] $Tag,
    [string] $Repo = $env:GITHUB_REPOSITORY
)

$ErrorActionPreference = 'Stop'

$items = @(
    @{ Id = '1.1'; Name = 'Backup snapshot'; Checks = @(); Next = '' }
    @{ Id = '1.2'; Name = 'Daily install'; Checks = @(); Next = '' }
    @{ Id = '2.1'; Name = 'New terminal PATH'; Checks = @(); Next = '' }
    @{ Id = '3.1'; Name = 'Directory and action pickers'; Checks = @('registration', 'find', 'actions', 'engine', 'fzf'); Next = 'open both engines and run a pick' }
    @{ Id = '3.2'; Name = 'File and search pickers'; Checks = @('registration', 'find', 'explore', 'grep', 'engine', 'fzf', 'bat'); Next = 'open the f and s picks' }
    @{ Id = '3.3'; Name = 'Yank to Explorer'; Checks = @(); Next = '' }
    @{ Id = '3.4'; Name = 'Paste clipboard'; Checks = @(); Next = '' }
    @{ Id = '3.5'; Name = 'Everything fallback'; Checks = @(); Next = '' }
    @{ Id = '4.1'; Name = 'Provenance refusal'; Checks = @('registration', 'action'); Next = 'test a cloned action with and without a console' }
    @{ Id = '4.2'; Name = 'Trust and edits'; Checks = @(); Next = '' }
    @{ Id = '4.3'; Name = 'UAC action'; Checks = @(); Next = '' }
    @{ Id = '4.4'; Name = 'Secrets'; Checks = @(); Next = '' }
    @{ Id = '5.1'; Name = 'Bin exports'; Checks = @(); Next = '' }
    @{ Id = '6.1'; Name = 'Notifier hooks'; Checks = @(); Next = '' }
    @{ Id = '7.1'; Name = 'Doctor on real store'; Checks = @(); Next = '' }
    @{ Id = '8.1'; Name = 'Release CI and read-back'; Checks = @('readback', 'download', 'version'); Next = 'confirm the candidate CI run is green' }
    @{ Id = '8.2'; Name = 'Stable Scoop bucket'; Checks = @(); Next = '' }
    @{ Id = '8.3'; Name = 'Nightly Scoop'; Checks = @(); Next = '' }
    @{ Id = '8.4'; Name = 'Release notes'; Checks = @(); Next = '' }
)

$checks = @{}
foreach ($key in @('readback', 'download', 'version', 'registration', 'find', 'explore', 'grep', 'actions', 'action', 'engine', 'fzf', 'bat')) {
    $checks[$key] = @{ Ok = $false; Why = 'candidate asset unavailable' }
}

function Set-Check([string] $Key, [bool] $Ok, [string] $Why) {
    $script:checks[$Key] = @{ Ok = $Ok; Why = $Why }
}

function Invoke-Child([string] $File, [string[]] $Arguments, [int] $TimeoutMs = 30000) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $File
    $start.WorkingDirectory = $script:repoRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    foreach ($arg in $Arguments) { [void] $start.ArgumentList.Add($arg) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void] $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            # A hung tool must not leave the preflight waiting on its output pipe.
            try { $process.Kill() } catch {}
            [void] $process.WaitForExit(5000)
            return [pscustomobject]@{ Ok = $false; TimedOut = $true; Code = -1; Out = ''; Err = '' }
        }
        return [pscustomobject]@{
            Ok = ($process.ExitCode -eq 0)
            TimedOut = $false
            Code = $process.ExitCode
            Out = $stdout.GetAwaiter().GetResult()
            Err = $stderr.GetAwaiter().GetResult()
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; TimedOut = $false; Code = -1; Out = ''; Err = '' }
    } finally {
        $process.Dispose()
    }
}

function Child-Problem($Result, [string] $Command) {
    if ($Result.TimedOut) { return "$Command timed out" }
    if ($Result.Code -eq -1) { return "$Command could not start" }
    $diagnostic = "$($Result.Err)`n$($Result.Out)"
    if ($diagnostic -match '(?i)config\.yml.*Access is denied') { return "$Command could not read GitHub CLI config" }
    if ($diagnostic -match '(?i)Access is denied') { return "$Command access denied" }
    if ($diagnostic -match '(?i)could not resolve host|network is unreachable|connection refused') { return "$Command could not connect" }
    return "$Command exited $($Result.Code)"
}

function Check-DoctorRows([string] $Json) {
    try { $report = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch {
        foreach ($key in @('engine', 'fzf', 'bat')) { Set-Check $key $false 'doctor JSON did not parse' }
        return
    }
    $picker = @($report.sections | Where-Object { $_.name -eq "Picker  (unknown-alias 'o <name>')" })
    $optional = @($report.sections | Where-Object { $_.name -eq 'Optional tools' })
    if ($picker.Count -ne 1) {
        Set-Check 'engine' $false 'doctor picker section missing'
        Set-Check 'fzf' $false 'doctor picker section missing'
    } else {
        $engine = @($picker[0].rows | Where-Object { $_.label -eq 'engine' })
        if ($engine.Count -ne 1 -or $engine[0].status -ne 'ok') {
            Set-Check 'engine' $false 'doctor engine row missing or not ok'
            Set-Check 'fzf' $false 'doctor engine row missing or not ok'
        } elseif ($engine[0].detail -eq 'fzf') {
            Set-Check 'engine' $true ''
            $fzf = @($picker[0].rows | Where-Object { $_.label -eq 'fzf' })
            Set-Check 'fzf' ($fzf.Count -eq 1 -and $fzf[0].status -eq 'ok') 'doctor fzf row is not ok'
        } elseif ($engine[0].detail -like 'native*') {
            Set-Check 'engine' $true ''
            Set-Check 'fzf' $true ''
        } else {
            Set-Check 'engine' $false 'doctor engine is neither native nor fzf'
            Set-Check 'fzf' $false 'doctor engine is neither native nor fzf'
        }
    }
    if ($optional.Count -ne 1) {
        Set-Check 'bat' $false 'doctor optional tools section missing'
    } else {
        $bat = @($optional[0].rows | Where-Object { $_.label -eq 'bat' })
        Set-Check 'bat' ($bat.Count -eq 1 -and $bat[0].status -eq 'ok') 'doctor bat row is not ok'
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("nix-preflight-" + [guid]::NewGuid())
try {
    [void] [IO.Directory]::CreateDirectory($scratch)
    $homeDir = Join-Path $scratch 'home'
    $realHome = [IO.Path]::GetFullPath((Join-Path $HOME '.nix')).TrimEnd('\', '/')
    $testHome = [IO.Path]::GetFullPath($homeDir).TrimEnd('\', '/')
    if ([string]::Equals($realHome, $testHome, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'scratch NIX_HOME resolves to the real store'
    }
    [void] [IO.Directory]::CreateDirectory($homeDir)
    $env:NIX_HOME = $homeDir

    if (-not $Repo) {
        $found = Invoke-Child 'gh' @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')
        if (-not $found.Ok) { throw (Child-Problem $found 'gh repo view') }
        $Repo = $found.Out.Trim()
    }
    if (-not $Repo) { throw 'repository name is empty' }

    $readback = Invoke-Child 'pwsh' @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'release-readback.ps1'), '-Tag', $Tag, '-Repo', $Repo) 180000
    if ($readback.Ok) { Set-Check 'readback' $true '' }
    else { Set-Check 'readback' $false (Child-Problem $readback 'release read-back') }

    $asset = "nix-$Tag-windows-amd64.zip"
    $download = Invoke-Child 'gh' @('release', 'download', $Tag, '--repo', $Repo, '--pattern', $asset, '--dir', $scratch) 120000
    if (-not $download.Ok) {
        $downloadProblem = Child-Problem $download 'asset download'
        Set-Check 'download' $false $downloadProblem
        Set-Check 'registration' $false $downloadProblem
    } else {
        try {
            $extracted = Join-Path $scratch 'candidate'
            Expand-Archive -LiteralPath (Join-Path $scratch $asset) -DestinationPath $extracted -ErrorAction Stop
            $candidate = Join-Path $extracted 'nix.exe'
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'nix.exe is missing from the asset' }
            Set-Check 'download' $true ''
        } catch {
            Set-Check 'download' $false 'asset could not be extracted as nix.exe'
            Set-Check 'registration' $false 'candidate nix.exe is missing'
        }
    }

    if ($checks['download'].Ok) {
        $version = Invoke-Child $candidate @('--version')
        if (-not $version.Ok) {
            Set-Check 'version' $false (Child-Problem $version 'candidate --version')
        } elseif ($version.Out -match '(?m)^nix:\s+(\S+)') {
            Set-Check 'version' ($Matches[1] -ceq $Tag) 'candidate --version does not match the tag'
        } else {
            Set-Check 'version' $false 'candidate --version has no nix: token'
        }

        $alpha = Join-Path $scratch 'alpha'
        $beta = Join-Path $scratch 'beta'
        [void] [IO.Directory]::CreateDirectory($alpha)
        [void] [IO.Directory]::CreateDirectory($beta)
        Set-Content -LiteralPath (Join-Path $alpha 'notes one.txt') -Value 'preflight-marker' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $alpha 'other file.txt') -Value 'ordinary content' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $beta 'notes two.txt') -Value 'second project' -Encoding ascii

        $first = Invoke-Child $candidate @('pfa', $alpha)
        $second = Invoke-Child $candidate @('pfb', $beta)
        if (-not $first.Ok) {
            Set-Check 'registration' $false (Child-Problem $first 'pfa registration')
        } elseif (-not $second.Ok) {
            Set-Check 'registration' $false (Child-Problem $second 'pfb registration')
        } else {
            Set-Check 'registration' $true ''
        }

        if ($checks['registration'].Ok) {
            $actionDir = Join-Path $homeDir 'actions'
            [void] [IO.Directory]::CreateDirectory($actionDir)
            Set-Content -LiteralPath (Join-Path $actionDir 'pfa.toml') -Value @('[actions]', 'hello = "echo preflight-action"') -Encoding ascii

            $find = Invoke-Child $candidate @('pfa', '--no-prompt', '--find', 'notes')
            Set-Check 'find' ($find.Ok -and $find.Out.Contains('notes one.txt')) '--find did not list notes one.txt'
            if ($find.TimedOut) { Set-Check 'find' $false '--find timed out' }

            $explore = Invoke-Child $candidate @('pfa', '--no-prompt', '--explore', 'notes')
            Set-Check 'explore' ($explore.Ok -and $explore.Out.Contains('notes one.txt')) '--explore did not list notes one.txt'
            if ($explore.TimedOut) { Set-Check 'explore' $false '--explore timed out' }

            $grep = Invoke-Child $candidate @('pfa', '--no-prompt', '--grep', 'preflight-marker')
            Set-Check 'grep' ($grep.Ok -and $grep.Out.Contains('notes one.txt') -and $grep.Out.Contains('preflight-marker')) '--grep did not find the marker (rg required)'
            if ($grep.TimedOut) { Set-Check 'grep' $false '--grep timed out' }

            $actions = Invoke-Child $candidate @('--no-prompt', '--actions')
            Set-Check 'actions' ($actions.Ok -and $actions.Out -match '(?m)^\s*pfa\s+:hello\b') '--actions did not list pfa :hello'
            if ($actions.TimedOut) { Set-Check 'actions' $false '--actions timed out' }

            $agent = Invoke-Child $candidate @('--agent', 'x')
            if (-not $agent.Ok -or $agent.Out -notmatch 'nix <alias> --run' -or $agent.Out -notmatch '--no-prompt') {
                Set-Check 'action' $false 'candidate --agent x did not confirm the non-interactive form'
            } else {
                # The candidate documents --run as the canonical form of the x wrapper.
                $action = Invoke-Child $candidate @('pfa', '--no-prompt', '--run', ':hello')
                Set-Check 'action' ($action.Ok -and $action.Out.Contains('preflight-action')) 'central action did not print preflight-action'
                if ($action.TimedOut) { Set-Check 'action' $false 'central action timed out' }
            }

            $doctor = Invoke-Child $candidate @('--doctor', '--json')
            if ($doctor.TimedOut) {
                foreach ($key in @('engine', 'fzf', 'bat')) { Set-Check $key $false 'doctor timed out' }
            } elseif (-not $doctor.Out) {
                foreach ($key in @('engine', 'fzf', 'bat')) { Set-Check $key $false 'doctor produced no JSON' }
            } else {
                # Doctor can exit 1 for unrelated rows; the required rows decide these boxes.
                Check-DoctorRows $doctor.Out
            }
        }
    }
} catch {
    if ($checks['readback'].Why -eq 'candidate asset unavailable') {
        Set-Check 'readback' $false "preflight setup failed before read-back ($($_.Exception.GetType().Name))"
    }
    if ($checks['download'].Why -eq 'candidate asset unavailable') {
        Set-Check 'download' $false 'preflight setup failed before asset download'
    }
} finally {
    if (Test-Path -LiteralPath $scratch) {
        try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop }
        catch { Set-Check 'download' $false 'scratch cleanup failed' }
    }
}

$ready = 0
$failed = 0
$manual = 0
foreach ($item in $items) {
    if ($item.Checks.Count -eq 0) {
        Write-Output "MANUAL $($item.Id) $($item.Name) - nothing checked; do it by hand"
        $manual++
        continue
    }
    $problem = $null
    foreach ($key in $item.Checks) {
        if (-not $checks[$key].Ok) { $problem = $checks[$key].Why; break }
    }
    if ($problem) {
        Write-Output "FAIL   $($item.Id) $($item.Name) - $problem"
        $failed++
    } else {
        Write-Output "READY  $($item.Id) $($item.Name) - $($item.Next)"
        $ready++
    }
}
Write-Output "preflight: $ready ready, $failed failed, $manual manual"
if ($failed -gt 0) { exit 1 }
