<#
.SYNOPSIS
    Script 3 - Event Log Parser.

.DESCRIPTION
    Queries two sources over a rolling window (24 hours by default) and writes
    both into a single timestamped text report:

      Section 1 - System log, Level 2 (Error) events
      Section 2 - Security log, Event ID 4625 (failed logon)

    Each section lists individual events with timestamps and is preceded by
    aggregate views: System errors grouped by source and event ID, failed
    logons grouped by account, source IP, and logon type. The grouping is what
    turns a wall of events into something you can act on.

    Requirements:
      - The Security log requires an elevated session. Without elevation the
        script reports the System section normally and flags Section 2 as
        inaccessible rather than failing outright.
      - Failed logon auditing must be enabled for 4625 events to exist at all.
        Verify with: auditpol /get /subcategory:"Logon"

.PARAMETER Hours
    Size of the lookback window in hours. Default 24.

.PARAMETER OutputDirectory
    Folder for the report. Created if missing. Default C:\Temp.

.PARAMETER MaxEventsPerSection
    Cap on individual events listed per section. Aggregates always cover the
    full result set. Default 200.

.PARAMETER Quiet
    Suppress console output; still writes the report and sets the exit code.

.OUTPUTS
    Exit code 0 = nothing found, 1 = events found, 2 = report write failed.

.EXAMPLE
    .\Get-EventLogReport.ps1

.EXAMPLE
    .\Get-EventLogReport.ps1 -Hours 72 -MaxEventsPerSection 500 -Quiet
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 8760)][int]$Hours = 24,
    [string]$OutputDirectory = 'C:\Temp',
    [ValidateRange(1, 10000)][int]$MaxEventsPerSection = 200,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$startTime  = Get-Date
$windowFrom = $startTime.AddHours(-$Hours)

$report = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$Text = '') $report.Add($Text) | Out-Null }
function Add-Table {
    param($InputObject)
    if (-not $InputObject) { return }
    ($InputObject | Format-Table -AutoSize | Out-String).Trim() -split "`r?`n" |
        ForEach-Object { Add-Line $_.TrimEnd() }
}
function Add-Section {
    param([string]$Title)
    Add-Line ''
    Add-Line ('=' * 78)
    Add-Line $Title
    Add-Line ('=' * 78)
}

# Get-WinEvent throws a terminating "No events were found" error on an empty
# result set, which is not an error condition here. Normalise to an empty array.
function Get-EventsSafely {
    param([hashtable]$FilterHashtable, [ref]$ErrorMessage)
    try {
        return @(Get-WinEvent -FilterHashtable $FilterHashtable -ErrorAction Stop)
    }
    catch [System.Exception] {
        if ($_.Exception.Message -match 'No events were found') { return @() }
        $ErrorMessage.Value = $_.Exception.Message
        return $null
    }
}

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================ HEADER
Add-Line ('=' * 78)
Add-Line '                        EVENT LOG REPORT'
Add-Line ('=' * 78)
Add-Line ("Computer     : {0}" -f $env:COMPUTERNAME)
Add-Line ("Generated    : {0:yyyy-MM-dd HH:mm:ss} ({1})" -f $startTime, [System.TimeZoneInfo]::Local.StandardName)
Add-Line ("Window       : {0:yyyy-MM-dd HH:mm:ss}  ->  {1:yyyy-MM-dd HH:mm:ss}  ({2} hours)" -f `
    $windowFrom, $startTime, $Hours)
Add-Line ("Elevated     : {0}" -f $(if ($isElevated) { 'Yes' } else { 'No - Security log may be unreadable' }))
Add-Line ("Run by       : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)

# ============================================================ 1. SYSTEM ERRORS
Add-Section '1. SYSTEM LOG - ERROR EVENTS'

$sysError = $null
$sysEvents = Get-EventsSafely -FilterHashtable @{
    LogName   = 'System'
    Level     = 2               # 1=Critical 2=Error 3=Warning 4=Information
    StartTime = $windowFrom
} -ErrorMessage ([ref]$sysError)

if ($null -eq $sysEvents) {
    Add-Line "ERROR: could not read the System log - $sysError"
    $sysEvents = @()
}
elseif ($sysEvents.Count -eq 0) {
    Add-Line "No Error-level events in the System log during the window."
}
else {
    Add-Line ("Total Error events: {0}" -f $sysEvents.Count)
    Add-Line ''
    Add-Line '--- Grouped by source and event ID ---'
    Add-Line ''

    $grouped = $sysEvents |
        Group-Object ProviderName, Id |
        Sort-Object Count -Descending |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                Count    = $_.Count
                Source   = $first.ProviderName
                'ID'     = $first.Id
                'Most recent' = '{0:yyyy-MM-dd HH:mm:ss}' -f ($_.Group |
                    Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                Message  = ($first.Message -split "`r?`n")[0] -replace '\s+', ' ' |
                    ForEach-Object { if ($_.Length -gt 70) { $_.Substring(0, 67) + '...' } else { $_ } }
            }
        }
    Add-Table $grouped

    Add-Line ''
    Add-Line '--- Individual events (most recent first) ---'
    Add-Line ''

    $shown = $sysEvents | Sort-Object TimeCreated -Descending | Select-Object -First $MaxEventsPerSection
    foreach ($e in $shown) {
        Add-Line ("[{0:yyyy-MM-dd HH:mm:ss}]  ID {1,-6} {2}" -f $e.TimeCreated, $e.Id, $e.ProviderName)
        $msg = ($e.Message -replace "`r", '') -split "`n" | Where-Object { $_.Trim() }
        foreach ($line in ($msg | Select-Object -First 4)) {
            Add-Line ("    {0}" -f $line.Trim())
        }
        if ($msg.Count -gt 4) { Add-Line '    ...' }
        Add-Line ''
    }
    if ($sysEvents.Count -gt $MaxEventsPerSection) {
        Add-Line ("... {0} further event(s) not listed (raise -MaxEventsPerSection to include them)." -f `
            ($sysEvents.Count - $MaxEventsPerSection))
    }
}

# ============================================================ 2. FAILED LOGONS
Add-Section '2. SECURITY LOG - FAILED LOGONS (EVENT ID 4625)'

$secError = $null
$secEvents = Get-EventsSafely -FilterHashtable @{
    LogName   = 'Security'
    Id        = 4625
    StartTime = $windowFrom
} -ErrorMessage ([ref]$secError)

# Human-readable logon type and failure status decoding.
$logonTypes = @{
    2  = 'Interactive (console)'
    3  = 'Network (share/SMB)'
    4  = 'Batch (scheduled task)'
    5  = 'Service'
    7  = 'Unlock'
    8  = 'NetworkCleartext'
    9  = 'NewCredentials (runas)'
    10 = 'RemoteInteractive (RDP)'
    11 = 'CachedInteractive'
}
$statusCodes = @{
    '0xc000005e' = 'No logon servers available'
    '0xc0000064' = 'Account does not exist'
    '0xc000006a' = 'Wrong password'
    '0xc000006d' = 'Bad username or password'
    '0xc000006e' = 'Account restriction'
    '0xc000006f' = 'Logon outside permitted hours'
    '0xc0000070' = 'Logon from unauthorised workstation'
    '0xc0000071' = 'Password expired'
    '0xc0000072' = 'Account disabled'
    '0xc0000133' = 'Clock skew between machines'
    '0xc0000193' = 'Account expired'
    '0xc0000224' = 'Password change required'
    '0xc0000234' = 'Account locked out'
}

if ($null -eq $secEvents) {
    Add-Line "ERROR: could not read the Security log - $secError"
    if (-not $isElevated) {
        Add-Line ''
        Add-Line 'The Security log requires an elevated session. Re-run this script as Administrator.'
    }
    $secEvents = @()
}
elseif ($secEvents.Count -eq 0) {
    Add-Line 'No failed logon events (4625) during the window.'
    Add-Line ''
    Add-Line 'If this is unexpected, confirm that logon failure auditing is enabled:'
    Add-Line '    auditpol /get /subcategory:"Logon"'
}
else {
    # Parse EventData by field name rather than positional index - the
    # positions shift between Windows versions.
    $parsed = foreach ($e in $secEvents) {
        $data = @{}
        foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }

        $lt     = $data['LogonType']
        $status = $data['Status']
        $sub    = $data['SubStatus']
        # SubStatus carries the specific reason when Status is the generic 0xc000006d.
        $reason = if ($sub -and $statusCodes.ContainsKey($sub.ToLower())) { $statusCodes[$sub.ToLower()] }
                  elseif ($status -and $statusCodes.ContainsKey($status.ToLower())) { $statusCodes[$status.ToLower()] }
                  else { "Unknown ($status/$sub)" }

        [pscustomobject]@{
            Time        = $e.TimeCreated
            Account     = if ($data['TargetDomainName']) { "$($data['TargetDomainName'])\$($data['TargetUserName'])" }
                          else { $data['TargetUserName'] }
            LogonType   = if ($lt -and $logonTypes.ContainsKey([int]$lt)) { "$lt - $($logonTypes[[int]$lt])" } else { $lt }
            LogonTypeId = $lt
            Workstation = if ($data['WorkstationName']) { $data['WorkstationName'] } else { '-' }
            SourceIP    = if ($data['IpAddress'] -and $data['IpAddress'] -ne '-') { $data['IpAddress'] } else { '-' }
            Reason      = $reason
            Process     = $data['ProcessName']
        }
    }

    Add-Line ("Total failed logons: {0}" -f $parsed.Count)
    Add-Line ("Distinct accounts  : {0}" -f (@($parsed | Group-Object Account).Count))
    Add-Line ("Distinct source IPs: {0}" -f (@($parsed | Where-Object { $_.SourceIP -ne '-' } |
                                                Group-Object SourceIP).Count))
    Add-Line ''
    Add-Line '--- By target account ---'
    Add-Line ''
    Add-Table ($parsed | Group-Object Account | Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Attempts  = $_.Count
                Account   = $_.Name
                'Reasons' = (($_.Group.Reason | Select-Object -Unique) -join ', ')
                'Last seen' = '{0:yyyy-MM-dd HH:mm:ss}' -f ($_.Group.Time | Sort-Object -Descending)[0]
            }
        })

    $byIp = $parsed | Where-Object { $_.SourceIP -ne '-' } | Group-Object SourceIP |
        Sort-Object Count -Descending
    if ($byIp) {
        Add-Line ''
        Add-Line '--- By source IP ---'
        Add-Line ''
        Add-Table ($byIp | ForEach-Object {
            [pscustomobject]@{
                Attempts   = $_.Count
                'Source IP' = $_.Name
                Accounts   = (($_.Group.Account | Select-Object -Unique) -join ', ')
                'Last seen' = '{0:yyyy-MM-dd HH:mm:ss}' -f ($_.Group.Time | Sort-Object -Descending)[0]
            }
        })
    }

    Add-Line ''
    Add-Line '--- By logon type ---'
    Add-Line ''
    Add-Table ($parsed | Group-Object LogonType | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Attempts = $_.Count; 'Logon type' = $_.Name } })

    # Cheap brute-force heuristic: many attempts from one IP, or one IP
    # spraying several accounts.
    $suspects = $byIp | Where-Object {
        $_.Count -ge 10 -or (@($_.Group.Account | Select-Object -Unique).Count -ge 3)
    }
    if ($suspects) {
        Add-Line ''
        Add-Line '--- POSSIBLE BRUTE FORCE / PASSWORD SPRAY ---'
        Add-Line ''
        foreach ($s in $suspects) {
            $accts = @($s.Group.Account | Select-Object -Unique)
            Add-Line ("  {0}: {1} attempts against {2} account(s) - {3}" -f `
                $s.Name, $s.Count, $accts.Count, ($accts -join ', '))
        }
    }

    Add-Line ''
    Add-Line '--- Individual events (most recent first) ---'
    Add-Line ''
    foreach ($p in ($parsed | Sort-Object Time -Descending | Select-Object -First $MaxEventsPerSection)) {
        Add-Line ("[{0:yyyy-MM-dd HH:mm:ss}]  {1}" -f $p.Time, $p.Account)
        Add-Line ("    Reason      : {0}" -f $p.Reason)
        Add-Line ("    Logon type  : {0}" -f $p.LogonType)
        Add-Line ("    Source      : {0}  (workstation: {1})" -f $p.SourceIP, $p.Workstation)
        Add-Line ''
    }
    if ($parsed.Count -gt $MaxEventsPerSection) {
        Add-Line ("... {0} further event(s) not listed." -f ($parsed.Count - $MaxEventsPerSection))
    }
}

# ============================================================ SUMMARY
Add-Section 'SUMMARY'
Add-Line ("System log errors      : {0}" -f $sysEvents.Count)
Add-Line ("Failed logons (4625)   : {0}" -f $secEvents.Count)
Add-Line ("Window                 : {0} hours ending {1:yyyy-MM-dd HH:mm:ss}" -f $Hours, $startTime)
Add-Line ("Query duration         : {0:N1} seconds" -f ((Get-Date) - $startTime).TotalSeconds)
Add-Line ('=' * 78)

# ============================================================ WRITE
try {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $reportPath = Join-Path $OutputDirectory `
        ("eventlog_{0}_{1:yyyy-MM-dd_HHmmss}.txt" -f $env:COMPUTERNAME, $startTime)

    $report -join [Environment]::NewLine | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
catch {
    Write-Error "Could not write report to '$OutputDirectory': $($_.Exception.Message)"
    exit 2
}

if (-not $Quiet) {
    Write-Host ''
    $report | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "Report saved to: $reportPath" -ForegroundColor Green
}

exit ([int](($sysEvents.Count + $secEvents.Count) -gt 0))
