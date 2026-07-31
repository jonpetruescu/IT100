<#
.SYNOPSIS
    Script 1 - System Health Check.

.DESCRIPTION
    Checks disk space on all fixed drives, average CPU load sampled over a
    30-second window, available physical memory, and the top 5 processes by
    CPU. Writes a formatted report to C:\Temp\healthcheck_<date>.txt.

    Thresholds (all overridable):
      Disk   - warn if free space < 20%
      CPU    - warn if 30-second average > 80%
      Memory - warn if available < 500 MB

.PARAMETER OutputDirectory
    Folder for the report. Created if missing. Default C:\Temp.

.PARAMETER DiskThresholdPercent
    Free-space percentage below which a drive is flagged. Default 20.

.PARAMETER CpuThresholdPercent
    Average CPU percentage above which the host is flagged. Default 80.

.PARAMETER MemoryThresholdMB
    Available memory in MB below which the host is flagged. Default 500.

.PARAMETER SampleSeconds
    Length of the CPU sampling window in seconds. Default 30.

.PARAMETER Quiet
    Suppress console output; still writes the report and sets the exit code.

.OUTPUTS
    Exit code 0 = healthy, 1 = one or more warnings, 2 = report could not be written.

.EXAMPLE
    .\Invoke-SystemHealthCheck.ps1

.EXAMPLE
    .\Invoke-SystemHealthCheck.ps1 -SampleSeconds 10 -MemoryThresholdMB 1024 -Quiet
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory     = 'C:\Temp',
    [ValidateRange(1, 99)][int]$DiskThresholdPercent = 20,
    [ValidateRange(1, 100)][int]$CpuThresholdPercent = 80,
    [ValidateRange(1, 1048576)][int]$MemoryThresholdMB = 500,
    [ValidateRange(1, 3600)][int]$SampleSeconds = 30,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$report   = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-Line { param([string]$Text = '') $report.Add($Text) | Out-Null }
function Add-Warn {
    param([string]$Text)
    $warnings.Add($Text) | Out-Null
    if (-not $Quiet) { Write-Warning $Text }
}
function Add-Header {
    param([string]$Title)
    Add-Line ''
    Add-Line ('-' * 72)
    Add-Line $Title
    Add-Line ('-' * 72)
}

# ============================================================ HEADER
$startTime = Get-Date
Add-Line ('=' * 72)
Add-Line '                     SYSTEM HEALTH CHECK REPORT'
Add-Line ('=' * 72)
Add-Line ("Computer    : {0}" -f $env:COMPUTERNAME)
Add-Line ("User        : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Add-Line ("Generated   : {0:yyyy-MM-dd HH:mm:ss} ({1})" -f $startTime, [System.TimeZoneInfo]::Local.StandardName)
Add-Line ("PowerShell  : {0}" -f $PSVersionTable.PSVersion)
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Add-Line ("OS          : {0} (build {1})" -f $os.Caption.Trim(), $os.BuildNumber)
    Add-Line ("Uptime      : {0:dd}d {0:hh}h {0:mm}m" -f (New-TimeSpan -Start $os.LastBootUpTime -End $startTime))
}
catch {
    $os = $null
    Add-Line "OS          : unavailable ($($_.Exception.Message))"
}
Add-Line ("Thresholds  : disk <{0}% free | CPU >{1}% avg over {2}s | memory <{3} MB free" -f `
    $DiskThresholdPercent, $CpuThresholdPercent, $SampleSeconds, $MemoryThresholdMB)

# ============================================================ 1. DISKS
Add-Header '1. DISK SPACE - ALL FIXED DRIVES'
try {
    # DriveType 3 = local fixed disk
    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID

    if (-not $disks) {
        Add-Line 'No fixed drives detected.'
    }
    else {
        $rows = foreach ($d in $disks) {
            if (-not $d.Size) { continue }   # unformatted / inaccessible volume
            $freePct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
            $low     = $freePct -lt $DiskThresholdPercent

            if ($low) {
                Add-Warn ("Low disk space on {0} - {1}% free ({2} GB of {3} GB), threshold {4}%." -f `
                    $d.DeviceID,
                    $freePct,
                    [math]::Round($d.FreeSpace / 1GB, 1),
                    [math]::Round($d.Size / 1GB, 1),
                    $DiskThresholdPercent)
            }

            [pscustomobject]@{
                Drive     = $d.DeviceID
                Label     = if ([string]::IsNullOrWhiteSpace($d.VolumeName)) { '-' } else { $d.VolumeName }
                'Total GB' = [math]::Round($d.Size / 1GB, 1)
                'Used GB'  = [math]::Round(($d.Size - $d.FreeSpace) / 1GB, 1)
                'Free GB'  = [math]::Round($d.FreeSpace / 1GB, 1)
                'Free %'   = $freePct
                Status    = if ($low) { 'WARNING' } else { 'OK' }
            }
        }

        if ($rows) {
            ($rows | Format-Table -AutoSize | Out-String).Trim() -split "`r?`n" |
                ForEach-Object { Add-Line $_.TrimEnd() }
        }
        else {
            Add-Line 'No readable fixed volumes.'
        }
    }
}
catch {
    Add-Line "ERROR: $($_.Exception.Message)"
    Add-Warn "Disk check failed: $($_.Exception.Message)"
}

# ============================================================ 2. CPU (+ process sampling)
Add-Header ("2. CPU LOAD - {0}-SECOND AVERAGE" -f $SampleSeconds)

$cpuAvg = $null
$cpuSamples = @()

# Snapshot process CPU time before the sampling window so section 3 can
# report actual CPU usage during the window rather than lifetime totals.
$procBefore = @{}
try {
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        if ($null -ne $p.CPU) { $procBefore[$p.Id] = $p.CPU }
    }
}
catch { }

try {
    if (-not $Quiet) { Write-Host "Sampling CPU for $SampleSeconds seconds..." -ForegroundColor Cyan }

    # Get-Counter path names are localised on non-English Windows; fall back to CIM.
    try {
        $counter = Get-Counter -Counter '\Processor(_Total)\% Processor Time' `
                               -SampleInterval 1 -MaxSamples $SampleSeconds
        $cpuSamples = $counter.CounterSamples.CookedValue
    }
    catch {
        $cpuSamples = for ($i = 0; $i -lt $SampleSeconds; $i++) {
            (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
            Start-Sleep -Seconds 1
        }
    }

    $stats  = $cpuSamples | Measure-Object -Average -Maximum -Minimum
    $cpuAvg = [math]::Round($stats.Average, 1)

    Add-Line ("Samples taken   : {0} (1-second interval)" -f $stats.Count)
    Add-Line ("Average load    : {0}%" -f $cpuAvg)
    Add-Line ("Peak load       : {0}%" -f [math]::Round($stats.Maximum, 1))
    Add-Line ("Minimum load    : {0}%" -f [math]::Round($stats.Minimum, 1))
    Add-Line ("Logical cores   : {0}" -f [Environment]::ProcessorCount)

    if ($cpuAvg -gt $CpuThresholdPercent) {
        Add-Line 'Status          : *** WARNING ***'
        Add-Warn ("Sustained high CPU - {0}% average over {1}s, threshold {2}%." -f `
            $cpuAvg, $SampleSeconds, $CpuThresholdPercent)
    }
    else {
        Add-Line 'Status          : OK'
    }
}
catch {
    Add-Line "ERROR: $($_.Exception.Message)"
    Add-Warn "CPU check failed: $($_.Exception.Message)"
}

# ============================================================ 3. MEMORY
Add-Header '3. PHYSICAL MEMORY'
try {
    if (-not $os) { $os = Get-CimInstance Win32_OperatingSystem }

    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)   # value is in KB
    $freeMB  = [math]::Round($os.FreePhysicalMemory     / 1KB, 0)
    $usedMB  = $totalMB - $freeMB
    $freePct = if ($totalMB) { [math]::Round(($freeMB / $totalMB) * 100, 1) } else { 0 }

    Add-Line ("Total       : {0:N0} MB ({1} GB)" -f $totalMB, [math]::Round($totalMB / 1024, 1))
    Add-Line ("In use      : {0:N0} MB ({1}%)" -f $usedMB, [math]::Round(100 - $freePct, 1))
    Add-Line ("Available   : {0:N0} MB ({1}%)" -f $freeMB, $freePct)
    Add-Line ("Threshold   : {0:N0} MB" -f $MemoryThresholdMB)

    if ($freeMB -lt $MemoryThresholdMB) {
        Add-Line 'Status      : *** WARNING ***'
        Add-Warn ("Low memory - {0:N0} MB available, threshold {1:N0} MB." -f $freeMB, $MemoryThresholdMB)
    }
    else {
        Add-Line 'Status      : OK'
    }
}
catch {
    Add-Line "ERROR: $($_.Exception.Message)"
    Add-Warn "Memory check failed: $($_.Exception.Message)"
}

# ============================================================ 4. TOP 5 PROCESSES
Add-Header '4. TOP 5 PROCESSES BY CPU'
try {
    $cores   = [Environment]::ProcessorCount
    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    $useDelta = $procBefore.Count -gt 0 -and $elapsed -gt 1

    $procs = foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        if ($null -eq $p.CPU) { continue }

        # CPU seconds consumed during the sampling window, normalised across cores.
        $deltaPct = $null
        if ($useDelta -and $procBefore.ContainsKey($p.Id)) {
            $deltaPct = [math]::Round((($p.CPU - $procBefore[$p.Id]) / $elapsed / $cores) * 100, 1)
        }

        [pscustomobject]@{
            Name        = $p.ProcessName
            PID         = $p.Id
            'CPU %'     = if ($null -ne $deltaPct) { $deltaPct } else { 'n/a' }
            'CPU (s)'   = [math]::Round($p.CPU, 1)
            'Mem (MB)'  = [math]::Round($p.WorkingSet64 / 1MB, 1)
            Threads     = $p.Threads.Count
            SortKey     = if ($null -ne $deltaPct) { $deltaPct } else { -1 }
        }
    }

    $top = $procs | Sort-Object SortKey, 'CPU (s)' -Descending |
                    Select-Object -First 5 -ExcludeProperty SortKey

    if ($top) {
        Add-Line ("CPU % measured over the {0}s sampling window, normalised across {1} logical cores." -f `
            [math]::Round($elapsed, 0), $cores)
        Add-Line ''
        ($top | Format-Table -AutoSize | Out-String).Trim() -split "`r?`n" |
            ForEach-Object { Add-Line $_.TrimEnd() }
    }
    else {
        Add-Line 'No process CPU data available.'
    }
}
catch {
    Add-Line "ERROR: $($_.Exception.Message)"
    Add-Warn "Process check failed: $($_.Exception.Message)"
}

# ============================================================ SUMMARY
Add-Line ''
Add-Line ('=' * 72)
Add-Line 'SUMMARY'
Add-Line ('=' * 72)
if ($warnings.Count -eq 0) {
    Add-Line 'RESULT: HEALTHY - no thresholds breached.'
}
else {
    Add-Line ("RESULT: {0} WARNING(S)" -f $warnings.Count)
    Add-Line ''
    $i = 1
    foreach ($w in $warnings) { Add-Line ("  {0}. {1}" -f $i, $w); $i++ }
}
Add-Line ''
Add-Line ("Check duration: {0:N1} seconds" -f ((Get-Date) - $startTime).TotalSeconds)
Add-Line ('=' * 72)

# ============================================================ WRITE REPORT
try {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $reportPath = Join-Path $OutputDirectory ("healthcheck_{0:yyyy-MM-dd_HHmmss}.txt" -f $startTime)
    $report -join [Environment]::NewLine | Set-Content -LiteralPath $reportPath -Encoding UTF8

    if (-not $Quiet) {
        Write-Host ''
        $report | ForEach-Object { Write-Host $_ }
        Write-Host ''
        Write-Host "Report saved to: $reportPath" -ForegroundColor Green
    }
}
catch {
    Write-Error "Could not write report to '$OutputDirectory': $($_.Exception.Message)"
    exit 2
}

exit ([int]($warnings.Count -gt 0))
