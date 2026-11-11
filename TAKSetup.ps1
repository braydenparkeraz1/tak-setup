<#
.SYNOPSIS
    TAK Remote Access Setup: connects this PC to The Alt Key PLLC's office network for remote work.

.DESCRIPTION
    Run by IT with the employee during onboarding. What it does, in order (everything is printed and logged to
    C:\ProgramData\TAKRemoteAccess\setup-script.log):

      1. Checks BitLocker (read-only): the Windows drive must be protected, or encrypting with a TPM protector.
         It never turns BitLocker on and never reads recovery keys.
      2. Asks for the employee's name and turns it into a device name (jane-smith-7f3a; the code is unique to this PC).
      3. Downloads the official Tailscale, RustDesk and OpenSSH installers from their vendors and refuses any whose
         SHA-256 doesn't match the value pinned below or whose Authenticode signature isn't valid and from that vendor.
      4. Installs Tailscale and joins the company tailnet as tag:client with a one-time code from IT (nothing secret is
         stored in this file), then waits for IT to approve the device. The IT dashboard adds Remote Desktop
         (tag:rdp-client) once it has seen BitLocker on.
      5. Installs RustDesk: direct connections from Tailscale addresses only, the employee clicks Accept for every
         session, never RustDesk's public servers.
      6. Installs OpenSSH Server for IT: key logins only (IT's public keys below), only from Tailscale addresses, only as
         the local administrator "tak-it", whose random password nobody knows and which can't sign in at the keyboard
         or over Remote Desktop.
      7. Tells the IT dashboard to check this PC now, and puts "TAK Remote Desktop" and "Get IT Help" on the desktop.

.NOTES
    HOW TO RUN (IT, on a call with the employee):
      1. Create a one-time code: Tailscale admin console > Settings > Keys > Generate auth key: Reusable OFF,
         Ephemeral OFF, Pre-approved OFF, Tags tag:client, expires in 1 day. Send it to the employee.
      2. The employee opens PowerShell as administrator (Start > type PowerShell > right-click Windows PowerShell >
         Run as administrator) and pastes:
             irm https://raw.githubusercontent.com/braydenparkeraz1/tak-setup/main/TAKSetup.ps1 | iex
      3. They paste the one-time code when asked, and you approve the device in the admin console.
    Windows PowerShell 5.1 (built into Windows 10/11). No secrets in this file: it is public on purpose.
#>
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # PowerShell 5.1's progress bar slows downloads down a lot

# -- settings (filled in by build-script.ps1) ---------------------------------------------------------
$ScriptVersion    = '0.2'
$SshAdminKeys     = @('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAFTFY/WOtlFnxMuD4Htrke0n+zFf6lCru13ip1E2sxC tak-it@brayden-desktop', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICMlH+y4irncqn6Vmjgwmm+VlDOcgBawoRVoIqQ7rQ// it-dashboard')
$Installers       = @{
    'tailscale' = @{ Name = 'Tailscale'; Version = '1.104.2'; File = 'tailscale-setup-amd64.msi'; Url = 'https://pkgs.tailscale.com/stable/tailscale-setup-1.104.2-amd64.msi'; Sha256 = '7EFF4ABDCBCF592AC9BCE28F2B9F0FD51F8FC09194C955FBE8253B67B531E7F5'; Signer = 'Tailscale Inc.' }
    'rustdesk' = @{ Name = 'RustDesk'; Version = '1.5.0'; File = 'rustdesk-x86_64.msi'; Url = 'https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-x86_64.msi'; Sha256 = '624FE792AB1D76B35134DAB84BFF97A6BCD14043FFD090A2C6A2800F77580495'; Signer = 'PURSLANE' }
    'openssh' = @{ Name = 'Win32-OpenSSH'; Version = '10.4.0.0'; File = 'openssh-win64.msi'; Url = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-Win64-v10.4.0.0.msi'; Sha256 = '788D8643464A01EB63640A2FD746F9ED23D106B5A901A35F88DC8CD40E446AC9'; Signer = 'Microsoft Corporation' }
}
$ClientTag        = 'tag:client'
$TailnetSuffix    = 'tail871d96.ts.net'
$RdpServerHost    = 'rdp-server'
$DashboardHost    = 'it-dashboard'
$IntakePort       = 8080
$SupportContact   = 'the IT team'
$ShortcutName     = 'TAK Remote Desktop'
$SshAccount       = 'tak-it'
$TailnetRanges    = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
$DataDir          = Join-Path $env:ProgramData 'TAKRemoteAccess'

# Any error nothing else caught: show it and wait, instead of the window closing before anyone can read it.
trap {
    $msg = "Setup stopped unexpectedly: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    try { Add-Content -LiteralPath (Join-Path $env:ProgramData 'TAKRemoteAccess\setup-script.log') -Value "$(Get-Date -Format s) ERROR $msg" -Encoding UTF8 } catch { }
    Write-Host ''
    Write-Host $msg -ForegroundColor Red
    Write-Host 'Please send a photo of this window to the IT team.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close' | Out-Null
    [Environment]::Exit(1)
}

# -- elevation ----------------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host 'TAK Remote Access Setup needs PowerShell to be opened as administrator.' -ForegroundColor Yellow
    Write-Host 'Close this window. Then: Start > type PowerShell > right-click "Windows PowerShell" > Run as administrator,'
    Write-Host 'and paste the command again.'
    Write-Host ''
    return
}

# -- output and log -----------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
# Admins own the data folder; everyone else may only read it (a standard user could otherwise pre-create it).
& icacls.exe $DataDir /setowner '*S-1-5-32-544' | Out-Null
& icacls.exe $DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
$LogFile = Join-Path $DataDir 'setup-script.log'

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1,-5} {2}' -f (Get-Date), $Level, (Hide-Secrets $Message)
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}
function Hide-Secrets([string]$Text) { $Text -replace 'tskey-[A-Za-z0-9]+-[A-Za-z0-9]+', 'tskey-****' }
# On screen: short, plain English for employees. Technical detail goes to the log only (Note).
function Say([string]$Message) { Write-Host "   $Message"; Write-Log $Message }
function Note([string]$Message) { Write-Log $Message }
$script:StepNo = 0
function Step([string]$Message) {
    $script:StepNo++
    Write-Host ''
    Write-Host "Step $($script:StepNo) of 4: $Message" -ForegroundColor Cyan
    Write-Log "== $Message"
}
function Fail([string]$Message, [string]$Detail = '') {
    Write-Log "$Message $Detail" 'ERROR'
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    Write-Host "Please contact $SupportContact. (Details for IT: $LogFile)" -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Press Enter to close' | Out-Null
    [Environment]::Exit(1)
}

# Runs an exe directly (no shell) and returns its exit code and output.
function Invoke-Exe([string]$Path, [string[]]$Arguments, [int]$TimeoutSeconds = 300) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { $p.Kill(); throw "$Path timed out after $TimeoutSeconds s" }
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

Write-Log "Script setup $ScriptVersion starting as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."
Write-Host ''
Write-Host 'TAK Remote Access Setup' -ForegroundColor Cyan
Write-Host "This connects your computer to The Alt Key's office so you can work on the office server from here."
Write-Host 'It also lets IT help you remotely: they can see your screen only after you click Accept,'
Write-Host 'and can install updates and fix problems in the background. It takes about five minutes.'

if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    Fail "This setup only supports standard (Intel/AMD) Windows computers. Please contact $SupportContact."
}

# -- 1. BitLocker (read-only) -------------------------------------------------------------------------
Step 'Checking this computer'
$drive = $env:SystemDrive
$bitLockerState = 'unavailable'
try {
    $vol = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
        -Filter "DriveLetter='$drive'" -ErrorAction Stop
} catch { $vol = $null }
if ($vol) {
    $protection = [int]$vol.ProtectionStatus
    $conversion = [int](Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus).ConversionStatus
    $tpm = @((Invoke-CimMethod -InputObject $vol -MethodName GetKeyProtectors -Arguments @{ KeyProtectorType = [uint32]1 }).VolumeKeyProtectorID).Count -gt 0
    Write-Log "BitLocker on ${drive}: protection=$protection conversion=$conversion tpmProtector=$tpm"
    if ($protection -eq 1) { $bitLockerState = 'protected' }
    elseif ($conversion -eq 2 -and $tpm) { $bitLockerState = 'encrypting' }
    elseif ($conversion -eq 4) { $bitLockerState = 'paused' }
    else { $bitLockerState = 'off' }
}
switch ($bitLockerState) {
    'protected'  { Say 'Drive protection (BitLocker) is on.' }
    'encrypting' { Say 'Drive protection (BitLocker) is on.' }
    'paused'     { Fail 'BitLocker encryption on this computer is paused. Open "Manage BitLocker" and resume it (or restart the computer), then run this setup again.' }
    default {
        Write-Host ''
        Write-Host "   This computer's drive needs BitLocker turned on first (it protects your work if the computer is lost)." -ForegroundColor Yellow
        Write-Host "   You can turn it on yourself, or contact $SupportContact for help. Then run this setup again."
        $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
        if ($edition -like 'Core*') {
            Write-Host '   How: Start > Settings > Privacy & security > Device encryption > turn it On.'
        } else {
            Write-Host '   How: Start > type "Manage BitLocker" > open it > "Turn on BitLocker" next to the C: drive.'
            Write-Host '        Save the recovery key when it asks (to your Microsoft account, a file or a printout), then follow the steps.'
        }
        Fail "Setup can't continue until BitLocker is on." "state=$bitLockerState"
    }
}

# -- 2. Device name -----------------------------------------------------------------------------------
$guid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
if (-not $guid) { $guid = $env:COMPUTERNAME }
$sha = [Security.Cryptography.SHA256]::Create()
$hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($guid.Trim().ToLowerInvariant()))
$deviceCode = ('{0:x2}{1:x2}' -f $hashBytes[0], $hashBytes[1])

function ConvertTo-DeviceName([string]$Name) {
    if (-not $Name -or -not $Name.Trim()) { return '' }
    $sb = New-Object Text.StringBuilder
    $lastDash = $true
    foreach ($c in $Name.Trim().Normalize([Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -eq [Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        if ($c -eq [char]0x27 -or $c -eq [char]0x2019) { continue }   # O'Neil -> oneil
        $l = [char]::ToLowerInvariant($c)
        if (($l -ge [char]'a' -and $l -le [char]'z') -or ($l -ge [char]'0' -and $l -le [char]'9')) {
            [void]$sb.Append($l); $lastDash = $false
        } elseif (-not $lastDash) {
            [void]$sb.Append('-'); $lastDash = $true
        }
    }
    $core = $sb.ToString().Trim('-')
    if (-not $core) { return '' }
    $suffix = "-$deviceCode"
    if ($core.Length -gt 63 - $suffix.Length) { $core = $core.Substring(0, 63 - $suffix.Length).TrimEnd('-') }
    return $core + $suffix
}

$hostname = ''
while (-not $hostname) {
    Write-Host ''
    $name = Read-Host '   Your full name'
    $hostname = ConvertTo-DeviceName $name
    if (-not $hostname) { Write-Host '   Please use letters or numbers (for example: Jane Smith).' -ForegroundColor Yellow }
}
Say "IT will see this computer as: $hostname"

# -- installer download + checks ----------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# A fresh folder only SYSTEM and Administrators can touch, so nobody can swap the file between the check and msiexec.
function New-AdminOnlyFolder([string]$Prefix) {
    $dir = Join-Path $DataDir ("$Prefix-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $dir
}

function Install-VendorMsi([string]$Id, [string[]]$Properties) {
    $i = $Installers[$Id]
    $dir = New-AdminOnlyFolder 'installer'
    $msi = Join-Path $dir $i.File
    try {
        Note "Downloading $($i.Name) $($i.Version) from $($i.Url)"
        Invoke-WebRequest -Uri $i.Url -OutFile $msi -UseBasicParsing
        $hold = [IO.File]::Open($msi, 'Open', 'Read', 'Read')   # keep it unchanged until msiexec is done
        try {
            $actual = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
            if ($actual -ne $i.Sha256) { Fail 'A download was damaged or changed, so setup stopped.' "$($i.Name): SHA-256 $actual, expected $($i.Sha256)" }
            $sig = Get-AuthenticodeSignature -LiteralPath $msi
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike "*$($i.Signer)*") {
                Fail 'A download was damaged or changed, so setup stopped.' "$($i.Name): signature $($sig.Status), signer $($sig.SignerCertificate.Subject)"
            }
            Write-Log "$($i.Name): SHA-256 $actual, signed by $($sig.SignerCertificate.Subject)"
            $log = Join-Path $DataDir ("{0}-{1:yyyyMMdd-HHmmss}.log" -f [IO.Path]::GetFileNameWithoutExtension($i.File), (Get-Date))
            Note "Installing $($i.Name)"
            $r = Invoke-Exe "$env:SystemRoot\System32\msiexec.exe" (@('/i', $msi, '/quiet', '/norestart') + $Properties + @('/l*v', $log)) 900
        } finally { $hold.Dispose() }
        switch ($r.ExitCode) {
            0 { Note "$($i.Name) installed." }
            3010 { Note "$($i.Name) installed (restart recommended; not restarting)." }
            1618 { Fail 'Windows is busy installing something else (often Windows Update). Wait a few minutes, then run this setup again.' 'msiexec 1618' }
            default { Fail "Part of the setup couldn't be installed." "$($i.Name): msiexec exit $($r.ExitCode); log $log" }
        }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -- 3. Tailscale: install and join -------------------------------------------------------------------
Step 'Connecting to the company network'
$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path $tailscale)) {
    # TS_NOLAUNCH: no tray app in the employee's session (it would take Tailscale over for that account).
    Install-VendorMsi 'tailscale' @('TS_NOLAUNCH=1')
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Get-Service Tailscale -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
} else {
    Note 'Tailscale is already installed.'
}

function Get-TailscaleStatus {
    $r = Invoke-Exe $tailscale @('status', '--json') 30
    if ($r.ExitCode -ne 0 -and -not $r.Out) { return $null }
    try { $r.Out | ConvertFrom-Json } catch { $null }
}
function Test-Ours($s) {
    if (-not $s -or -not $s.Self) { return $false }
    $tags = @(); if ($s.Self.PSObject.Properties['Tags'] -and $s.Self.Tags) { $tags = @($s.Self.Tags) }
    $suffix = if ($s.PSObject.Properties['MagicDNSSuffix']) { $s.MagicDNSSuffix } else { '' }
    ($suffix -eq $TailnetSuffix) -and ($tags -contains $ClientTag -or $tags -contains 'tag:rdp-client')
}

$status = Get-TailscaleStatus
if ($status -and $status.BackendState -eq 'Running' -and (Test-Ours $status)) {
    Note 'Already connected to the company network.'
} else {
    if ($status -and $status.BackendState -eq 'Running') {
        Fail "This computer is already connected to a different private network (Tailscale), so setup stopped." "suffix=$($status.MagicDNSSuffix)"
    }
    # The one-time code from IT (a single-use Tailscale auth key): typed or pasted, never shown, never logged.
    $AuthKey = ''
    for ($try = 1; $try -le 3 -and -not $AuthKey; $try++) {
        Write-Host ''
        $secure = Read-Host '   Paste the one-time code IT sent you (it starts with tskey-auth-), then press Enter' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $typed = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($typed -like 'tskey-auth-*') { $AuthKey = $typed }
        else { Write-Host "   That doesn't look like the code from IT. Please copy it again (it starts with tskey-auth-)." -ForegroundColor Yellow }
    }
    if (-not $AuthKey) { Fail 'Setup needs the one-time code from IT to connect this computer.' 'no valid auth key entered' }
    # The key goes to tailscale in a file in an admin-only folder: never on a command line, never in the log.
    $keyDir = New-AdminOnlyFolder 'join'
    $keyFile = Join-Path $keyDir 'authkey'
    try {
        [IO.File]::WriteAllText($keyFile, $AuthKey, (New-Object Text.UTF8Encoding($false)))
        Note 'Joining the company network.'
        $r = Invoke-Exe $tailscale @('up', "--auth-key=file:$keyFile", "--advertise-tags=$ClientTag", "--hostname=$hostname",
            '--unattended', '--timeout=60s') 120
        Write-Log ("tailscale up exit {0}: {1} {2}" -f $r.ExitCode, (Hide-Secrets $r.Out), (Hide-Secrets $r.Err))
    } finally {
        Remove-Item -LiteralPath $keyDir -Recurse -Force -ErrorAction SilentlyContinue
        $AuthKey = $null
    }
    $status = Get-TailscaleStatus
    if (-not $status -or $status.BackendState -notin @('Running', 'NeedsMachineAuth')) {
        $text = "$($r.Out) $($r.Err)".ToLowerInvariant()
        if ($text -match 'tag' -and $text -match 'not permitted|invalid|not allowed') {
            Fail "The company network turned the one-time code down. Ask IT for a new code, then paste the command again." (Hide-Secrets $text)
        }
        Fail "This computer couldn't connect to the company network. Check that you're online, and that the one-time code hasn't been used or expired (ask IT for a new one)." ("state " + $(if ($status) { $status.BackendState } else { 'unknown' }))
    }
    [void](Invoke-Exe $tailscale @('set', '--auto-update') 30)
}

if ($status.BackendState -eq 'NeedsMachineAuth') {
    Write-Host ''
    Write-Host "   Waiting for IT to approve this computer..." -ForegroundColor Yellow
    Write-Host "   If it takes more than a few minutes, contact $SupportContact and give them this name: $hostname"
    Write-Log 'Waiting for approval.'
    while ($true) {
        Start-Sleep 3
        $status = Get-TailscaleStatus
        if ($status -and $status.BackendState -eq 'Running') { break }
        if ($status -and $status.BackendState -eq 'NeedsLogin') { Fail 'IT removed this computer before approving it.' 'NeedsLogin during approval wait' }
    }
    Say 'Approved by IT.'
}
if (-not (Test-Ours $status)) { Fail 'This computer connected, but not to the company network as expected.' "suffix=$($status.MagicDNSSuffix)" }
Say 'Connected.'

# -- 4. RustDesk --------------------------------------------------------------------------------------
Step 'Setting up IT support'
$rustdesk = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
$rdOptions = [ordered]@{
    'custom-rendezvous-server' = '127.0.0.1'   # never RustDesk's public servers
    'relay-server'             = '127.0.0.1'
    'api-server'               = 'http://127.0.0.1'
    'direct-server'            = 'Y'           # direct connections on tcp 21118 ...
    'whitelist'                = ($TailnetRanges -join ',')   # ... from Tailscale addresses only
    'approve-mode'             = 'click'       # the employee clicks Accept for every session
    'enable-lan-discovery'     = 'N'
    'allow-auto-update'        = 'Y'
}
if (-not (Test-Path $rustdesk)) {
    # Write the settings BEFORE installing: the service starts as soon as the MSI finishes.
    $rdConfig = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml'
    New-Item -ItemType Directory -Force -Path (Split-Path $rdConfig) | Out-Null
    $toml = "[options]`n" + (($rdOptions.GetEnumerator() | ForEach-Object { "$($_.Key) = '$($_.Value)'" }) -join "`n") + "`n"
    if (Test-Path $rdConfig) { Write-Log 'RustDesk2.toml already exists; options are applied after install instead.' }
    else { [IO.File]::WriteAllText($rdConfig, $toml, (New-Object Text.UTF8Encoding($false))) }
    Install-VendorMsi 'rustdesk' @('CREATEDESKTOPSHORTCUTS=N', 'INSTALLPRINTER=N')
} else {
    Note 'RustDesk is already installed; re-applying its settings.'
}
$svc = Get-Service RustDesk -ErrorAction SilentlyContinue
if (-not $svc) { Fail "IT's support tools couldn't be set up." 'no RustDesk service' }
if ($svc.Status -ne 'Running') { Start-Service RustDesk }
(Get-Service RustDesk).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
$wrong = @()
foreach ($o in $rdOptions.GetEnumerator()) { [void](Invoke-Exe $rustdesk @('--option', $o.Key, $o.Value) 30) }
foreach ($o in $rdOptions.GetEnumerator()) {
    $actual = (Invoke-Exe $rustdesk @('--option', $o.Key) 30).Out.Trim()
    if ($actual -ne $o.Value) { $wrong += "$($o.Key)='$actual'" }
}
if ($wrong) { Fail "IT's support tools couldn't be set up." ("RustDesk options: " + ($wrong -join '; ')) }
Note 'RustDesk configured: direct connections from Tailscale addresses only, click-to-accept.'

# -- 5. OpenSSH Server + tak-it -----------------------------------------------------------------------
Note 'Setting up OpenSSH Server for IT.'
$sshData = Join-Path $env:ProgramData 'ssh'
New-Item -ItemType Directory -Force -Path $sshData | Out-Null
& icacls.exe $sshData /setowner '*S-1-5-32-544' | Out-Null
& icacls.exe $sshData /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX' | Out-Null

$sshBin = Join-Path $env:ProgramFiles 'OpenSSH'
$sshdConfig = @"
# Managed by TAK Remote Access Setup (script $ScriptVersion): rewritten on every run, local edits are replaced.
# IT remote support: key logins only, only for "$SshAccount", only from the company's Tailscale network.
Port 22

AllowUsers $SshAccount
AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
# Off for everyone, then on again only for tailnet sources (see the Match block at the end).
PubkeyAuthentication no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30

# A shell and file copy only: no tunnels through this PC.
AllowTcpForwarding no
AllowAgentForwarding no
GatewayPorts no

# Every login (account, source address, key fingerprint) goes to the OpenSSH/Operational event log.
LogLevel VERBOSE

Subsystem sftp "$(($sshBin -replace '\\', '/'))/sftp-server.exe"

Match Address $($TailnetRanges -join ',')
	PubkeyAuthentication yes
"@ -replace "`r`n", "`n"
# Written BEFORE the MSI, which starts sshd straight away: it never runs with Microsoft's defaults.
[IO.File]::WriteAllText((Join-Path $sshData 'sshd_config'), $sshdConfig + "`n", (New-Object Text.UTF8Encoding($false)))
$keysFile = Join-Path $sshData 'administrators_authorized_keys'
[IO.File]::WriteAllText($keysFile, "# Managed by TAK Remote Access Setup (script).`n" + ($SshAdminKeys -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
& icacls.exe $keysFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null

$sshdExe = Join-Path $sshBin 'sshd.exe'
if (-not (Test-Path $sshdExe)) {
    Install-VendorMsi 'openssh' @('ADDLOCAL=Server', 'MSIRESTARTMANAGERCONTROL=Disable')
} else {
    Note 'OpenSSH Server is already installed.'
}

# The account IT's SSH key logs in to. Its password is random, never shown or stored: nobody knows it.
$chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?@'
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 40
$rng.GetBytes($bytes)
$secure = New-Object Security.SecureString
foreach ($b in $bytes) { $secure.AppendChar($chars[$b % $chars.Length]) }
$secure.MakeReadOnly()
$description = 'TAK IT: SSH key logins only (remote support)'
if (Get-LocalUser -Name $SshAccount -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $SshAccount -Password $secure -PasswordNeverExpires $true -Description $description
    Enable-LocalUser -Name $SshAccount
    Note "Account $SshAccount already exists; its password was replaced (nobody knows it)."
} else {
    New-LocalUser -Name $SshAccount -Password $secure -FullName 'TAK IT support (remote)' -Description $description `
        -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Note "Created the account $SshAccount (""TAK IT support (remote)"")."
}
$admins = Get-LocalGroup -SID 'S-1-5-32-544'
try {
    Add-LocalGroupMember -Group $admins -Member $SshAccount -ErrorAction Stop
} catch [Microsoft.PowerShell.Commands.MemberExistsException] {
    Write-Log "$SshAccount is already in $($admins.Name)."
}

# It may not sign in at the keyboard or over Remote Desktop: SSH with IT's key is the only way in.
$sid = (Get-LocalUser -Name $SshAccount).SID.Value
$secDir = New-AdminOnlyFolder 'rights'
try {
    $inf = Join-Path $secDir 'rights.inf'
    $r = Invoke-Exe "$env:SystemRoot\System32\secedit.exe" @('/export', '/cfg', $inf, '/areas', 'USER_RIGHTS') 60
    $lines = [Collections.Generic.List[string]](Get-Content -LiteralPath $inf -Encoding Unicode)
    foreach ($right in 'SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight') {
        $idx = -1
        for ($n = 0; $n -lt $lines.Count; $n++) { if ($lines[$n] -like "$right *") { $idx = $n } }
        if ($idx -ge 0) {
            if ($lines[$idx] -notlike "*$sid*") { $lines[$idx] = $lines[$idx] + ",*$sid" }
        } else {
            $section = $lines.IndexOf('[Privilege Rights]')
            $lines.Insert($section + 1, "$right = *$sid")
        }
    }
    Set-Content -LiteralPath $inf -Value $lines -Encoding Unicode
    $r = Invoke-Exe "$env:SystemRoot\System32\secedit.exe" @('/configure', '/db', (Join-Path $secDir 'rights.sdb'), '/cfg', $inf, '/areas', 'USER_RIGHTS', '/quiet') 120
    if ($r.ExitCode -ne 0) { Fail "IT's support tools couldn't be set up." "secedit exit $($r.ExitCode): $($r.Out) $($r.Err)" }
} finally {
    Remove-Item -LiteralPath $secDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Log "$SshAccount ($sid): denied local and Remote Desktop sign-in."

# Firewall: only Tailscale addresses may reach port 22. The MSI's own rule allows any source: remove it.
Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -eq 'OpenSSH SSH Server Preview (sshd)' -or $_.Name -eq 'OpenSSH-Server-In-TCP' -or $_.DisplayName -eq 'TAK IT support (SSH)'
} | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'TAK IT support (SSH)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 `
    -RemoteAddress $TailnetRanges -LocalAddress $TailnetRanges -Profile Any | Out-Null

$check = Invoke-Exe $sshdExe @('-t') 30
if ($check.ExitCode -ne 0) { Fail "IT's support tools couldn't be set up." "sshd -t: $($check.Err)" }
Set-Service sshd -StartupType Automatic
Restart-Service sshd
$agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
if ($agent) { Stop-Service ssh-agent -ErrorAction SilentlyContinue; Set-Service ssh-agent -StartupType Disabled }
Note "SSH configured: IT's keys only, only as $SshAccount, only from Tailscale addresses."
Say 'Done. IT can only see your screen after you click Accept.'

# -- 6. Tell the dashboard, shortcut, state -----------------------------------------------------------
Step 'Finishing'
try {
    $body = @{ volume = $drive; protectionStatus = [int]$vol.ProtectionStatus; conversionStatus = $conversion; setupVersion = "script-$ScriptVersion" } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "http://${DashboardHost}:$IntakePort/api/bitlocker/ready" -Body $body -ContentType 'application/json' -TimeoutSec 10 | Out-Null
    Note 'Told the IT dashboard to check this computer now.'
} catch {
    Write-Log "Dashboard ready ping failed: $($_.Exception.Message)" 'WARN'
}

$lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$ShortcutName.lnk"
$shell = New-Object -ComObject WScript.Shell
$s = $shell.CreateShortcut($lnk)
$s.TargetPath = "$env:SystemRoot\System32\mstsc.exe"
$s.Arguments = "/v:$RdpServerHost /multimon"
$s.WorkingDirectory = "$env:SystemRoot\System32"
$s.IconLocation = "$env:SystemRoot\System32\mstsc.exe,0"
$s.Description = 'Connect to The Alt Key remote desktop server'
$s.Save()
Note "Created $lnk."

# "Get IT Help": a link to the IT dashboard's help page (no program to install). The page identifies this PC by its
# company-network address, so it only works on this computer.
$helpUrl = "http://${DashboardHost}:$IntakePort/help"
$helpLink = "[InternetShortcut]`r`nURL=$helpUrl`r`nIconFile=$env:SystemRoot\System32\shell32.dll`r`nIconIndex=23`r`n"
foreach ($folder in [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms')) {
    $path = Join-Path $folder 'Get IT Help.url'
    [IO.File]::WriteAllText($path, $helpLink, (New-Object Text.UTF8Encoding($false)))
    Note "Created $path -> $helpUrl"
}
Say 'Added two icons to your desktop.'

$state = [ordered]@{
    version   = "script-$ScriptVersion"
    device    = $hostname
    completed = (Get-Date).ToString('o')
    mode      = 'script'
    takhelp   = ''
    sshd      = (Get-Item $sshdExe).VersionInfo.FileVersion
    bitlocker = $bitLockerState
    escrowed  = ''
}
[IO.File]::WriteAllText((Join-Path $DataDir 'device-state.txt'), (($state.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "You're all set." -ForegroundColor Green
Write-Host "   ""$ShortcutName"" on your desktop connects you to the office server. It starts working within"
Write-Host '   a few minutes, once IT''s automatic security check has run.'
Write-Host '   "Get IT Help" on your desktop sends a message to IT if anything goes wrong.'
Write-Log 'Setup finished.'
Read-Host 'Press Enter to close' | Out-Null
[Environment]::Exit(0)
