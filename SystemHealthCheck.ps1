<#
.SYNOPSIS
    Quick system health check: disk space, Windows Defender status, top CPU processes.
.DESCRIPTION
    Writes a plain-text report and echoes results to the console.
    Exit code 1 if any warning was raised, 0 otherwise.
.PARAMETER OutputPath
    Full path for the .txt report. Defaults to the desktop with a timestamped name.
.PARAMETER DiskThresholdPercent
    Free-space percentage below which a warning is raised. Default 20.
.EXAMPLE
    .\SystemHealthCheck.ps1
    .\SystemHealthCheck.ps1 -OutputPath C:\Reports\health.txt -DiskThresholdPercent 15
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) ("HealthReport_{0}_{1:yyyyMMdd_HHmmss}.txt" -f $env:COMPUTERNAME, (Get-Date))),
    [ValidateRange(1, 99)]
    [int]$DiskThresholdPercent = 20
)

$ErrorActionPreference = 'Stop'
$report   = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-Line { param([string]$Text = '') $report.Add($Text) | Out-Null }

Add-Line ('=' * 64)
Add-Line "SYSTEM HEALTH REPORT"
Add-Line ('=' * 64)
Add-Line "Computer  : $env:COMPUTERNAME"
Add-Line "User      : $env:USERDOMAIN\$env:USERNAME"
Add-Line "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
Add-Line "PowerShell: $($PSVersionTable.PSVersion)"
Add-Line ''

# --- 1. Disk space on C: -------------------------------------------------
Add-Line ('-' * 64)
Add-Line "1. DISK SPACE (C:)"
Add-Line ('-' * 64)
try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
    if (-not $disk -or -not $disk.Size) { throw "C: drive not found or reports zero size." }

    $totalGB   = [math]::Round($disk.Size / 1GB, 2)
    $freeGB    = [math]::Round($disk.FreeSpace / 1GB, 2)
    $usedGB    = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
    $freePct   = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)

    Add-Line ("Total       : {0} GB" -f $totalGB)
    Add-Line ("Used        : {0} GB" -f $usedGB)
    Add-Line ("Free        : {0} GB ({1}%)" -f $freeGB, $freePct)
    Add-Line ("Threshold   : {0}%" -f $DiskThresholdPercent)

    if ($freePct -lt $DiskThresholdPercent) {
        $msg = "LOW DISK SPACE: C: has only $freePct% free (below $DiskThresholdPercent% threshold)."
        Add-Line ("Status      : *** WARNING ***")
        $warnings.Add($msg) | Out-Null
        Write-Warning $msg
    }
    else {
        Add-Line "Status      : OK"
    }
}
catch {
    $msg = "Disk check failed: $($_.Exception.Message)"
    Add-Line "Status      : ERROR - $($_.Exception.Message)"
    $warnings.Add($msg) | Out-Null
    Write-Warning $msg
}
Add-Line ''

# --- 2. Windows Defender -------------------------------------------------
Add-Line ('-' * 64)
Add-Line "2. WINDOWS DEFENDER"
Add-Line ('-' * 64)
try {
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        throw "Get-MpComputerStatus is unavailable (Defender module not present)."
    }

    $mp = Get-MpComputerStatus

    Add-Line ("Antivirus enabled      : {0}" -f $mp.AntivirusEnabled)
    Add-Line ("Real-time protection   : {0}" -f $mp.RealTimeProtectionEnabled)
    Add-Line ("Antispyware enabled    : {0}" -f $mp.AntispywareEnabled)
    Add-Line ("Tamper protection      : {0}" -f $mp.IsTamperProtected)
    Add-Line ("Signature version      : {0}" -f $mp.AntivirusSignatureVersion)
    Add-Line ("Signature age (days)   : {0}" -f $mp.AntivirusSignatureAge)
    Add-Line ("Last quick scan        : {0}" -f $mp.QuickScanEndTime)
    Add-Line ("Last full scan         : {0}" -f $mp.FullScanEndTime)

    if (-not $mp.AntivirusEnabled) {
        $msg = "Windows Defender antivirus is DISABLED."
        Add-Line "Status                 : *** WARNING ***"
        $warnings.Add($msg) | Out-Null
        Write-Warning $msg
    }
    elseif (-not $mp.RealTimeProtectionEnabled) {
        $msg = "Defender is enabled but real-time protection is OFF."
        Add-Line "Status                 : *** WARNING ***"
        $warnings.Add($msg) | Out-Null
        Write-Warning $msg
    }
    else {
        Add-Line "Status                 : OK"
    }

    if ($mp.AntivirusSignatureAge -gt 7) {
        $msg = "Defender signatures are $($mp.AntivirusSignatureAge) days old."
        $warnings.Add($msg) | Out-Null
        Write-Warning $msg
    }
}
catch {
    $msg = "Defender check failed: $($_.Exception.Message)"
    Add-Line "Status                 : ERROR - $($_.Exception.Message)"
    $warnings.Add($msg) | Out-Null
    Write-Warning $msg
}
Add-Line ''

# --- 3. Top 10 processes by CPU ------------------------------------------
Add-Line ('-' * 64)
Add-Line "3. TOP 10 PROCESSES BY CPU TIME"
Add-Line ('-' * 64)
try {
    $procs = Get-Process |
        Where-Object { $_.CPU -ne $null } |
        Sort-Object CPU -Descending |
        Select-Object -First 10 -Property `
            @{N='Name';       E={$_.ProcessName}},
            @{N='PID';        E={$_.Id}},
            @{N='CPU(s)';     E={[math]::Round($_.CPU, 2)}},
            @{N='Memory(MB)'; E={[math]::Round($_.WorkingSet64 / 1MB, 1)}},
            @{N='Threads';    E={$_.Threads.Count}}

    if ($procs) {
        ($procs | Format-Table -AutoSize | Out-String).TrimEnd().Split("`n") | ForEach-Object { Add-Line $_.TrimEnd() }
    }
    else {
        Add-Line "No process CPU data available."
    }
}
catch {
    Add-Line "ERROR - $($_.Exception.Message)"
    Write-Warning "Process check failed: $($_.Exception.Message)"
}
Add-Line ''

# --- Summary -------------------------------------------------------------
Add-Line ('=' * 64)
Add-Line "SUMMARY"
Add-Line ('=' * 64)
if ($warnings.Count -eq 0) {
    Add-Line "No issues detected."
}
else {
    Add-Line "$($warnings.Count) warning(s):"
    $i = 1
    foreach ($w in $warnings) { Add-Line "  $i. $w"; $i++ }
}
Add-Line ('=' * 64)

# --- Write report --------------------------------------------------------
try {
    $dir = Split-Path -Path $OutputPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $report -join [Environment]::NewLine | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host ''
    $report | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "Report saved to: $OutputPath" -ForegroundColor Green
}
catch {
    Write-Error "Could not write report to '$OutputPath': $($_.Exception.Message)"
    exit 2
}

exit ([int]($warnings.Count -gt 0))
