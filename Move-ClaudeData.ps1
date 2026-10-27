#Requires -Version 5.1
<#
  Move-ClaudeData.ps1

  Relocates Claude Desktop's data/cache folder to a location of your
  choosing, then leaves an NTFS junction behind so Claude keeps working
  without any reconfiguration.

  BACKGROUND:
  Claude Desktop is normally installed as an MSIX-packaged ("Desktop
  Bridge") app. Windows transparently bind-redirects the app's view of
  %APPDATA%\Claude to a real backing folder under:
    %LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Roaming\Claude
  That redirection sits below the NTFS reparse-point layer, so placing a
  junction or symlink directly on %APPDATA%\Claude gets silently shadowed
  and does nothing. This script finds the REAL backing folder and junctions
  that instead. If Claude isn't installed as an MSIX package on your
  machine, it falls back to junctioning %APPDATA%\Claude / %LOCALAPPDATA%\Claude
  directly, which works fine in that case.

  USAGE:
    Just run it and follow the prompts:
      .\Move-ClaudeData.ps1

    Or pass the destination and skip prompts:
      .\Move-ClaudeData.ps1 -TargetRoot "D:\DevTools\Claude" -Force

    -Force never overwrites an existing, non-empty destination folder on its
    own - that always requires -AllowOverwrite as well (with -Force, it then
    proceeds without asking; without -Force, it still asks for confirmation).

  The script is safe to re-run: folders already converted to junctions are
  skipped. Nothing is deleted — the original data is renamed to a
  ".bak-<timestamp>" folder alongside itself, which you can remove by hand
  once you've confirmed Claude works correctly.

  TO UNDO a migration: delete the junction at the original path (a plain
  `Remove-Item <original path>` removes just the junction, not the data it
  points to), then rename the matching "<original path>.bak-<timestamp>"
  folder back to its original name.

  Requires: Windows, PowerShell 5.1+, no admin rights needed (junctions,
  unlike symlinks, don't require elevation or Developer Mode).
#>

[CmdletBinding()]
param(
    [string]$TargetRoot,
    [switch]$Force,
    [switch]$AllowOverwrite,
    [switch]$DeleteBackup
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg)  { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Warn2([string]$msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Ok([string]$msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Err2([string]$msg)  { Write-Host "    $msg" -ForegroundColor Red }

# Exact executable name Claude Desktop runs as - deliberately NOT a wildcard
# like "Claude*", so we never touch an unrelated app that happens to match.
$ClaudeProcessName = "Claude"

# ---------------------------------------------------------------------------
# 1. Find Claude's real data folder(s) - packaged (MSIX) or plain install
# ---------------------------------------------------------------------------
Write-Step "Looking for your Claude Desktop installation"

$pkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "AnthropicPBC.Claude_*" -ErrorAction SilentlyContinue |
       Select-Object -First 1

$mappings = @()

if ($pkg) {
    Write-Ok "Found MSIX package: $($pkg.Name)"
    $localCache = Join-Path $pkg.FullName "LocalCache"
    $mappings = @(
        @{ Label = "Roaming"; Real = Join-Path $localCache "Roaming\Claude" }
        @{ Label = "Local";   Real = Join-Path $localCache "Local\Claude" }
    ) | Where-Object { Test-Path $_.Real }
} else {
    Write-Warn2 "No MSIX package found; checking for a plain (non-packaged) install"
    $mappings = @(
        @{ Label = "Roaming"; Real = Join-Path $env:APPDATA "Claude" }
        @{ Label = "Local";   Real = Join-Path $env:LOCALAPPDATA "Claude" }
    ) | Where-Object { Test-Path $_.Real }

    if ($mappings) {
        Write-Warn2 "WARNING: this is the fallback path. It junctions %APPDATA%\Claude / %LOCALAPPDATA%\Claude"
        Write-Warn2 "directly, which is only correct if Claude actually reads/writes those folders as a"
        Write-Warn2 "plain (non-packaged) install. If you're unsure, cancel and check with 'tasklist' /"
        Write-Warn2 "Task Manager -> Claude -> Open file location to confirm how it's installed."
        $fallbackAnswer = Read-Host "    Type YES to continue with the fallback folders"
        if ($fallbackAnswer -cne 'YES') {
            Write-Host "Aborted, nothing was changed." -ForegroundColor Red
            return
        }
    }
}

if (-not $mappings) {
    throw "Could not find a Claude data folder on this machine. Is Claude Desktop installed?"
}

foreach ($m in $mappings) {
    Write-Info ("Found {0,-8} {1}" -f $m.Label, $m.Real)
}

# ---------------------------------------------------------------------------
# 2. Ask where to put it
# ---------------------------------------------------------------------------
if (-not $TargetRoot) {
    Write-Step "Where do you want Claude's data stored?"
    Write-Info "Example: D:\Claude  or  E:\Apps\ClaudeData"
    $TargetRoot = Read-Host "    Destination folder"
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        Write-Err2 "No destination given. Aborting."
        return
    }
}

$driveLetter = (Split-Path -Qualifier $TargetRoot -ErrorAction SilentlyContinue)
if ($driveLetter) {
    $vol = Get-Volume -DriveLetter $driveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($vol -and $vol.FileSystemType -ne 'NTFS') {
        throw "Destination drive $driveLetter is $($vol.FileSystemType), not NTFS. Junctions require NTFS on both ends."
    }
}

Write-Ok "Target: $TargetRoot"

Write-Info "Plan:"
foreach ($m in $mappings) {
    $m.Target = Join-Path $TargetRoot $m.Label
    Write-Info ("  {0,-8} {1}  ->  {2}" -f $m.Label, $m.Real, $m.Target)
}

if (-not $Force) {
    $answer = Read-Host "`n    Proceed? (y/N)"
    if ($answer -notmatch '^[Yy]') {
        Write-Host "Aborted, nothing was changed." -ForegroundColor Red
        return
    }
}

# ---------------------------------------------------------------------------
# 3. Skip mappings that are already junctions (already migrated)
# ---------------------------------------------------------------------------
$pending = @()
foreach ($m in $mappings) {
    $item = Get-Item -LiteralPath $m.Real -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Ok "$($m.Label): already a junction -> skipping"
    } else {
        $pending += $m
    }
}

if (-not $pending) {
    Write-Step "Nothing to do"
    Write-Ok "All folders are already junctioned."
    return
}

# ---------------------------------------------------------------------------
# 4. Close Claude if it's running
# ---------------------------------------------------------------------------
Write-Step "Checking for running Claude processes"

$procs = Get-Process -Name $ClaudeProcessName -ErrorAction SilentlyContinue
if ($procs) {
    Write-Warn2 "The following process(es) named '$ClaudeProcessName' must be closed before moving its data:"
    $procs | ForEach-Object { Write-Info ("  PID {0,-7} {1}" -f $_.Id, $_.Path) }
    if (-not $Force) {
        $answer = Read-Host "    Close these now and continue? (y/N)"
        if ($answer -notmatch '^[Yy]') {
            Write-Host "Aborted. Close Claude manually and re-run this script." -ForegroundColor Red
            return
        }
    }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Get-Process -Name $ClaudeProcessName -ErrorAction SilentlyContinue) {
        throw "Claude is still running after Stop-Process. Close it manually (check the system tray too) and re-run."
    }
    Write-Ok "Claude closed."
} else {
    Write-Ok "Claude is not running."
}

# ---------------------------------------------------------------------------
# 5. Create target root
# ---------------------------------------------------------------------------
Write-Step "Preparing destination"
New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
Write-Ok "Destination root: $TargetRoot"

# ---------------------------------------------------------------------------
# 6. Mirror each real folder to its target, then junction it
#
# NOTE ON FAILURE MODES:
# - Each mapping is migrated independently. If one mapping fails partway
#   through, mappings already junctioned successfully are left as-is;
#   re-running this script skips them (step 3 above) and retries only
#   what's left - nothing needs to be undone by hand for those.
# - The rename -> mklink pair for a single mapping is NOT atomic. If the
#   script is killed in that narrow window, the folder will briefly be
#   missing from its original path. To restore it by hand, rename the
#   "<original path>.bak-<timestamp>" folder back to its original name.
# ---------------------------------------------------------------------------
$completed = @()
try {
foreach ($m in $pending) {
    Write-Step "Migrating '$($m.Label)' data"

    if (Test-Path $m.Target) {
        $existing = Get-ChildItem $m.Target -Force -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Warn2 "Destination '$($m.Target)' already has content in it."
            Write-Warn2 "The next step mirrors the source into it with robocopy /MIR, which DELETES anything"
            Write-Warn2 "in the destination that isn't also in the source."
            if ($AllowOverwrite) {
                if (-not $Force) {
                    $answer = Read-Host "    Continue and overwrite/remove mismatched files in '$($m.Target)'? (y/N)"
                    if ($answer -notmatch '^[Yy]') {
                        throw "Aborted before touching '$($m.Target)'. $($completed.Count) of $($pending.Count) folder(s) already migrated in this run (they were skipped on re-run)."
                    }
                }
            } else {
                # Refuse outright: -Force alone must never silently wipe existing
                # destination content. -AllowOverwrite is required to even be asked.
                throw "Refusing to touch non-empty destination '$($m.Target)' without -AllowOverwrite. $($completed.Count) of $($pending.Count) folder(s) already migrated in this run (they were skipped on re-run). Re-run with -AllowOverwrite if you really want to mirror over its existing content."
            }
        }
    }

    New-Item -ItemType Directory -Path $m.Target -Force | Out-Null

    $sizeMB = [math]::Round(((Get-ChildItem $m.Real -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum) / 1MB, 1)
    Write-Info "Copying $($m.Real) ($sizeMB MB) -> $($m.Target) (this can take a while for large caches)"
    $log = Join-Path $env:TEMP "claude-move-$($m.Label)-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    & robocopy $m.Real $m.Target /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:2 /NP /NFL /NDL /LOG:$log | Out-Null
    $rc = $LASTEXITCODE

    # Robocopy exit codes 0-7 are success states; 8+ indicate failure.
    if ($rc -ge 8) {
        throw "Robocopy failed for $($m.Label) (exit code $rc). See log: $log"
    }
    Write-Ok "Copy complete (robocopy exit code $rc). Log: $log"

    $backup = "$($m.Real).bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Info "Backing up original folder to: $backup"
    try {
        Rename-Item -LiteralPath $m.Real -NewName (Split-Path $backup -Leaf) -ErrorAction Stop
    } catch {
        throw "Could not rename $($m.Real): $($_.Exception.Message)`nMake sure Claude (and any background helper processes) are fully closed, then re-run. If it persists, try running this script from an elevated PowerShell window."
    }

    Write-Info "Creating junction: $($m.Real)  =>  $($m.Target)"
    $mklinkOut = cmd /c mklink /J "`"$($m.Real)`"" "`"$($m.Target)`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Rename-Item -LiteralPath $backup -NewName (Split-Path $m.Real -Leaf) -ErrorAction SilentlyContinue
        throw "mklink failed for $($m.Label): $mklinkOut"
    }

    $verify = Get-Item -LiteralPath $m.Real -Force
    if (-not ($verify.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Verification failed: $($m.Real) is not a reparse point after mklink."
    }
    Write-Ok "$($m.Label) junction verified."

    if ($DeleteBackup) {
        Write-Info "Removing backup copy $backup"
        Remove-Item -LiteralPath $backup -Recurse -Force
        Write-Ok "Backup removed."
    } else {
        Write-Info "Backup kept at: $backup (delete manually once you've confirmed Claude works)"
    }

    $completed += $m.Label
}
} catch {
    Write-Err2 "Failed while migrating: $($_.Exception.Message)"
    if ($completed) {
        Write-Warn2 "Already migrated successfully before this failure: $($completed -join ', ')"
        Write-Warn2 "Those are fine as-is - re-running this script will skip them and retry only what's left."
    }
    throw
}

Write-Step "Done"
Write-Ok "Claude's data now physically lives under: $TargetRoot"
Write-Info "Start Claude again and confirm your chats/settings are intact before deleting any .bak-* folders."
