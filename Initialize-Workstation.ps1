<#
.SYNOPSIS
    Script A - Sierra Valley USD workstation onboarding.

.DESCRIPTION
    Prepares a new or re-imaged workstation for the SVUSD domain:

      1. Renames the computer to the district naming standard
      2. Sets static DNS servers on the active network adapter
      3. Enables Windows Firewall on all three profiles
      4. Disables three unnecessary services
      5. Writes a completion report and returns a meaningful exit code

    Naming standard: <SITE>-<ROLE>-<ASSET>   e.g. SVHS-STAFF-04127
      SITE  = SVHS (Campus A), SVMS (Campus B), SVES (Campus C), SVDO (District Office)
      ROLE  = STAFF, LAB, LIB, ADMIN, CART
      ASSET = the district asset tag, digits only

    NetBIOS caps computer names at 15 characters. The script validates this
    before attempting the rename, because Rename-Computer will accept a longer
    name and leave you with a machine that cannot authenticate properly.

    Services disabled and why:
      RemoteRegistry - remote registry editing. Lateral-movement path, unused
                       on staff endpoints. CIS Benchmark recommends disabled.
      Fax            - fax service. No fax hardware anywhere in the district.
      XblGameSave    - Xbox Live game save sync. Consumer service with no
                       educational function; disabled per the district image.

.PARAMETER Site
    Campus code: SVHS, SVMS, SVES, or SVDO.

.PARAMETER Role
    Device role: STAFF, LAB, LIB, ADMIN, or CART.

.PARAMETER AssetTag
    District asset tag, digits only.

.PARAMETER DnsServers
    DNS servers to set. Defaults to the district DC and the campus RODC.

.PARAMETER ReportPath
    Folder for the completion report. Default C:\SVUSD\Logs.

.PARAMETER NoRestart
    Skip the restart prompt even when a rename requires one.

.PARAMETER WhatIf
    Show what would change without changing anything. Supported on every
    state-changing call in this script.

.OUTPUTS
    Exit code 0 = all steps succeeded
               1 = completed with warnings (one or more steps skipped)
               2 = a required step failed, or the script was not run elevated

.EXAMPLE
    .\Initialize-Workstation.ps1 -Site SVHS -Role STAFF -AssetTag 04127

.EXAMPLE
    .\Initialize-Workstation.ps1 -Site SVES -Role LAB -AssetTag 00891 -WhatIf

.NOTES
    Author : Jon Petruescu
    Course : IT100, Summer 2027
    Run elevated. Rename-Computer, firewall configuration, and service changes
    all require administrator rights.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('SVHS', 'SVMS', 'SVES', 'SVDO')]
    [string]$Site,

    [Parameter(Mandatory = $true)]
    [ValidateSet('STAFF', 'LAB', 'LIB', 'ADMIN', 'CART')]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{1,6}$')]
    [string]$AssetTag,

    [string[]]$DnsServers = @('10.10.1.10', '10.10.2.10'),

    [string]$ReportPath = 'C:\SVUSD\Logs',

    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# ------------------------------------------------------------------ results
$Steps = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Step {
    param(
        [string]$Name,
        [ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail
    )
    $Steps.Add([pscustomobject]@{
        Step   = $Name
        Status = $Status
        Detail = $Detail
        Time   = Get-Date -Format 'HH:mm:ss'
    }) | Out-Null

    $colour = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'SKIP' { 'Cyan' }
    }
    Write-Host ("[{0,-4}] {1,-32} {2}" -f $Status, $Name, $Detail) -ForegroundColor $colour
}

Write-Host ''
Write-Host '========================================================================' -ForegroundColor White
Write-Host '  SVUSD WORKSTATION ONBOARDING' -ForegroundColor White
Write-Host '========================================================================' -ForegroundColor White
Write-Host ("  Current name : {0}" -f $env:COMPUTERNAME)
Write-Host ("  Started      : {0:yyyy-MM-dd HH:mm:ss}" -f $startTime)
Write-Host ''

# ------------------------------------------------------------------ elevation
$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isElevated) {
    Write-Error 'This script must be run from an elevated PowerShell session.'
    exit 2
}

$RestartNeeded = $false

# ============================================================ 1. RENAME
$newName = "$Site-$Role-$AssetTag"

# NetBIOS hard limit. Rename-Computer accepts longer names and then the
# machine fails to authenticate cleanly - fail loudly here instead.
if ($newName.Length -gt 15) {
    Add-Step 'Rename computer' 'FAIL' "'$newName' is $($newName.Length) chars; NetBIOS limit is 15"
}
elseif ($env:COMPUTERNAME -eq $newName) {
    Add-Step 'Rename computer' 'SKIP' "already named $newName"
}
else {
    try {
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Rename to $newName")) {
            Rename-Computer -NewName $newName -Force -ErrorAction Stop
            $RestartNeeded = $true
            Add-Step 'Rename computer' 'OK' "$env:COMPUTERNAME -> $newName (restart required)"
        }
        else {
            Add-Step 'Rename computer' 'SKIP' "WhatIf: would rename to $newName"
        }
    }
    catch {
        Add-Step 'Rename computer' 'FAIL' $_.Exception.Message
    }
}

# ============================================================ 2. DNS
try {
    # Only touch adapters that are actually up and carrying IPv4. Setting DNS
    # on every adapter also hits virtual and disconnected ones.
    $adapters = Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object { $_.Status -eq 'Up' }

    if (-not $adapters) {
        Add-Step 'Set DNS servers' 'FAIL' 'no physical adapter is up'
    }
    else {
        foreach ($a in $adapters) {
            $current = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses

            if (($current -join ',') -eq ($DnsServers -join ',')) {
                Add-Step 'Set DNS servers' 'SKIP' "$($a.Name) already set to $($DnsServers -join ', ')"
                continue
            }

            if ($PSCmdlet.ShouldProcess($a.Name, "Set DNS to $($DnsServers -join ', ')")) {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex `
                    -ServerAddresses $DnsServers -ErrorAction Stop
                Add-Step 'Set DNS servers' 'OK' "$($a.Name): $($DnsServers -join ', ')"
            }
            else {
                Add-Step 'Set DNS servers' 'SKIP' "WhatIf: would set $($a.Name)"
            }
        }
    }
}
catch {
    Add-Step 'Set DNS servers' 'FAIL' $_.Exception.Message
}

# ============================================================ 3. FIREWALL
try {
    $profiles = Get-NetFirewallProfile -ErrorAction Stop
    $off = $profiles | Where-Object { -not $_.Enabled }

    if (-not $off) {
        Add-Step 'Enable Windows Firewall' 'SKIP' 'all three profiles already enabled'
    }
    elseif ($PSCmdlet.ShouldProcess('Domain, Private, Public', 'Enable firewall')) {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -ErrorAction Stop

        # Default-deny inbound is the setting that actually matters. A firewall
        # that is "enabled" while defaulting to Allow protects nothing.
        Set-NetFirewallProfile -Profile Domain, Private, Public `
            -DefaultInboundAction Block -DefaultOutboundAction Allow -ErrorAction Stop

        Add-Step 'Enable Windows Firewall' 'OK' "enabled on $($off.Name -join ', '); inbound default = Block"
    }
    else {
        Add-Step 'Enable Windows Firewall' 'SKIP' "WhatIf: would enable $($off.Name -join ', ')"
    }
}
catch {
    Add-Step 'Enable Windows Firewall' 'FAIL' $_.Exception.Message
}

# ============================================================ 4. SERVICES
$ServicesToDisable = @(
    @{ Name = 'RemoteRegistry'; Reason = 'remote registry access - lateral movement path' }
    @{ Name = 'Fax';            Reason = 'no fax hardware in the district' }
    @{ Name = 'XblGameSave';    Reason = 'Xbox Live save sync - no educational function' }
)

foreach ($svc in $ServicesToDisable) {
    try {
        $s = Get-Service -Name $svc.Name -ErrorAction Stop

        if ($s.StartType -eq 'Disabled' -and $s.Status -eq 'Stopped') {
            Add-Step "Disable $($svc.Name)" 'SKIP' 'already stopped and disabled'
            continue
        }

        if ($PSCmdlet.ShouldProcess($svc.Name, 'Stop and disable')) {
            if ($s.Status -ne 'Stopped') {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            }
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
            Add-Step "Disable $($svc.Name)" 'OK' $svc.Reason
        }
        else {
            Add-Step "Disable $($svc.Name)" 'SKIP' "WhatIf: would disable ($($svc.Reason))"
        }
    }
    catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # Absent on some SKUs and builds - not an error worth failing the run.
        Add-Step "Disable $($svc.Name)" 'SKIP' 'service not present on this build'
    }
    catch {
        Add-Step "Disable $($svc.Name)" 'WARN' $_.Exception.Message
    }
}

# ============================================================ REPORT
$nOK   = @($Steps | Where-Object Status -eq 'OK').Count
$nWarn = @($Steps | Where-Object Status -eq 'WARN').Count
$nFail = @($Steps | Where-Object Status -eq 'FAIL').Count
$nSkip = @($Steps | Where-Object Status -eq 'SKIP').Count

if     ($nFail -gt 0) { $verdict = 'FAILED';               $code = 2 }
elseif ($nWarn -gt 0) { $verdict = 'COMPLETED WITH WARNINGS'; $code = 1 }
else                  { $verdict = 'SUCCESS';              $code = 0 }

$report = [System.Collections.Generic.List[string]]::new()
$report.Add('========================================================================')
$report.Add('  SVUSD WORKSTATION ONBOARDING REPORT')
$report.Add('========================================================================')
$report.Add("Original name : $env:COMPUTERNAME")
$report.Add("Assigned name : $newName")
$report.Add("Site / Role   : $Site / $Role     Asset tag: $AssetTag")
$report.Add("Technician    : $env:USERDOMAIN\$env:USERNAME")
$report.Add("Started       : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))")
$report.Add("Completed     : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
$report.Add("OS            : $((Get-CimInstance Win32_OperatingSystem).Caption)")
$report.Add("Serial        : $((Get-CimInstance Win32_BIOS).SerialNumber)")
$report.Add("Model         : $((Get-CimInstance Win32_ComputerSystem).Model)")
$report.Add('')
$report.Add('------------------------------------------------------------------------')
$report.Add('STEPS')
$report.Add('------------------------------------------------------------------------')
foreach ($s in $Steps) {
    $report.Add(('{0}  [{1,-4}]  {2,-32}  {3}' -f $s.Time, $s.Status, $s.Step, $s.Detail))
}
$report.Add('')
$report.Add('------------------------------------------------------------------------')
$report.Add("RESULT: $verdict   ($nOK ok, $nWarn warning, $nFail failed, $nSkip skipped)")
if ($RestartNeeded) {
    $report.Add('A restart is required to complete the rename before domain join.')
}
$report.Add('------------------------------------------------------------------------')

try {
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
    }
    $file = Join-Path $ReportPath ("onboard_{0}_{1:yyyy-MM-dd_HHmmss}.txt" -f $newName, $startTime)
    $report -join [Environment]::NewLine | Set-Content -LiteralPath $file -Encoding UTF8
    $saved = $file
}
catch {
    Write-Warning "Could not write the report to '$ReportPath': $($_.Exception.Message)"
    $saved = $null
}

Write-Host ''
Write-Host '========================================================================' -ForegroundColor White
$vc = switch ($code) { 0 { 'Green' } 1 { 'Yellow' } 2 { 'Red' } }
Write-Host ("  RESULT: {0}" -f $verdict) -ForegroundColor $vc
Write-Host ("  {0} ok, {1} warning, {2} failed, {3} skipped" -f $nOK, $nWarn, $nFail, $nSkip)
Write-Host '========================================================================' -ForegroundColor White
if ($saved) { Write-Host "  Report: $saved" -ForegroundColor Green }

# ------------------------------------------------------------------ restart
if ($RestartNeeded -and -not $NoRestart -and $code -ne 2) {
    Write-Host ''
    Write-Host '  The rename needs a restart before this machine joins the domain.' -ForegroundColor Yellow
    $answer = Read-Host '  Restart now? (y/N)'
    if ($answer -match '^[Yy]') {
        Restart-Computer -Force
    }
    else {
        Write-Host '  Restart skipped. Remember to reboot before domain join.' -ForegroundColor Yellow
    }
}

exit $code
