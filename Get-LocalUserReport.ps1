<#
.SYNOPSIS
    Script 2 - Local User Account Report.

.DESCRIPTION
    Enumerates every local user account and reports name, enabled status, last
    logon, and whether the account is a member of the local Administrators
    group. Enabled accounts that have never logged on are flagged as a risk.

    Results are written to a CSV file and, unless -Quiet is used, summarised
    on the console.

    Notes on accuracy:
      - Administrators membership is resolved via the well-known SID
        S-1-5-32-544 rather than the literal name "Administrators", so the
        script works on non-English Windows.
      - Get-LocalGroupMember throws on orphaned or Azure AD member SIDs on
        some builds; the script falls back to the ADSI WinNT provider.
      - LastLogon reflects logons recorded by the local SAM. It is not
        replicated and will be blank for accounts that have only ever
        authenticated elsewhere.

.PARAMETER OutputDirectory
    Folder for the CSV. Created if missing. Default C:\Temp.

.PARAMETER OutputPath
    Full path to the CSV, overriding OutputDirectory and the generated name.

.PARAMETER IncludeDisabled
    Included by default. Use -IncludeDisabled:$false to report enabled accounts only.

.PARAMETER Quiet
    Suppress console output; still writes the CSV and sets the exit code.

.OUTPUTS
    Exit code 0 = no flagged accounts, 1 = one or more flagged, 2 = CSV write failed.

.EXAMPLE
    .\Get-LocalUserReport.ps1

.EXAMPLE
    .\Get-LocalUserReport.ps1 -OutputPath C:\Audit\users.csv -Quiet
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\Temp',
    [string]$OutputPath,
    [switch]$IncludeDisabled = $true,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# ---------------------------------------------------------------- helpers
function Write-Info {
    param([string]$Text, [string]$Colour = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Colour }
}

# Resolve local Administrators membership to a lookup of lowercase names.
function Get-AdministratorsMemberSet {
    $set = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # Preferred path: SID-based group lookup, locale independent.
    try {
        $adminGroup = Get-LocalGroup -ErrorAction Stop |
            Where-Object { $_.SID.Value -eq 'S-1-5-32-544' }

        if ($adminGroup) {
            # -ErrorAction SilentlyContinue: unresolvable member SIDs raise
            # non-terminating errors but the resolvable members still return.
            $members = Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue
            if ($members) {
                foreach ($m in $members) {
                    # Name arrives as DOMAIN\user or MACHINE\user.
                    $set.Add(($m.Name -split '\\')[-1]) | Out-Null
                }
                return $set
            }
        }
    }
    catch { }

    # Fallback: ADSI WinNT provider. Works where the cmdlets choke.
    try {
        $groupName = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
            ).Translate([System.Security.Principal.NTAccount]).Value -replace '^.*\\'

        $group = [ADSI]"WinNT://./$groupName,group"
        foreach ($member in @($group.Invoke('Members'))) {
            $set.Add(([ADSI]$member).InvokeGet('Name')) | Out-Null
        }
    }
    catch {
        Write-Warning "Could not enumerate the Administrators group: $($_.Exception.Message)"
    }

    return $set
}

# ---------------------------------------------------------------- gather
Write-Info 'Enumerating local accounts...' 'Cyan'

$admins = Get-AdministratorsMemberSet

$users = $null
$source = 'Get-LocalUser'
try {
    $users = Get-LocalUser -ErrorAction Stop
}
catch {
    # LocalAccounts module missing (older builds, Server Core minimal, some PS7 setups).
    Write-Warning "Get-LocalUser unavailable, falling back to CIM: $($_.Exception.Message)"
    $source = 'Win32_UserAccount'
    $users = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" |
        ForEach-Object {
            [pscustomobject]@{
                Name                 = $_.Name
                FullName             = $_.FullName
                Description          = $_.Description
                Enabled              = -not $_.Disabled
                SID                  = $_.SID
                LastLogon            = $null      # not exposed by this class
                PasswordLastSet      = $null
                PasswordExpires      = $null
                PasswordRequired     = $_.PasswordRequired
                UserMayChangePassword = $_.PasswordChangeable
            }
        }
}

if (-not $users) {
    Write-Error 'No local user accounts could be enumerated.'
    exit 2
}

# ---------------------------------------------------------------- build rows
$rows = foreach ($u in $users) {
    if (-not $IncludeDisabled -and -not $u.Enabled) { continue }

    $isAdmin      = $admins.Contains($u.Name)
    $neverLoggedOn = ($null -eq $u.LastLogon)
    $flagged      = ($neverLoggedOn -and $u.Enabled)

    $daysSince = if ($neverLoggedOn) { $null }
                 else { [math]::Round(((Get-Date) - $u.LastLogon).TotalDays, 0) }

    $riskNotes = [System.Collections.Generic.List[string]]::new()
    if ($flagged)               { $riskNotes.Add('Enabled but never logged on') | Out-Null }
    if ($flagged -and $isAdmin) { $riskNotes.Add('Unused administrator account') | Out-Null }
    if ($u.Enabled -and $null -ne $daysSince -and $daysSince -gt 90) {
        $riskNotes.Add("Dormant - $daysSince days since last logon") | Out-Null
    }

    # SID is a SecurityIdentifier from Get-LocalUser, a plain string from CIM.
    $sidText = if ($u.SID -is [string]) { $u.SID } else { $u.SID.ToString() }

    [pscustomobject]@{
        ComputerName    = $env:COMPUTERNAME
        Name            = $u.Name
        FullName        = $u.FullName
        Enabled         = [bool]$u.Enabled
        LastLogon       = if ($neverLoggedOn) { '' } else { '{0:yyyy-MM-dd HH:mm:ss}' -f $u.LastLogon }
        DaysSinceLogon  = $daysSince
        NeverLoggedOn   = $neverLoggedOn
        IsAdministrator = $isAdmin
        Flagged         = $flagged
        RiskNotes       = $riskNotes -join '; '
        PasswordLastSet = if ($u.PasswordLastSet) { '{0:yyyy-MM-dd}' -f $u.PasswordLastSet } else { '' }
        PasswordExpires = if ($u.PasswordExpires) { '{0:yyyy-MM-dd}' -f $u.PasswordExpires } else { 'Never' }
        SID             = $sidText
        Description     = $u.Description
        ReportedUtc     = '{0:yyyy-MM-dd HH:mm:ss}' -f $startTime.ToUniversalTime()
    }
}

$rows = @($rows | Sort-Object @{E='Flagged';Descending=$true},
                              @{E='IsAdministrator';Descending=$true},
                              Name)

$flaggedRows = @($rows | Where-Object Flagged)

# ---------------------------------------------------------------- write CSV
if (-not $OutputPath) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        try { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
        catch { Write-Error "Cannot create '$OutputDirectory': $($_.Exception.Message)"; exit 2 }
    }
    $OutputPath = Join-Path $OutputDirectory `
        ("useraudit_{0}_{1:yyyy-MM-dd_HHmmss}.csv" -f $env:COMPUTERNAME, $startTime)
}

try {
    $parent = Split-Path -Path $OutputPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
}
catch {
    Write-Error "Could not write CSV to '$OutputPath': $($_.Exception.Message)"
    exit 2
}

# ---------------------------------------------------------------- console summary
if (-not $Quiet) {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host "  LOCAL USER ACCOUNT REPORT - $env:COMPUTERNAME"
    Write-Host ('=' * 78)
    Write-Host ("  Generated : {0:yyyy-MM-dd HH:mm:ss}" -f $startTime)
    Write-Host ("  Source    : {0}" -f $source)
    Write-Host ''

    $rows | Format-Table -AutoSize `
        Name, Enabled, LastLogon, IsAdministrator, Flagged | Out-Host

    Write-Host ("  Accounts total    : {0}" -f $rows.Count)
    Write-Host ("  Enabled           : {0}" -f @($rows | Where-Object Enabled).Count)
    Write-Host ("  Administrators    : {0}" -f @($rows | Where-Object IsAdministrator).Count)

    if ($flaggedRows.Count -gt 0) {
        Write-Host ''
        Write-Host ("  *** {0} ENABLED ACCOUNT(S) HAVE NEVER LOGGED ON ***" -f $flaggedRows.Count) `
            -ForegroundColor Yellow
        foreach ($f in $flaggedRows) {
            $tag = if ($f.IsAdministrator) { ' [ADMINISTRATOR]' } else { '' }
            Write-Host ("    - {0}{1}" -f $f.Name, $tag) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ''
        Write-Host '  No enabled accounts without a logon history.' -ForegroundColor Green
    }

    if ($source -eq 'Win32_UserAccount') {
        Write-Host ''
        Write-Warning 'CIM fallback in use - LastLogon is unavailable, so the never-logged-on flag is unreliable on this host.'
    }

    Write-Host ''
    Write-Host "  CSV saved to: $OutputPath" -ForegroundColor Green
    Write-Host ('=' * 78)
}

exit ([int]($flaggedRows.Count -gt 0))
