#Requires -Version 5.1
<#
.SYNOPSIS
    WinRegister - Register any program with Windows Search, Start Menu, Run dialog,
    and Apps & Features.

.DESCRIPTION
    Makes portable apps, standalone executables, and extracted programs appear in
    Windows Search, the Start Menu, the Run dialog (Win+R), and Apps & Features -
    the same way installed apps do.

    Mechanism (per-user, no admin):
      - Creates a Start Menu .lnk with an explicit AppUserModelID (per Microsoft
        Win32 Shell spec, PascalCased, <=128 chars, no spaces).
      - Optional HKCU\...\App Paths entry for Win+R launching by name.
      - HKCU\...\Uninstall (ARP) record for Apps & Features visibility.
      - All operations are idempotent, atomic, and rollback-safe.

    Designed to be invoked from the Windows Explorer right-click menu after a
    one-time Install. Can also be used from the command line.

.PARAMETER Register
    Path to register. Accepts an .exe (registered directly), a .lnk (target
    resolved), or a folder (primary executable auto-detected).

.PARAMETER Unregister
    Path of a previously-registered item to remove.

.PARAMETER Install
    One-time setup: copies this script to %LOCALAPPDATA%\WinRegister and adds
    the Explorer right-click "Register with Windows" / "Unregister from Windows"
    entries.

.PARAMETER Uninstall
    Removes the context menu entries. With -Purge, also removes every
    registration WinRegister has ever created.

.PARAMETER Purge
    Modifier for -Uninstall: also remove every registration.

.PARAMETER List
    List all programs currently registered by WinRegister.

.PARAMETER Repair
    Scan all registrations; remove entries whose target executable no longer
    exists, and recreate missing artefacts for entries that still resolve.

.PARAMETER Doctor
    Print a diagnostic snapshot: install state, context menu, registry sanity,
    log location, and per-registration health.

.PARAMETER DisplayName
    Override the auto-detected display name.

.PARAMETER NoConfirm
    Skip the confirmation dialog (CLI/scripting only - context menu always
    confirms).

.PARAMETER Silent
    Suppress success toasts. Errors are still shown.

.EXAMPLE
    .\WinRegister.ps1 -Install

.EXAMPLE
    .\WinRegister.ps1 -Register "D:\Tools\r2modman"

.EXAMPLE
    .\WinRegister.ps1 -Unregister "D:\Tools\r2modman\r2modman.exe"

.EXAMPLE
    .\WinRegister.ps1 -Doctor

.NOTES
    Requires Windows 10/11 + Windows PowerShell 5.1 (or PowerShell 7+).
    Per-user installation - no administrator rights required.

    Sources of design correctness (verified):
      - PE format: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
      - App Paths: https://learn.microsoft.com/en-us/windows/win32/shell/app-registration
      - AppUserModelID: https://learn.microsoft.com/en-us/windows/win32/shell/appids
      - Uninstall (ARP): https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key
      - High DPI: https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows
#>

[CmdletBinding(DefaultParameterSetName = 'Help')]
param(
    [Parameter(ParameterSetName = 'Register', Mandatory, Position = 0)]
    [string]$Register,

    [Parameter(ParameterSetName = 'Unregister', Mandatory, Position = 0)]
    [string]$Unregister,

    [Parameter(ParameterSetName = 'Unregister')]
    [switch]$ForceUnregister,

    [Parameter(ParameterSetName = 'Install', Mandatory)]
    [switch]$Install,

    # When set, the script will not write its own Apps & Features entry -
    # used by the Inno Setup installer so its native ARP entry is canonical.
    [Parameter(ParameterSetName = 'Install')]
    [switch]$SkipSelfArp,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Purge,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$List,

    [Parameter(ParameterSetName = 'Repair', Mandatory)]
    [switch]$Repair,

    [Parameter(ParameterSetName = 'Doctor', Mandatory)]
    [switch]$Doctor,

    [Parameter(ParameterSetName = 'Settings', Mandatory)]
    [switch]$Settings,

    [Parameter(ParameterSetName = 'CheckUpdate', Mandatory)]
    [switch]$CheckUpdate,

    [Parameter(ParameterSetName = 'Version', Mandatory)]
    [switch]$Version,

    [Parameter(ParameterSetName = 'SelfTest', Mandatory)]
    [switch]$SelfTest,

    [Parameter(ParameterSetName = 'Register')]
    [string]$DisplayName,

    [Parameter(ParameterSetName = 'Register')]
    [switch]$NoConfirm,

    [Parameter()]
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
# Note: deliberately NOT using `Set-StrictMode -Version Latest` here.
# StrictMode v3+ throws on access to undefined PSCustomObject properties,
# which collides with forward-compat reads of registrations.json across
# script versions. We use defensive accessors via Get-SafeProperty instead.

#region Configuration ----------------------------------------------------------

$script:Cfg = [pscustomobject]@{
    Version              = '1.3.0'
    SchemaVersion        = 2
    SettingsSchemaVersion= 2
    AppName              = 'WinRegister'
    Publisher            = 'trustxix'
    HomepageUrl          = 'https://github.com/trustxix/winregister'
    UpdateApiUrl         = 'https://api.github.com/repos/trustxix/winregister/releases/latest'
    StartMenuFolder      = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    SelfStartMenuFolder  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WinRegister'
    DataFolder           = Join-Path $env:LOCALAPPDATA 'WinRegister'
    InstalledScript      = Join-Path $env:LOCALAPPDATA 'WinRegister\WinRegister.ps1'
    InstalledShim        = Join-Path $env:LOCALAPPDATA 'WinRegister\winregister.cmd'
    HiddenLauncher       = Join-Path $env:LOCALAPPDATA 'WinRegister\winregister-launcher.vbs'
    RegistryFile         = Join-Path $env:LOCALAPPDATA 'WinRegister\registrations.json'
    SettingsFile         = Join-Path $env:APPDATA       'WinRegister\settings.json'
    SettingsFolder       = Join-Path $env:APPDATA       'WinRegister'
    LogFile              = Join-Path $env:LOCALAPPDATA 'WinRegister\winregister.log'
    LogMaxBytes          = 1MB
    SelfArpId            = 'WinRegister.Self'
    AppPathsRoot         = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths'
    UninstallRoot        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    ContextRoot          = 'HKCU:\Software\Classes'
    ContextVerbId        = 'WinRegister.Register'
    ContextUnregVerbId   = 'WinRegister.Unregister'
    ContextLabel         = 'Register with Windows'
    ContextUnregLabel    = 'Unregister from Windows'
    ContextIconRegister  = 'imageres.dll,-5323'
    ContextIconUnregister= 'imageres.dll,-5366'
    ClassicMenuClsidKey  = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    ClassicMenuInprocKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    ClassicMenuMarker    = Join-Path $env:LOCALAPPDATA 'WinRegister\.classic-menu-owned-by-us'
    MaxArpDisplayName    = 32
    MaxAumid             = 128
    MaxPascalSegment     = 80
    # Conservative blacklist: catches obvious installers, uninstallers, and helper
    # binaries that shouldn't be registered as user-facing apps. Refined to avoid
    # false-positives against legitimate portable tools (e.g., a user's portable
    # Python install is now allowed; previously 'python' was an exact-match block).
    # Users can override per-call with -Force, or extend via Settings.Registration.ExtraBlacklist.
    BlacklistPatterns    = @(
        'unins000', 'unins001', 'unins002', 'uninstall', 'uninst', 'uninst*',
        'setup', 'setup_*', 'installer',
        'vc_redist*', 'vcredist*', 'msvcr*', 'msvcp*', 'ucrtbase*',
        'crashpad_handler', '*crashreporter*', '*crash_handler*', '*-crashpad*',
        'dxsetup', 'dotnet-host*', 'msedgewebview2',
        '*-helper', '*_helper', '* Helper',
        '*-gpu', '*_gpu',
        'elevate', 'elevation_service'
    )
    ProtectedPaths       = @(
        $env:WINDIR,
        (Join-Path $env:WINDIR 'System32'),
        (Join-Path $env:WINDIR 'SysWOW64'),
        (Join-Path $env:WINDIR 'WinSxS')
    )
}

#endregion

#region Defensive helpers -----------------------------------------------------

function Get-SafeProperty {
    # Strict-mode-safe accessor for PSCustomObject / hashtable properties.
    # Returns $Default if the property is missing.
    param(
        $Object,
        [Parameter(Mandatory)] [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $props = $Object.PSObject.Properties
    if ($props -and $props[$Name]) { return $props[$Name].Value }
    return $Default
}

#endregion

#region Logging --------------------------------------------------------------

function Initialize-DataFolder {
    if (-not (Test-Path -LiteralPath $script:Cfg.DataFolder)) {
        New-Item -ItemType Directory -Path $script:Cfg.DataFolder -Force | Out-Null
    }
}

function Resize-LogFile {
    try {
        if (-not (Test-Path -LiteralPath $script:Cfg.LogFile)) { return }
        $f = Get-Item -LiteralPath $script:Cfg.LogFile
        if ($f.Length -gt $script:Cfg.LogMaxBytes) {
            # Rotate: keep tail half of the log
            $bytes = [System.IO.File]::ReadAllBytes($script:Cfg.LogFile)
            $halfStart = [int]($bytes.Length / 2)
            # Find next newline boundary so we don't truncate mid-line
            while ($halfStart -lt $bytes.Length -and $bytes[$halfStart] -ne 0x0A) {
                $halfStart++
            }
            if ($halfStart -lt $bytes.Length) { $halfStart++ }
            $tail = $bytes[$halfStart..($bytes.Length - 1)]
            $header = [System.Text.Encoding]::UTF8.GetBytes(
                "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] log rotated`r`n")
            [System.IO.File]::WriteAllBytes($script:Cfg.LogFile, ($header + $tail))
        }
    } catch { }
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Debug')] [string]$Level = 'Info'
    )
    try {
        Initialize-DataFolder
        Resize-LogFile
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $line = "[$stamp] [$Level] $Message"
        Add-Content -LiteralPath $script:Cfg.LogFile -Value $line -Encoding UTF8
        if ($VerbosePreference -eq 'Continue' -or $Level -in 'Warn', 'Error') {
            $color = @{ Info = 'Gray'; Warn = 'Yellow'; Error = 'Red'; Debug = 'DarkGray' }[$Level]
            Write-Host $line -ForegroundColor $color
        }
    } catch {
        # Logging must never throw.
    }
}

#endregion

#region Settings persistence --------------------------------------------------
# Per-user settings live in %APPDATA%\WinRegister\settings.json (the
# professional convention: PowerToys, VS Code, Discord, every modern app
# uses this exact location for per-user config). Atomic Move-Item writes.

function Get-DefaultSettings {
    [pscustomobject]@{
        SchemaVersion = $script:Cfg.SettingsSchemaVersion
        Confirmation = [pscustomobject]@{
            AskOnRegister   = $true   # show confirmation dialog before registering
            AskOnUnregister = $true   # show confirmation dialog before unregistering
        }
        Notifications = [pscustomobject]@{
            ShowOnRegister   = $true   # toast after successful register
            ShowOnUnregister = $true   # toast after successful unregister
        }
        Updates = [pscustomobject]@{
            CheckEnabled       = $true
            CheckFrequencyDays = 1
            LastCheckedAt      = '1970-01-01T00:00:00Z'
            LastSeenVersion    = '0.0.0'
            SkippedVersion     = ''   # user clicked "skip this version"
        }
        Registration = [pscustomobject]@{
            AutoDetectPrimaryExe = $true     # in folder mode, auto-pick the main exe
            StartMenuSubfolder   = ''        # optional subfolder under Programs (empty = top-level)
            ExtraBlacklist       = @()       # user-added blacklist patterns
            FolderScanDepth      = 4         # max recursion when scanning folders for the main .exe
        }
        Modified = (Get-Date).ToString('o')
    }
}

function Initialize-SettingsFolder {
    if (-not (Test-Path -LiteralPath $script:Cfg.SettingsFolder)) {
        New-Item -ItemType Directory -Path $script:Cfg.SettingsFolder -Force | Out-Null
    }
}

function Merge-SettingsDefaults {
    # Recursively fill missing properties on $loaded from $defaults. Also
    # validates type compatibility: if a user has manually edited settings.json
    # and entered an incompatible type (e.g., a string where a bool was expected),
    # we revert to the default for that field rather than letting the value
    # propagate and trigger a runtime error later.
    param($Loaded, $Defaults)
    if ($null -eq $Loaded)   { return $Defaults }
    if ($null -eq $Defaults) { return $Loaded }
    foreach ($prop in $Defaults.PSObject.Properties) {
        $name = $prop.Name
        $defVal = $prop.Value
        $hasIt = $Loaded.PSObject.Properties[$name]
        if (-not $hasIt) {
            Add-Member -InputObject $Loaded -NotePropertyName $name -NotePropertyValue $defVal -Force
            continue
        }
        $loadedVal = $hasIt.Value
        # Recurse on nested objects.
        if ($defVal -is [pscustomobject] -and $loadedVal -is [pscustomobject]) {
            $Loaded.$name = Merge-SettingsDefaults -Loaded $loadedVal -Defaults $defVal
            continue
        }
        # Type compatibility check. Booleans and numerics in JSON can come back
        # as strings if the user edited by hand - try a soft coerce, then fall
        # back to the default on failure.
        if ($null -ne $defVal -and $null -ne $loadedVal) {
            $defType = $defVal.GetType()
            if (-not ($loadedVal -is $defType)) {
                try {
                    if ($defType -eq [bool])   { $Loaded.$name = [bool]::Parse([string]$loadedVal); continue }
                    if ($defType -eq [int])    { $Loaded.$name = [int]::Parse([string]$loadedVal); continue }
                    if ($defType -eq [string]) { $Loaded.$name = [string]$loadedVal; continue }
                    if ($defType.IsArray)      { $Loaded.$name = @($loadedVal); continue }
                } catch { }
                Write-Log "Settings: type mismatch on '$name' (expected $($defType.Name)); reverting to default." -Level Warn
                $Loaded.$name = $defVal
            }
        }
    }
    return $Loaded
}

function Get-Settings {
    $defaults = Get-DefaultSettings
    if (-not (Test-Path -LiteralPath $script:Cfg.SettingsFile)) {
        return $defaults
    }
    try {
        $raw = Get-Content -LiteralPath $script:Cfg.SettingsFile -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return $defaults }
        $loaded = $raw | ConvertFrom-Json
        # Merge defaults to handle older files missing new fields
        return Merge-SettingsDefaults -Loaded $loaded -Defaults $defaults
    } catch {
        Write-Log "Could not parse settings; using defaults: $_" -Level Warn
        return $defaults
    }
}

function Save-Settings {
    # Atomic, file-locked write. The lock prevents the rare but real race when
    # two settings UIs or a UI + an update check both try to save at the same
    # time. Pattern: temp file + Move-Item replace + retry on contention.
    param([pscustomobject]$Settings)
    Initialize-SettingsFolder
    $Settings | Add-Member -NotePropertyName 'Modified' -NotePropertyValue (Get-Date).ToString('o') -Force
    $json = $Settings | ConvertTo-Json -Depth 10
    $tmp = "$($script:Cfg.SettingsFile).tmp"

    $maxAttempts = 50   # 5 seconds total at 100ms back-off
    for ($i = 1; $i -le $maxAttempts; $i++) {
        try {
            # Hold exclusive write on the temp file until we've serialized, then
            # release before the atomic Move-Item (Move requires no open handles).
            $fs = [System.IO.File]::Open(
                $tmp,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush()
            } finally {
                $fs.Dispose()
            }
            Move-Item -LiteralPath $tmp -Destination $script:Cfg.SettingsFile -Force
            return
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    throw "Could not write settings.json after $maxAttempts attempts"
}

function Backup-File {
    # Snapshot a file to <path>.bak.<UTC>. Used before destructive operations
    # like Reset-Settings or PurgeAllRegistrations. Caller can ignore failure;
    # backup is best-effort and never blocks the primary operation.
    param([string]$Path, [string]$Tag = '')
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $suffix = if ($Tag) { "$Tag-$stamp" } else { $stamp }
        $bak = "$Path.bak.$suffix"
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        Write-Log "Backed up $Path -> $bak"
        return $bak
    } catch {
        Write-Log "Backup of $Path failed (non-fatal): $_" -Level Warn
        return $null
    }
}

function Reset-Settings {
    if (Test-Path -LiteralPath $script:Cfg.SettingsFile) {
        # Best-effort snapshot before destroying user state.
        Backup-File -Path $script:Cfg.SettingsFile -Tag 'reset' | Out-Null
        Remove-Item -LiteralPath $script:Cfg.SettingsFile -Force
    }
    Save-Settings -Settings (Get-DefaultSettings)
}

#endregion

#region Update checker (GitHub Releases API) ----------------------------------
# Polls the repo's /releases/latest endpoint. Respects:
#   - User-Agent header (mandatory per GitHub docs, else 403)
#   - Rate-limit-friendly TTL (default daily, configurable in settings)
#   - User opt-out (Settings.Updates.CheckEnabled = false)
#   - "Skip this version" (Settings.Updates.SkippedVersion)
# Returns $null if no update; PSCustomObject with .Version, .Url, .Notes if one is available.

function Compare-SemVer {
    # Returns -1 if $a < $b, 0 if equal, 1 if $a > $b. Strips leading 'v'.
    param([string]$A, [string]$B)
    try {
        $va = [Version]($A -replace '^v','' -replace '-.+$','')
        $vb = [Version]($B -replace '^v','' -replace '-.+$','')
        return $va.CompareTo($vb)
    } catch {
        return 0
    }
}

function Test-UpdateAvailable {
    param(
        [pscustomobject]$Settings,
        [switch]$Force   # bypass frequency throttle (used by "Check now" button)
    )

    if (-not $Settings.Updates.CheckEnabled -and -not $Force) {
        return $null
    }

    # Respect frequency
    if (-not $Force) {
        try {
            $last = [DateTime]::Parse($Settings.Updates.LastCheckedAt)
            $age  = (Get-Date).ToUniversalTime() - $last.ToUniversalTime()
            if ($age.TotalDays -lt $Settings.Updates.CheckFrequencyDays) {
                return $null
            }
        } catch { }
    }

    # Update LastCheckedAt now, regardless of outcome (so failures don't hammer the API).
    $Settings.Updates.LastCheckedAt = (Get-Date).ToString('o')

    # Result has three possible Status values:
    #   'UpdateAvailable' - newer release found (.Version, .Url, .Notes populated)
    #   'UpToDate'        - check succeeded, current is latest
    #   'CheckFailed'     - network error, 404, rate-limited, etc.
    try {
        # GitHub requires a User-Agent header. Use our own identifier.
        $headers = @{
            'User-Agent' = "WinRegister/$($script:Cfg.Version) (+$($script:Cfg.HomepageUrl))"
            'Accept'     = 'application/vnd.github+json'
        }
        $resp = Invoke-RestMethod -Uri $script:Cfg.UpdateApiUrl -Headers $headers -TimeoutSec 8 -ErrorAction Stop
    } catch {
        Write-Log "Update check failed (non-fatal): $_" -Level Warn
        Save-Settings -Settings $Settings
        return [pscustomobject]@{ Status = 'CheckFailed'; ErrorMessage = $_.Exception.Message }
    }

    $tag = "$($resp.tag_name)"
    if (-not $tag) {
        Save-Settings -Settings $Settings
        return [pscustomobject]@{ Status = 'CheckFailed'; ErrorMessage = 'Empty tag_name in response' }
    }

    $latestNormalized = $tag -replace '^v',''
    $Settings.Updates.LastSeenVersion = $latestNormalized
    Save-Settings -Settings $Settings

    if ($Settings.Updates.SkippedVersion -and ($Settings.Updates.SkippedVersion -eq $latestNormalized)) {
        return [pscustomobject]@{ Status = 'UpToDate' }   # user-skipped; treat as up-to-date silently
    }

    if ((Compare-SemVer -A $latestNormalized -B $script:Cfg.Version) -gt 0) {
        return [pscustomobject]@{
            Status  = 'UpdateAvailable'
            Version = $latestNormalized
            Url     = "$($resp.html_url)"
            Notes   = "$($resp.body)"
            Title   = "$($resp.name)"
        }
    }
    return [pscustomobject]@{ Status = 'UpToDate' }
}

function Show-UpdateNotification {
    param(
        [pscustomobject]$Update,
        [pscustomobject]$Settings
    )
    if (-not $Update) { return }

    Initialize-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WinRegister - Update available'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object System.Drawing.Size(480, 230)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.TopMost = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "WinRegister $($Update.Version) is available"
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(20, 18)
    $form.Controls.Add($title)

    $current = New-Object System.Windows.Forms.Label
    $current.Text = "You're running $($script:Cfg.Version). The latest release is $($Update.Version)."
    $current.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
    $current.AutoSize = $true
    $current.Location = New-Object System.Drawing.Point(20, 45)
    $form.Controls.Add($current)

    $notes = New-Object System.Windows.Forms.TextBox
    $notes.Multiline = $true
    $notes.ScrollBars = 'Vertical'
    $notes.ReadOnly = $true
    $notes.Text = if ($Update.Notes) { $Update.Notes } else { '(no release notes)' }
    $notes.Location = New-Object System.Drawing.Point(20, 75)
    $notes.Size = New-Object System.Drawing.Size(440, 90)
    $notes.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($notes)

    $skip = New-Object System.Windows.Forms.Button
    $skip.Text = 'Skip this version'
    $skip.Size = New-Object System.Drawing.Size(120, 30)
    $skip.Location = New-Object System.Drawing.Point(20, 180)
    $skip.Add_Click({
        $Settings.Updates.SkippedVersion = $Update.Version
        Save-Settings -Settings $Settings
        $form.DialogResult = 'Cancel'; $form.Close()
    })
    $form.Controls.Add($skip)

    $later = New-Object System.Windows.Forms.Button
    $later.Text = 'Remind me later'
    $later.Size = New-Object System.Drawing.Size(120, 30)
    $later.Location = New-Object System.Drawing.Point(210, 180)
    $later.DialogResult = 'Cancel'
    $form.Controls.Add($later)

    $download = New-Object System.Windows.Forms.Button
    $download.Text = 'Download'
    $download.Size = New-Object System.Drawing.Size(110, 30)
    $download.Location = New-Object System.Drawing.Point(350, 180)
    $download.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $download.ForeColor = [System.Drawing.Color]::White
    $download.FlatStyle = 'Flat'; $download.FlatAppearance.BorderSize = 0
    $download.Add_Click({
        try { Start-Process $Update.Url | Out-Null } catch { }
        $form.DialogResult = 'OK'; $form.Close()
    })
    $form.Controls.Add($download)
    $form.AcceptButton = $download
    $form.CancelButton = $later

    $form.Add_Shown({
        $form.TopMost = $false; $form.TopMost = $true
        try { [WinRegister.Native]::ForceForeground($form.Handle) } catch { }
    })
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

function Invoke-StartupUpdateCheck {
    # Called once per script invocation, gated by frequency and user setting.
    # Silent failure - never blocks the user's actual operation.
    try {
        $settings = Get-Settings
        $result = Test-UpdateAvailable -Settings $settings
        if ($result -and $result.Status -eq 'UpdateAvailable') {
            Show-UpdateNotification -Update $result -Settings $settings
        }
    } catch {
        Write-Log "Startup update check failed: $_" -Level Warn
    }
}

#endregion

#region Native interop --------------------------------------------------------

function Initialize-Native {
    if ('WinRegister.Native' -as [type]) { return }

    $cs = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace WinRegister
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class CShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
     Guid("000214F9-0000-0000-C000-000000000046")]
    public interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out ushort pwHotkey);
        void SetHotkey(ushort wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
     Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    public interface IPropertyStore
    {
        int GetCount(out uint cProps);
        int GetAt(uint iProp, out PROPERTYKEY pkey);
        int GetValue([In] ref PROPERTYKEY key, [Out] PropVariant pv);
        int SetValue([In] ref PROPERTYKEY key, [In] PropVariant pv);
        int Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;
        public PROPERTYKEY(Guid fmtid, uint pid) { this.fmtid = fmtid; this.pid = pid; }
    }

    [StructLayout(LayoutKind.Explicit)]
    public class PropVariant : IDisposable
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(2)] public ushort wReserved1;
        [FieldOffset(4)] public ushort wReserved2;
        [FieldOffset(6)] public ushort wReserved3;
        [FieldOffset(8)] public IntPtr pwszVal;
        [FieldOffset(8)] public long longVal;

        public const ushort VT_EMPTY  = 0;
        public const ushort VT_LPWSTR = 31;

        public PropVariant() { vt = VT_EMPTY; }
        public PropVariant(string value)
        {
            vt = VT_LPWSTR;
            pwszVal = Marshal.StringToCoTaskMemUni(value ?? string.Empty);
        }

        public void Dispose()
        {
            if (vt == VT_LPWSTR && pwszVal != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(pwszVal);
                pwszVal = IntPtr.Zero;
            }
            vt = VT_EMPTY;
            GC.SuppressFinalize(this);
        }

        ~PropVariant() { Dispose(); }
    }

    public static class Native
    {
        // PKEY_AppUserModel_ID - System.AppUserModel.ID property identifier.
        // Verified against Microsoft Win32 Shell PROPERTYKEY docs.
        private static readonly Guid PKEY_AppUserModel_FMT =
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        private const uint PKEY_AppUserModel_PID = 5;

        public static void CreateShortcut(
            string shortcutPath,
            string targetPath,
            string arguments,
            string workingDirectory,
            string description,
            string iconPath,
            int iconIndex,
            string appUserModelId)
        {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            try
            {
                link.SetPath(targetPath);
                if (!string.IsNullOrEmpty(arguments))        link.SetArguments(arguments);
                if (!string.IsNullOrEmpty(workingDirectory)) link.SetWorkingDirectory(workingDirectory);
                if (!string.IsNullOrEmpty(description))      link.SetDescription(description);
                if (!string.IsNullOrEmpty(iconPath))         link.SetIconLocation(iconPath, iconIndex);

                if (!string.IsNullOrEmpty(appUserModelId))
                {
                    IPropertyStore store = (IPropertyStore)link;
                    PROPERTYKEY key = new PROPERTYKEY(PKEY_AppUserModel_FMT, PKEY_AppUserModel_PID);
                    using (PropVariant pv = new PropVariant(appUserModelId))
                    {
                        store.SetValue(ref key, pv);
                        store.Commit();
                    }
                }

                IPersistFile pf = (IPersistFile)link;
                pf.Save(shortcutPath, false);
            }
            finally
            {
                Marshal.ReleaseComObject(link);
            }
        }

        // Read the PE Subsystem field. Returns 2 (GUI), 3 (CUI), or 0 if not a valid PE.
        // The Subsystem field sits at PE_offset + 0x5C for BOTH PE32 (0x10B) and PE32+ (0x20B):
        // in PE32+, the BaseOfData field is removed but ImageBase grows from 4 to 8 bytes,
        // keeping the Subsystem offset identical. Verified against the Microsoft PE specification.
        public static ushort GetPESubsystem(string path)
        {
            try
            {
                using (var fs = File.OpenRead(path))
                using (var br = new BinaryReader(fs))
                {
                    if (fs.Length < 0x40) return 0;
                    if (br.ReadUInt16() != 0x5A4D) return 0;  // "MZ"
                    fs.Seek(0x3C, SeekOrigin.Begin);
                    uint peOffset = br.ReadUInt32();
                    if (peOffset == 0 || peOffset + 0x60 > fs.Length) return 0;
                    fs.Seek(peOffset, SeekOrigin.Begin);
                    if (br.ReadUInt32() != 0x00004550) return 0;  // "PE\0\0"
                    fs.Seek(peOffset + 0x5C, SeekOrigin.Begin);
                    return br.ReadUInt16();
                }
            }
            catch { return 0; }
        }

        // SetProcessDPIAware - tell Windows we'll render at the screen's native DPI
        // rather than getting bitmap-scaled (which causes blurry text on high-DPI displays).
        // Microsoft notes: must be called BEFORE any UI is created.
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDPIAware();

        // SHChangeNotify - the documented way to tell Explorer that file
        // associations / context menus have changed, without restarting it.
        // This is what every professional installer calls after writing
        // shell verbs to the registry. See:
        //   https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotify
        public const int SHCNE_ASSOCCHANGED = 0x08000000;
        public const uint SHCNF_IDLIST = 0x0000;
        public const uint SHCNF_FLUSH  = 0x1000;

        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

        public static void NotifyAssocChanged()
        {
            SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST | SHCNF_FLUSH, IntPtr.Zero, IntPtr.Zero);
        }

        // Force a window to the foreground despite Windows' background-app
        // foreground lockout. The trick: attach our input thread to the
        // currently-foreground window's thread, which transfers foreground
        // rights for the duration, then call SetForegroundWindow + ShowWindow.
        // This is the standard technique used by Inno Setup, NSIS, etc.
        // See: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow

        public const int SW_RESTORE = 9;
        public const int SW_SHOW = 5;

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool FlashWindow(IntPtr hWnd, bool bInvert);
        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        public static void ForceForeground(IntPtr hWnd)
        {
            if (hWnd == IntPtr.Zero) return;
            try
            {
                if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);

                uint thisThread = GetCurrentThreadId();
                IntPtr foreHwnd = GetForegroundWindow();
                uint forePid = 0;
                uint foreThread = (foreHwnd == IntPtr.Zero) ? 0 : GetWindowThreadProcessId(foreHwnd, out forePid);

                bool attached = false;
                if (foreThread != 0 && foreThread != thisThread)
                {
                    attached = AttachThreadInput(thisThread, foreThread, true);
                }
                try
                {
                    BringWindowToTop(hWnd);
                    SetForegroundWindow(hWnd);
                    ShowWindow(hWnd, SW_SHOW);
                }
                finally
                {
                    if (attached) AttachThreadInput(thisThread, foreThread, false);
                }

                // Belt-and-braces: flash the taskbar entry so the user notices.
                FlashWindow(hWnd, true);
            }
            catch { }
        }
    }
}
'@

    try {
        Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
    } catch {
        Write-Log "Failed to compile native helpers: $_" -Level Error
        throw "Could not initialize native helpers: $($_.Exception.Message)"
    }
}

function Initialize-DpiAwareness {
    # Idempotent - calling twice is harmless per Microsoft docs.
    try {
        Initialize-Native
        [void][WinRegister.Native]::SetProcessDPIAware()
    } catch {
        Write-Log "DPI awareness init failed (non-fatal): $_" -Level Warn
    }
}

#endregion

#region Classic context menu (Win11 top-level visibility) ---------------------
# Win11 hides registry-based shell verbs under "Show more options" by default.
# The documented per-user workaround is to neutralize the modern menu provider's
# CLSID under HKCU - then Explorer falls back to the classic full menu at the
# top level, with all our entries visible. This is what every "restore classic
# context menu" tweak does. Per-user only; reversible on Uninstall.

function Test-ClassicMenuEnabled {
    return Test-Path -LiteralPath $script:Cfg.ClassicMenuInprocKey
}

function Enable-ClassicContextMenu {
    # Returns $true if WE made the change, $false if it was already enabled
    # (e.g. user set it manually before installing us).
    if (Test-ClassicMenuEnabled) { return $false }
    New-Item -Path $script:Cfg.ClassicMenuInprocKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $script:Cfg.ClassicMenuInprocKey -Name '(Default)' -Value '' -Type String
    Write-Log "Enabled classic context menu (HKCU CLSID tweak)."
    return $true
}

function Disable-ClassicContextMenu {
    if (Test-Path -LiteralPath $script:Cfg.ClassicMenuClsidKey) {
        Remove-Item -LiteralPath $script:Cfg.ClassicMenuClsidKey -Recurse -Force
        Write-Log "Disabled classic context menu (HKCU CLSID tweak removed)."
    }
}

function Restart-WindowsExplorer {
    # Stop+respawn Explorer so context menu changes take effect immediately.
    # Modern Windows auto-respawns Explorer when its process exits; we add a
    # belt-and-braces Start-Process in case AutoRestartShell is disabled.
    try {
        $procs = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 1200
        }
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 600
        }
        Write-Log "Restarted Explorer.exe."
    } catch {
        Write-Log "Restart-WindowsExplorer failed (non-fatal): $_" -Level Warn
    }
}

#endregion

#region Validation & detection ------------------------------------------------

function Test-ProtectedPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    foreach ($protected in $script:Cfg.ProtectedPaths) {
        if ($full.StartsWith($protected, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-IsBlacklisted {
    # Built-in patterns plus any user-added entries from settings.
    param([string]$ExeBaseName, [string[]]$ExtraPatterns = @())
    $name = $ExeBaseName.ToLowerInvariant()
    foreach ($pat in $script:Cfg.BlacklistPatterns) {
        if ($name -like $pat) { return $true }
    }
    foreach ($pat in $ExtraPatterns) {
        if ($pat -and ($name -like $pat.ToLowerInvariant())) { return $true }
    }
    return $false
}

function Test-IsValidExecutable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.exe') { return $false }
    Initialize-Native
    $subsystem = [WinRegister.Native]::GetPESubsystem($Path)
    return $subsystem -ne 0
}

function Get-PESubsystem {
    param([string]$Path)
    Initialize-Native
    return [WinRegister.Native]::GetPESubsystem($Path)
}

function Get-ExecutableScore {
    param(
        [System.IO.FileInfo]$Exe,
        [string]$FolderPath
    )

    $score = 0
    $baseName = $Exe.BaseName.ToLowerInvariant()
    $folderName = (Split-Path $FolderPath -Leaf).ToLowerInvariant()

    if (Test-IsBlacklisted -ExeBaseName $baseName) { return -10000 }

    $subsystem = Get-PESubsystem -Path $Exe.FullName
    if ($subsystem -eq 0) { return -10000 }
    if ($subsystem -eq 2) { $score += 50 }   # GUI
    if ($subsystem -eq 3) { $score += 5 }    # console

    if ($baseName -eq $folderName) { $score += 40 }
    elseif ($baseName -like "$folderName*" -or $folderName -like "$baseName*") { $score += 20 }

    try {
        $info = $Exe.VersionInfo
        if ($info.ProductName -and $info.ProductName.Trim())          { $score += 20 }
        if ($info.FileDescription -and $info.FileDescription.Trim())  { $score += 10 }
        if ($info.CompanyName -and $info.CompanyName.Trim())          { $score += 5 }
    } catch { }

    $parent = Split-Path $Exe.FullName -Parent
    if ([System.IO.Path]::GetFullPath($parent) -eq [System.IO.Path]::GetFullPath($FolderPath)) {
        $score += 25
    } else {
        $rel = $Exe.FullName.Substring($FolderPath.Length).TrimStart('\')
        $depth = ($rel.Split('\') | Where-Object { $_ }).Count - 1
        $score -= ($depth * 5)
    }

    $score += [Math]::Min(15, [int]($Exe.Length / 1MB))

    return $score
}

function Find-PrimaryExecutable {
    param(
        [string]$FolderPath,
        [int]$MaxDepth = 4
    )

    Write-Log "Scanning folder for primary executable: $FolderPath (depth=$MaxDepth)"

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        throw "Folder not found: $FolderPath"
    }

    $folderFull = [System.IO.Path]::GetFullPath($FolderPath)
    $exes = @(Get-ChildItem -LiteralPath $folderFull -Filter *.exe -Recurse -Depth $MaxDepth -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer })

    if ($exes.Count -eq 0) {
        throw "No .exe files found in $FolderPath"
    }

    # Strong Electron signal: .exe sibling of resources\app.asar wins outright.
    $asar = Get-ChildItem -LiteralPath $folderFull -Filter 'app.asar' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($asar) {
        $electronDir = $asar.Directory.Parent.FullName
        $candidates = @($exes | Where-Object { (Split-Path $_.FullName -Parent) -ieq $electronDir })
        $best = $candidates |
            Where-Object { -not (Test-IsBlacklisted $_.BaseName) -and (Get-PESubsystem $_.FullName) -eq 2 } |
            Sort-Object -Property @{ Expression = { Get-ExecutableScore -Exe $_ -FolderPath $folderFull }; Descending = $true } |
            Select-Object -First 1
        if ($best) {
            Write-Log "Electron app detected; primary: $($best.FullName)"
            return $best.FullName
        }
    }

    $scored = $exes | ForEach-Object {
        [pscustomobject]@{
            Exe   = $_
            Score = Get-ExecutableScore -Exe $_ -FolderPath $folderFull
        }
    } | Sort-Object Score -Descending

    $top = $scored | Select-Object -First 1
    if (-not $top -or $top.Score -le 0) {
        throw "Could not identify a primary executable in $FolderPath. All candidates were filtered out or scored too low."
    }

    Write-Log "Primary executable selected: $($top.Exe.FullName) (score $($top.Score))"
    return $top.Exe.FullName
}

function Resolve-Target {
    param(
        [string]$Path,
        [int]$MaxFolderDepth = 4
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $ext = $item.Extension.ToLowerInvariant()

    if ($item.PSIsContainer) {
        return Find-PrimaryExecutable -FolderPath $item.FullName -MaxDepth $MaxFolderDepth
    }

    if ($ext -eq '.lnk') {
        $target = $null
        $shell = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $sc = $shell.CreateShortcut($item.FullName)
            $target = $sc.TargetPath
        } finally {
            if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        }
        # .lnk files can legitimately have an empty TargetPath (Control Panel
        # applets, shell namespaces like ::{GUID}). We can't register those.
        if (-not $target) {
            throw "This shortcut has no file target (it points to a shell namespace or Control Panel item, which can't be registered as a program)."
        }
        if (-not (Test-Path -LiteralPath $target)) {
            throw "Shortcut target is missing or unreachable: $target"
        }
        if ((Get-Item -LiteralPath $target).PSIsContainer) {
            return Find-PrimaryExecutable -FolderPath $target -MaxDepth $MaxFolderDepth
        }
        if ([System.IO.Path]::GetExtension($target).ToLowerInvariant() -eq '.lnk') {
            throw "Refusing to follow .lnk -> .lnk chain to avoid loops."
        }
        return $target
    }

    if ($ext -eq '.exe') {
        return $item.FullName
    }

    throw "Unsupported target type: $($item.FullName). Expected .exe, .lnk, or a folder."
}

function Get-CleanString {
    # Strip whitespace + control chars; collapse internal whitespace.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $cleaned = ($Text -replace '[\x00-\x1F\x7F]', ' ' -replace '\s+', ' ').Trim()
    return $cleaned
}

function Get-ProgramMetadata {
    param([string]$ExePath)

    $item = Get-Item -LiteralPath $ExePath
    $info = $item.VersionInfo

    $productName    = Get-CleanString $info.ProductName
    $fileDesc       = Get-CleanString $info.FileDescription
    $vendor         = Get-CleanString $info.CompanyName
    $productVersion = Get-CleanString $info.ProductVersion
    $fileVersion    = Get-CleanString $info.FileVersion

    $name = if ($productName) { $productName }
            elseif ($fileDesc) { $fileDesc }
            else { $item.BaseName }

    $version = if ($productVersion) { $productVersion }
               elseif ($fileVersion) { $fileVersion }
               else { '' }

    [pscustomobject]@{
        ExePath     = $item.FullName
        DisplayName = $name
        Vendor      = $vendor
        Version     = $version
        BaseName    = $item.BaseName
        WorkingDir  = $item.Directory.FullName
        FileSize    = $item.Length
    }
}

#endregion

#region Identifier helpers (AUMID per Microsoft spec) -------------------------

function ConvertTo-PascalCase {
    # Microsoft AppUserModelID spec: each segment must be PascalCased, no spaces,
    # <=128 chars total. We split on any non-alphanumeric character, capitalize
    # the first letter of each fragment, and concatenate.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'App' }
    $segs = $Text -split '[^a-zA-Z0-9]+' | Where-Object { $_ }
    if ($segs.Count -eq 0) { return 'App' }
    $pascal = ($segs | ForEach-Object {
        $first = $_.Substring(0, 1).ToUpperInvariant()
        if ($_.Length -gt 1) { $first + $_.Substring(1) } else { $first }
    }) -join ''
    if ($pascal.Length -gt $script:Cfg.MaxPascalSegment) {
        $pascal = $pascal.Substring(0, $script:Cfg.MaxPascalSegment)
    }
    return $pascal
}

function Get-PathHash {
    # Stable short hash of a path, used as the AUMID discriminator.
    param([string]$Path)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 10).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-AppId {
    # CompanyName.ProductName.SubProduct - per Microsoft AUMID format.
    # Hash acts as SubProduct so two installs of the same product at different
    # paths get distinct AUMIDs (Microsoft GitExtensions #12524 issue).
    param([string]$DisplayName, [string]$ExePath)
    $product = ConvertTo-PascalCase $DisplayName
    $hash = Get-PathHash $ExePath
    $aumid = "WinRegister.$product.$hash"
    if ($aumid.Length -gt $script:Cfg.MaxAumid) {
        # Truncate the product segment to fit
        $overflow = $aumid.Length - $script:Cfg.MaxAumid
        $product = $product.Substring(0, [Math]::Max(1, $product.Length - $overflow))
        $aumid = "WinRegister.$product.$hash"
    }
    if ($aumid -match '\s') {
        throw "AUMID generation produced a space (bug): $aumid"
    }
    return $aumid
}

function Get-SafeFilename {
    param([string]$Text, [string]$Fallback = 'App')
    $clean = ($Text -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $clean) { return $Fallback }
    if ($clean.Length -gt 100) { $clean = $clean.Substring(0, 100).TrimEnd() }
    return $clean
}

#endregion

#region Registration store ----------------------------------------------------

function Get-RegistrationStore {
    if (-not (Test-Path -LiteralPath $script:Cfg.RegistryFile)) {
        return [ordered]@{}
    }
    try {
        $raw = Get-Content -LiteralPath $script:Cfg.RegistryFile -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return [ordered]@{} }
        $obj = $raw | ConvertFrom-Json

        # Schema v2 wraps entries under a "Registrations" property and adds
        # "SchemaVersion". v1 had entries directly at the root.
        $schemaVersion = Get-SafeProperty $obj 'SchemaVersion' -Default 1
        $entries = if ($schemaVersion -ge 2) {
            Get-SafeProperty $obj 'Registrations' -Default $obj
        } else {
            $obj
        }

        $hash = [ordered]@{}
        if ($null -ne $entries) {
            foreach ($prop in $entries.PSObject.Properties) {
                $hash[$prop.Name] = $prop.Value
            }
        }
        return $hash
    } catch {
        Write-Log "Could not parse registration store; treating as empty: $_" -Level Warn
        return [ordered]@{}
    }
}

function Save-RegistrationStore {
    # Direct write (used only for full overwrites, e.g. purge to empty).
    # For incremental updates, prefer Edit-RegistrationStore.
    param([System.Collections.IDictionary]$Store)
    Initialize-DataFolder

    $payload = [ordered]@{
        SchemaVersion = $script:Cfg.SchemaVersion
        Generator     = "$($script:Cfg.AppName) $($script:Cfg.Version)"
        Updated       = (Get-Date).ToString('o')
        Registrations = $Store
    }
    $json = $payload | ConvertTo-Json -Depth 10

    $tmpFile = "$($script:Cfg.RegistryFile).tmp"
    Set-Content -LiteralPath $tmpFile -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmpFile -Destination $script:Cfg.RegistryFile -Force
}

function Edit-RegistrationStore {
    # Atomic read-modify-write with OS-level exclusive file lock. The lock is
    # held only for the few milliseconds it takes to read + apply the caller's
    # mutation + write - never during user interaction. This replaces the
    # earlier process-wide mutex, which could deadlock if a process was
    # stranded with an unanswered dialog.
    #
    # $Action receives a single argument: the live ordered hashtable. It may
    # add, modify, or remove keys.
    param([Parameter(Mandatory)] [scriptblock]$Action)

    Initialize-DataFolder
    $path = $script:Cfg.RegistryFile
    $maxAttempts = 100   # 10 seconds total at 100ms back-off

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open(
                $path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
            continue
        }

        try {
            # Read current content
            $store = [ordered]@{}
            if ($fs.Length -gt 0) {
                $buf = New-Object byte[] ([int]$fs.Length)
                [void]$fs.Read($buf, 0, $buf.Length)
                $raw = [System.Text.Encoding]::UTF8.GetString($buf)
                if ($raw.Trim()) {
                    try {
                        $obj = $raw | ConvertFrom-Json
                        $sv = Get-SafeProperty $obj 'SchemaVersion' -Default 1
                        $entries = if ($sv -ge 2) {
                            Get-SafeProperty $obj 'Registrations' -Default $obj
                        } else { $obj }
                        if ($null -ne $entries) {
                            foreach ($p in $entries.PSObject.Properties) {
                                $store[$p.Name] = $p.Value
                            }
                        }
                    } catch {
                        Write-Log "JSON parse failure under lock; treating as empty: $_" -Level Warn
                    }
                }
            }

            # Caller mutates
            & $Action $store

            # Serialize and write
            $payload = [ordered]@{
                SchemaVersion = $script:Cfg.SchemaVersion
                Generator     = "$($script:Cfg.AppName) $($script:Cfg.Version)"
                Updated       = (Get-Date).ToString('o')
                Registrations = $store
            }
            $newBytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10))

            $fs.SetLength($newBytes.Length)
            $fs.Position = 0
            $fs.Write($newBytes, 0, $newBytes.Length)
            $fs.Flush()
            return
        } finally {
            if ($fs) { $fs.Dispose() }
        }
    }
    throw "Could not acquire exclusive lock on $path after $maxAttempts attempts"
}

function Find-RegistrationByExe {
    param([string]$ExePath)
    try {
        $full = [System.IO.Path]::GetFullPath($ExePath)
    } catch {
        $full = $ExePath
    }
    $store = Get-RegistrationStore
    foreach ($key in $store.Keys) {
        $entry = $store[$key]
        $entryPath = Get-SafeProperty $entry 'ExePath'
        if ($entryPath -and ($entryPath -ieq $full)) {
            return [pscustomobject]@{ Id = $key; Entry = $entry }
        }
    }
    return $null
}

#endregion

#region Registration backend --------------------------------------------------

function New-StartMenuShortcut {
    param(
        [Parameter(Mandatory)] [string]$ShortcutPath,
        [Parameter(Mandatory)] [string]$TargetPath,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$AppUserModelId,
        [string]$Description,
        [string]$WorkingDirectory
    )

    Initialize-Native

    $parent = Split-Path $ShortcutPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [WinRegister.Native]::CreateShortcut(
        $ShortcutPath,
        $TargetPath,
        '',
        $WorkingDirectory,
        $Description,
        $TargetPath,
        0,
        $AppUserModelId
    )

    Write-Log "Created shortcut: $ShortcutPath -> $TargetPath (AUMID=$AppUserModelId)"
}

function Test-AppPathsCollision {
    # Returns $true if a different exe is already registered under this name.
    param(
        [Parameter(Mandatory)] [string]$KeyName,
        [Parameter(Mandatory)] [string]$ExePath
    )
    $keyPath = Join-Path $script:Cfg.AppPathsRoot $KeyName
    if (-not (Test-Path -LiteralPath $keyPath)) { return $false }
    try {
        $existing = (Get-ItemProperty -LiteralPath $keyPath -Name '(Default)' -ErrorAction Stop).'(default)'
        if (-not $existing) {
            $existing = (Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop).'(default)'
        }
    } catch { return $false }
    if (-not $existing) { return $false }
    return ($existing -ine $ExePath)
}

function Set-AppPathsEntry {
    # Per Microsoft App Paths docs: (Default) is the full path; Path is optional
    # and should be omitted unless the app needs extra DLL search dirs.
    param(
        [Parameter(Mandatory)] [string]$ExeBaseName,
        [Parameter(Mandatory)] [string]$ExePath
    )
    $keyName = if ($ExeBaseName -like '*.exe') { $ExeBaseName } else { "$ExeBaseName.exe" }

    if (Test-AppPathsCollision -KeyName $keyName -ExePath $ExePath) {
        Write-Log "App Paths key '$keyName' is already claimed by another exe; skipping to avoid clobber." -Level Warn
        return $null
    }

    $keyPath = Join-Path $script:Cfg.AppPathsRoot $keyName
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $keyPath -Name '(Default)' -Value $ExePath -Type String
    Write-Log "Set App Paths: $keyPath = $ExePath"
    return $keyName
}

function Remove-AppPathsEntry {
    param([string]$KeyName)
    if (-not $KeyName) { return }
    $keyPath = Join-Path $script:Cfg.AppPathsRoot $KeyName
    if (Test-Path -LiteralPath $keyPath) {
        Remove-Item -LiteralPath $keyPath -Recurse -Force
        Write-Log "Removed App Paths: $keyPath"
    }
}

function Get-DirectorySize {
    param([string]$Path)
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Sum Length).Sum
        return [int64]$sum
    } catch { return 0 }
}

function Set-UninstallEntry {
    # ARP (Apps & Features) entry. DisplayName must be <=32 chars per the
    # Microsoft Win32 MSI Uninstall registry reference, else the entry may be
    # hidden by the Settings UI.
    param(
        [Parameter(Mandatory)] [string]$AppId,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$ExePath,
        [string]$Vendor,
        [string]$Version,
        [int64]$InstallSize
    )

    $keyPath = Join-Path $script:Cfg.UninstallRoot $AppId
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }

    $arpName = if ($DisplayName.Length -gt $script:Cfg.MaxArpDisplayName) {
        $DisplayName.Substring(0, $script:Cfg.MaxArpDisplayName - 1).TrimEnd() + '...'
    } else {
        $DisplayName
    }

    $installLocation = Split-Path $ExePath -Parent
    $uninstallCmd = ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Unregister "{1}"' `
        -f $script:Cfg.InstalledScript, $ExePath)
    $quietCmd = $uninstallCmd + ' -Silent -NoConfirm'

    $estimatedKb = [int]([Math]::Max(0, $InstallSize) / 1KB)
    $installDate = (Get-Date).ToString('yyyyMMdd')

    Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayName'          -Value $arpName              -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayIcon'          -Value $ExePath              -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'InstallLocation'      -Value $installLocation      -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'UninstallString'      -Value $uninstallCmd         -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'QuietUninstallString' -Value $quietCmd             -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'Publisher'            -Value ([string]$Vendor)     -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayVersion'       -Value ([string]$Version)    -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'InstallDate'          -Value $installDate          -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'EstimatedSize'        -Value $estimatedKb          -Type DWord
    Set-ItemProperty -LiteralPath $keyPath -Name 'NoModify'             -Value 1                     -Type DWord
    Set-ItemProperty -LiteralPath $keyPath -Name 'NoRepair'             -Value 1                     -Type DWord
    Set-ItemProperty -LiteralPath $keyPath -Name 'WinRegisterManaged'   -Value 1                     -Type DWord

    Write-Log "Set Uninstall entry: $keyPath (size=${estimatedKb}KB)"
}

function Remove-UninstallEntry {
    param([string]$AppId)
    if (-not $AppId) { return }
    $keyPath = Join-Path $script:Cfg.UninstallRoot $AppId
    if (Test-Path -LiteralPath $keyPath) {
        Remove-Item -LiteralPath $keyPath -Recurse -Force
        Write-Log "Removed Uninstall entry: $keyPath"
    }
}

function Remove-ShortcutFile {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force
        Write-Log "Removed shortcut: $Path"
    }
}

#endregion

#region UI --------------------------------------------------------------------

function Show-ConfirmDialog {
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$ExePath,
        [string]$Vendor,
        [string]$Version
    )

    Initialize-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WinRegister'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.ClientSize = New-Object System.Drawing.Size(520, 290)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.TopMost = $true
    $form.ShowInTaskbar = $true

    try {
        $exeIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if ($exeIcon) {
            $form.Icon = $exeIcon
            $pic = New-Object System.Windows.Forms.PictureBox
            $pic.Image = $exeIcon.ToBitmap()
            $pic.SizeMode = 'Zoom'
            $pic.Location = New-Object System.Drawing.Point(20, 20)
            $pic.Size = New-Object System.Drawing.Size(48, 48)
            $form.Controls.Add($pic)
        }
    } catch { }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Register this program with Windows?'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(85, 22)
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'It will appear in Windows Search, the Start Menu, and Apps & Features.'
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
    $subtitle.AutoSize = $true
    $subtitle.MaximumSize = New-Object System.Drawing.Size(420, 0)
    $subtitle.Location = New-Object System.Drawing.Point(85, 47)
    $form.Controls.Add($subtitle)

    $nameLbl = New-Object System.Windows.Forms.Label
    $nameLbl.Text = 'Name'
    $nameLbl.AutoSize = $true
    $nameLbl.Location = New-Object System.Drawing.Point(20, 95)
    $form.Controls.Add($nameLbl)

    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Text = $DisplayName
    $nameBox.Location = New-Object System.Drawing.Point(85, 92)
    $nameBox.Size = New-Object System.Drawing.Size(415, 24)
    $nameBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $nameBox.MaxLength = 100
    $form.Controls.Add($nameBox)

    $pathLbl = New-Object System.Windows.Forms.Label
    $pathLbl.Text = 'Target'
    $pathLbl.AutoSize = $true
    $pathLbl.Location = New-Object System.Drawing.Point(20, 130)
    $form.Controls.Add($pathLbl)

    $pathVal = New-Object System.Windows.Forms.Label
    $pathVal.Text = $ExePath
    $pathVal.AutoSize = $false
    $pathVal.Size = New-Object System.Drawing.Size(415, 18)
    $pathVal.AutoEllipsis = $true
    $pathVal.ForeColor = [System.Drawing.Color]::FromArgb(64, 64, 64)
    $pathVal.Location = New-Object System.Drawing.Point(85, 130)
    $form.Controls.Add($pathVal)

    if ($Vendor) {
        $vLbl = New-Object System.Windows.Forms.Label
        $vLbl.Text = 'Vendor'
        $vLbl.AutoSize = $true
        $vLbl.Location = New-Object System.Drawing.Point(20, 155)
        $form.Controls.Add($vLbl)

        $vText = $Vendor
        if ($Version) { $vText = "$vText  v$Version" }
        $vVal = New-Object System.Windows.Forms.Label
        $vVal.Text = $vText
        $vVal.AutoSize = $true
        $vVal.ForeColor = [System.Drawing.Color]::FromArgb(64, 64, 64)
        $vVal.Location = New-Object System.Drawing.Point(85, 155)
        $form.Controls.Add($vVal)
    }

    $sep = New-Object System.Windows.Forms.Label
    $sep.BorderStyle = 'Fixed3D'
    $sep.AutoSize = $false
    $sep.Size = New-Object System.Drawing.Size(485, 2)
    $sep.Location = New-Object System.Drawing.Point(20, 195)
    $form.Controls.Add($sep)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'You can rename above before registering. Unregister later via the same right-click menu.'
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(20, 210)
    $form.Controls.Add($hint)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object System.Drawing.Size(100, 32)
    $cancel.Location = New-Object System.Drawing.Point(295, 240)
    $cancel.DialogResult = 'Cancel'
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Register'
    $ok.Size = New-Object System.Drawing.Size(100, 32)
    $ok.Location = New-Object System.Drawing.Point(400, 240)
    $ok.DialogResult = 'OK'
    $ok.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $ok.ForeColor = [System.Drawing.Color]::White
    $ok.FlatStyle = 'Flat'
    $ok.FlatAppearance.BorderSize = 0
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $form.Add_Shown({
        # Toggle TopMost to force Z-order re-evaluation
        $form.TopMost = $false
        $form.TopMost = $true
        $form.Activate()
        $form.BringToFront()
        # Win32 foreground-grab trick - needed when the process was spawned
        # from a background context (wscript -> powershell) and Windows has
        # revoked foreground rights.
        try { [WinRegister.Native]::ForceForeground($form.Handle) } catch { }
        $nameBox.Focus() | Out-Null
        $nameBox.SelectAll()
    })

    $result = $form.ShowDialog()
    $finalName = $nameBox.Text.Trim()
    $form.Dispose()

    if ($result -ne 'OK') { return $null }
    if (-not $finalName) { return $DisplayName }
    return $finalName
}

function Show-ToastMessage {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')] [string]$Level = 'Info'
    )
    if ($Silent -and $Level -eq 'Info') { return }

    Initialize-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.Size = New-Object System.Drawing.Size(370, 90)
    $form.BackColor = switch ($Level) {
        'Info'    { [System.Drawing.Color]::FromArgb(0, 120, 212) }
        'Warning' { [System.Drawing.Color]::FromArgb(202, 132, 0) }
        'Error'   { [System.Drawing.Color]::FromArgb(196, 43, 28) }
    }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($screen.Right - 390), ($screen.Bottom - 110))

    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Title
    $t.ForeColor = [System.Drawing.Color]::White
    $t.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $t.Location = New-Object System.Drawing.Point(15, 12)
    $t.AutoSize = $true
    $form.Controls.Add($t)

    $m = New-Object System.Windows.Forms.Label
    $m.Text = $Message
    $m.ForeColor = [System.Drawing.Color]::White
    $m.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $m.Location = New-Object System.Drawing.Point(15, 38)
    $m.Size = New-Object System.Drawing.Size(345, 45)
    $form.Controls.Add($m)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2500
    $timer.Add_Tick({ $form.Close(); $timer.Stop(); $timer.Dispose() })
    $form.Add_Shown({
        $form.TopMost = $false
        $form.TopMost = $true
        try { [WinRegister.Native]::ForceForeground($form.Handle) } catch { }
        $timer.Start()
    })
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

function Show-ErrorDialog {
    param([string]$Message)
    Initialize-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Message, 'WinRegister', 'OK', 'Error'
    ) | Out-Null
}

function Show-ConfirmYesNo {
    param([string]$Title, [string]$Message)
    Initialize-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message, $Title, 'YesNo', 'Warning', 'Button2'
    )
    return ($result -eq 'Yes')
}

function Show-SettingsDialog {
    Initialize-DpiAwareness
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $settings = Get-Settings

    # Single ToolTip provider serves every control on the form.
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 12000
    $tt.InitialDelay = 400
    $tt.ReshowDelay  = 250

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WinRegister Settings'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object System.Drawing.Size(620, 540)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.TopMost = $true
    try {
        $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon(
            [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\imageres.dll'))
    } catch { }

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(12, 12)
    $tabs.Size = New-Object System.Drawing.Size(596, 478)
    $form.Controls.Add($tabs)

    # ---------- General tab ----------
    $tabGeneral = New-Object System.Windows.Forms.TabPage
    $tabGeneral.Text = '  General  '
    $tabGeneral.BackColor = [System.Drawing.Color]::White
    $tabs.TabPages.Add($tabGeneral)

    function New-CheckBoxRow {
        param($Parent, $Text, $Checked, $X, $Y, $Tooltip)
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $Text
        $cb.AutoSize = $true
        $cb.Checked = [bool]$Checked
        $cb.Location = New-Object System.Drawing.Point($X, $Y)
        $cb.AccessibleName = $Text
        $Parent.Controls.Add($cb)
        if ($Tooltip) { $tt.SetToolTip($cb, $Tooltip) }
        return $cb
    }
    function New-Group {
        param($Parent, $Text, $X, $Y, $W, $H)
        $g = New-Object System.Windows.Forms.GroupBox
        $g.Text = $Text
        $g.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
        $g.Location = New-Object System.Drawing.Point($X, $Y)
        $g.Size = New-Object System.Drawing.Size($W, $H)
        $Parent.Controls.Add($g)
        return $g
    }

    $gbConfirm = New-Group -Parent $tabGeneral -Text 'Confirmation prompts' -X 16 -Y 14 -W 556 -H 80
    $cbAskReg   = New-CheckBoxRow -Parent $gbConfirm -Text 'Ask before registering a program'   -Checked $settings.Confirmation.AskOnRegister   -X 16 -Y 22 -Tooltip 'When on, a confirmation dialog appears each time you click Register so you can edit the display name before committing. Turn off for instant one-click registration.'
    $cbAskUnreg = New-CheckBoxRow -Parent $gbConfirm -Text 'Ask before unregistering a program' -Checked $settings.Confirmation.AskOnUnregister -X 16 -Y 48 -Tooltip 'When on, a yes/no confirmation appears before removing a registration. Recommended for safety - the underlying program is never deleted regardless.'

    $gbNotif = New-Group -Parent $tabGeneral -Text 'Notifications' -X 16 -Y 104 -W 556 -H 80
    $cbNotifReg   = New-CheckBoxRow -Parent $gbNotif -Text 'Show toast after successful register'   -Checked $settings.Notifications.ShowOnRegister   -X 16 -Y 22 -Tooltip 'Brief blue toast notification in the bottom-right corner confirming the program was added.'
    $cbNotifUnreg = New-CheckBoxRow -Parent $gbNotif -Text 'Show toast after successful unregister' -Checked $settings.Notifications.ShowOnUnregister -X 16 -Y 48 -Tooltip 'Brief blue toast notification confirming the program was removed.'

    $gbReg = New-Group -Parent $tabGeneral -Text 'Registration behavior' -X 16 -Y 194 -W 556 -H 158
    $cbAutoExe = New-CheckBoxRow -Parent $gbReg -Text 'Auto-detect primary executable when registering a folder' -Checked $settings.Registration.AutoDetectPrimaryExe -X 16 -Y 22 -Tooltip 'When right-clicking a folder, WinRegister scans for the main .exe (filters out installers, helpers, crash handlers) and registers it. If off, you must right-click the .exe directly.'

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = 'Start Menu subfolder:'
    $lblSub.AutoSize = $true
    $lblSub.Location = New-Object System.Drawing.Point(16, 54)
    $gbReg.Controls.Add($lblSub)
    $tt.SetToolTip($lblSub, "Optional: nests registered shortcuts under a subfolder of Start Menu Programs (e.g. 'Portable Apps'). Empty = top-level.")

    $txtSub = New-Object System.Windows.Forms.TextBox
    $txtSub.Text = [string](Get-SafeProperty $settings.Registration 'StartMenuSubfolder' -Default '')
    $txtSub.Location = New-Object System.Drawing.Point(170, 51)
    $txtSub.Size = New-Object System.Drawing.Size(250, 24)
    $txtSub.MaxLength = 60
    $gbReg.Controls.Add($txtSub)
    $tt.SetToolTip($txtSub, "Example: 'Portable Apps' makes shortcuts appear under Start Menu -> Portable Apps -> <name>.")

    $lblDepth = New-Object System.Windows.Forms.Label
    $lblDepth.Text = 'Folder scan depth:'
    $lblDepth.AutoSize = $true
    $lblDepth.Location = New-Object System.Drawing.Point(16, 86)
    $gbReg.Controls.Add($lblDepth)

    $numDepth = New-Object System.Windows.Forms.NumericUpDown
    $numDepth.Minimum = 1; $numDepth.Maximum = 10
    $numDepth.Value = [int](Get-SafeProperty $settings.Registration 'FolderScanDepth' -Default 4)
    $numDepth.Location = New-Object System.Drawing.Point(170, 83)
    $numDepth.Size = New-Object System.Drawing.Size(60, 24)
    $gbReg.Controls.Add($numDepth)
    $tt.SetToolTip($numDepth, "How many subdirectory levels to scan for the main .exe. 4 covers nearly every app.")

    $lblBL = New-Object System.Windows.Forms.Label
    $lblBL.Text = 'Custom blacklist:'
    $lblBL.AutoSize = $true
    $lblBL.Location = New-Object System.Drawing.Point(16, 118)
    $gbReg.Controls.Add($lblBL)
    $tt.SetToolTip($lblBL, "Comma-separated glob patterns of .exe basenames to refuse, in addition to the built-in installer/helper filters. Example: 'launcher,*-tray,oldtool*'.")

    $existingBL = @(Get-SafeProperty $settings.Registration 'ExtraBlacklist' -Default @())
    $txtBL = New-Object System.Windows.Forms.TextBox
    $txtBL.Text = ($existingBL -join ', ')
    $txtBL.Location = New-Object System.Drawing.Point(170, 115)
    $txtBL.Size = New-Object System.Drawing.Size(360, 24)
    $gbReg.Controls.Add($txtBL)

    $gbActions = New-Group -Parent $tabGeneral -Text 'Actions' -X 16 -Y 362 -W 556 -H 76
    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = 'Clear all registered programs...'
    $btnClear.Size = New-Object System.Drawing.Size(220, 30)
    $btnClear.Location = New-Object System.Drawing.Point(16, 28)
    $gbActions.Controls.Add($btnClear)
    $tt.SetToolTip($btnClear, "Removes every program WinRegister has registered. The executables themselves are not deleted. A backup of registrations.json is saved first.")

    # See trailing handlers below - they reference these variables
    $btnLog = New-Object System.Windows.Forms.Button
    $btnLog.Text = 'Open data folder'
    $btnLog.Size = New-Object System.Drawing.Size(140, 30)
    $btnLog.Location = New-Object System.Drawing.Point(248, 28)
    $btnLog.Add_Click({ try { Start-Process explorer.exe $script:Cfg.DataFolder } catch { } })
    $gbActions.Controls.Add($btnLog)
    $tt.SetToolTip($btnLog, "Opens %LOCALAPPDATA%\WinRegister - contains the log, registration database, and backups.")

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = 'Reset settings'
    $btnReset.Size = New-Object System.Drawing.Size(140, 30)
    $btnReset.Location = New-Object System.Drawing.Point(398, 28)
    $gbActions.Controls.Add($btnReset)
    $tt.SetToolTip($btnReset, "Reverts every preference to its default. Registered programs are not affected. A backup of settings.json is saved first.")

    # Wire the Clear-all button handler (defined above)
    $btnClear.Add_Click({
        $count = (Get-RegistrationStore).Count
        if ($count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Nothing to clear - no programs are registered.", 'WinRegister', 'OK', 'Information') | Out-Null
            return
        }
        $ok = Show-ConfirmYesNo -Title 'Clear all registrations' -Message "This will unregister all $count programs you've added with WinRegister. The programs themselves will NOT be deleted - only their entries from Windows Search, Start Menu, and Apps & Features.`n`n(A backup of registrations.json is saved under %LOCALAPPDATA%\WinRegister\.)`n`nContinue?"
        if ($ok) {
            Invoke-PurgeAllRegistrations
            [System.Windows.Forms.MessageBox]::Show("Cleared $count registrations.", 'WinRegister', 'OK', 'Information') | Out-Null
        }
    })

    $btnReset.Add_Click({
        $ok = Show-ConfirmYesNo -Title 'Reset settings' -Message 'Reset all WinRegister preferences to defaults? Your registered programs are NOT affected. A backup of settings.json is saved first.'
        if ($ok) {
            Reset-Settings
            $form.DialogResult = 'Retry'; $form.Close()
        }
    })

    # ---------- Updates tab ----------
    $tabUpdates = New-Object System.Windows.Forms.TabPage
    $tabUpdates.Text = '  Updates  '
    $tabUpdates.BackColor = [System.Drawing.Color]::White
    $tabs.TabPages.Add($tabUpdates)

    $gbU = New-Group -Parent $tabUpdates -Text 'Automatic update checks' -X 16 -Y 14 -W 556 -H 240
    $cbUpdates = New-CheckBoxRow -Parent $gbU -Text 'Check for updates on startup' -Checked $settings.Updates.CheckEnabled -X 16 -Y 22 -Tooltip "Each time you run a Register, Unregister, or Settings action, WinRegister will at most once per N days hit the GitHub Releases API to see if a newer version exists. Silent unless an update is found."

    $lblFreq = New-Object System.Windows.Forms.Label
    $lblFreq.Text = 'Check at most every:'
    $lblFreq.AutoSize = $true
    $lblFreq.Location = New-Object System.Drawing.Point(16, 56)
    $gbU.Controls.Add($lblFreq)

    $numFreq = New-Object System.Windows.Forms.NumericUpDown
    $numFreq.Minimum = 1; $numFreq.Maximum = 90
    $numFreq.Value = [int]$settings.Updates.CheckFrequencyDays
    $numFreq.Location = New-Object System.Drawing.Point(160, 53)
    $numFreq.Size = New-Object System.Drawing.Size(60, 24)
    $gbU.Controls.Add($numFreq)
    $tt.SetToolTip($numFreq, "Minimum days between automatic checks. The 'Check now' button always runs immediately.")

    $lblFreqUnit = New-Object System.Windows.Forms.Label
    $lblFreqUnit.Text = 'days'
    $lblFreqUnit.AutoSize = $true
    $lblFreqUnit.Location = New-Object System.Drawing.Point(228, 56)
    $gbU.Controls.Add($lblFreqUnit)

    $lblCurrent = New-Object System.Windows.Forms.Label
    $lblCurrent.Text = "Installed version: $($script:Cfg.Version)"
    $lblCurrent.AutoSize = $true
    $lblCurrent.Location = New-Object System.Drawing.Point(16, 96)
    $gbU.Controls.Add($lblCurrent)

    $lblLast = New-Object System.Windows.Forms.Label
    $lastTxt = if ($settings.Updates.LastCheckedAt -and $settings.Updates.LastCheckedAt -ne '1970-01-01T00:00:00Z') {
        try { ([DateTime]::Parse($settings.Updates.LastCheckedAt)).ToString('yyyy-MM-dd HH:mm') } catch { 'never' }
    } else { 'never' }
    $lblLast.Text = "Last checked: $lastTxt"
    $lblLast.AutoSize = $true
    $lblLast.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
    $lblLast.Location = New-Object System.Drawing.Point(16, 120)
    $gbU.Controls.Add($lblLast)

    $btnCheckNow = New-Object System.Windows.Forms.Button
    $btnCheckNow.Text = 'Check for updates now'
    $btnCheckNow.Size = New-Object System.Drawing.Size(200, 30)
    $btnCheckNow.Location = New-Object System.Drawing.Point(16, 156)
    $gbU.Controls.Add($btnCheckNow)
    $tt.SetToolTip($btnCheckNow, "Force a check right now, regardless of the frequency setting.")

    $btnCheckNow.Add_Click({
        $btnCheckNow.Enabled = $false
        $btnCheckNow.Text = 'Checking...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $result = Test-UpdateAvailable -Settings $settings -Force
            switch ("$($result.Status)") {
                'UpdateAvailable' { Show-UpdateNotification -Update $result -Settings $settings }
                'UpToDate'        { [System.Windows.Forms.MessageBox]::Show("You're on the latest version ($($script:Cfg.Version)).", 'WinRegister', 'OK', 'Information') | Out-Null }
                default {
                    $msg = if ($result -and $result.ErrorMessage) {
                        "Could not contact the update server:`n`n$($result.ErrorMessage)"
                    } else { "Could not contact the update server." }
                    [System.Windows.Forms.MessageBox]::Show($msg, 'WinRegister', 'OK', 'Warning') | Out-Null
                }
            }
            try {
                $reloaded = Get-Settings
                $lblLast.Text = "Last checked: $(([DateTime]::Parse($reloaded.Updates.LastCheckedAt)).ToString('yyyy-MM-dd HH:mm'))"
            } catch { }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Update check failed: $($_.Exception.Message)", 'WinRegister', 'OK', 'Warning') | Out-Null
        } finally {
            $btnCheckNow.Enabled = $true
            $btnCheckNow.Text = 'Check for updates now'
        }
    })

    if ($settings.Updates.SkippedVersion) {
        $lblSkipped = New-Object System.Windows.Forms.Label
        $lblSkipped.Text = "Skipped version: $($settings.Updates.SkippedVersion)"
        $lblSkipped.AutoSize = $true
        $lblSkipped.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
        $lblSkipped.Location = New-Object System.Drawing.Point(230, 162)
        $gbU.Controls.Add($lblSkipped)

        $btnUnskip = New-Object System.Windows.Forms.Button
        $btnUnskip.Text = 'Clear'
        $btnUnskip.Size = New-Object System.Drawing.Size(70, 24)
        $btnUnskip.Location = New-Object System.Drawing.Point(380, 158)
        $gbU.Controls.Add($btnUnskip)
        $tt.SetToolTip($btnUnskip, "Clear the 'skip this version' flag so update prompts come back.")

        $btnUnskip.Add_Click({
            $settings.Updates.SkippedVersion = ''
            Save-Settings -Settings $settings
            $btnUnskip.Visible = $false; $lblSkipped.Visible = $false
        })
    }

    # ---------- Registrations tab ----------
    $tabRegs = New-Object System.Windows.Forms.TabPage
    $tabRegs.Text = '  Registrations  '
    $tabRegs.BackColor = [System.Drawing.Color]::White
    $tabs.TabPages.Add($tabRegs)

    $lvRegs = New-Object System.Windows.Forms.ListView
    $lvRegs.Location = New-Object System.Drawing.Point(16, 14)
    $lvRegs.Size = New-Object System.Drawing.Size(556, 380)
    $lvRegs.View = 'Details'
    $lvRegs.FullRowSelect = $true
    $lvRegs.GridLines = $true
    $lvRegs.MultiSelect = $false
    [void]$lvRegs.Columns.Add('Name', 180)
    [void]$lvRegs.Columns.Add('Vendor', 110)
    [void]$lvRegs.Columns.Add('Version', 80)
    [void]$lvRegs.Columns.Add('Status', 70)
    [void]$lvRegs.Columns.Add('Path', 700)
    $tabRegs.Controls.Add($lvRegs)
    $tt.SetToolTip($lvRegs, "Programs WinRegister has registered. Select one and click Unregister, or double-click the row to open its containing folder.")

    function Refresh-RegList {
        $lvRegs.BeginUpdate()
        $lvRegs.Items.Clear()
        $store = Get-RegistrationStore
        foreach ($k in $store.Keys) {
            $e = $store[$k]
            $name   = Get-SafeProperty $e 'DisplayName' -Default '(unnamed)'
            $path   = Get-SafeProperty $e 'ExePath' -Default '?'
            $vendor = Get-SafeProperty $e 'Vendor' -Default ''
            $ver    = Get-SafeProperty $e 'Version' -Default ''
            $alive  = if ($path -ne '?' -and (Test-Path -LiteralPath $path)) { 'OK' } else { 'MISSING' }
            $row = New-Object System.Windows.Forms.ListViewItem $name
            [void]$row.SubItems.Add($vendor)
            [void]$row.SubItems.Add($ver)
            [void]$row.SubItems.Add($alive)
            [void]$row.SubItems.Add($path)
            $row.Tag = $path
            if ($alive -eq 'MISSING') { $row.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0) }
            [void]$lvRegs.Items.Add($row)
        }
        $lvRegs.EndUpdate()
    }
    Refresh-RegList

    $lvRegs.Add_DoubleClick({
        if ($lvRegs.SelectedItems.Count -gt 0) {
            $p = "$($lvRegs.SelectedItems[0].Tag)"
            if ($p -and (Test-Path -LiteralPath $p)) {
                try { Start-Process explorer.exe ("/select,`"$p`"") } catch { }
            }
        }
    })

    $btnUnreg = New-Object System.Windows.Forms.Button
    $btnUnreg.Text = 'Unregister selected'
    $btnUnreg.Size = New-Object System.Drawing.Size(160, 28)
    $btnUnreg.Location = New-Object System.Drawing.Point(16, 404)
    $tabRegs.Controls.Add($btnUnreg)
    $tt.SetToolTip($btnUnreg, "Removes the selected program's registration. The executable itself stays put.")
    $btnUnreg.Add_Click({
        if ($lvRegs.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select a program first.', 'WinRegister', 'OK', 'Information') | Out-Null
            return
        }
        $p = "$($lvRegs.SelectedItems[0].Tag)"
        $name = "$($lvRegs.SelectedItems[0].Text)"
        if (Show-ConfirmYesNo -Title 'Unregister' -Message "Unregister '$name'?") {
            Invoke-Unregister -InputPath $p -SkipConfirm
            Refresh-RegList
        }
    })

    $btnRepair = New-Object System.Windows.Forms.Button
    $btnRepair.Text = 'Repair (clean dead entries)'
    $btnRepair.Size = New-Object System.Drawing.Size(190, 28)
    $btnRepair.Location = New-Object System.Drawing.Point(186, 404)
    $tabRegs.Controls.Add($btnRepair)
    $tt.SetToolTip($btnRepair, "Removes entries whose target exe no longer exists, and recreates missing Start Menu shortcuts for live entries.")
    $btnRepair.Add_Click({ Invoke-Repair; Refresh-RegList })

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = 'Refresh'
    $btnRefresh.Size = New-Object System.Drawing.Size(80, 28)
    $btnRefresh.Location = New-Object System.Drawing.Point(492, 404)
    $tabRegs.Controls.Add($btnRefresh)
    $btnRefresh.Add_Click({ Refresh-RegList })

    # ---------- About tab ----------
    $tabAbout = New-Object System.Windows.Forms.TabPage
    $tabAbout.Text = '  About  '
    $tabAbout.BackColor = [System.Drawing.Color]::White
    $tabs.TabPages.Add($tabAbout)

    $aboutTitle = New-Object System.Windows.Forms.Label
    $aboutTitle.Text = "WinRegister $($script:Cfg.Version)"
    $aboutTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $aboutTitle.AutoSize = $true
    $aboutTitle.Location = New-Object System.Drawing.Point(20, 25)
    $tabAbout.Controls.Add($aboutTitle)

    $aboutDesc = New-Object System.Windows.Forms.Label
    $aboutDesc.Text = "Register portable programs with Windows Search, Start Menu, the Run dialog,`r`nand Apps & Features. Per-user, no admin required."
    $aboutDesc.AutoSize = $true
    $aboutDesc.ForeColor = [System.Drawing.Color]::FromArgb(64, 64, 64)
    $aboutDesc.Location = New-Object System.Drawing.Point(20, 65)
    $tabAbout.Controls.Add($aboutDesc)

    $aboutLink = New-Object System.Windows.Forms.LinkLabel
    $aboutLink.Text = $script:Cfg.HomepageUrl
    $aboutLink.AutoSize = $true
    $aboutLink.Location = New-Object System.Drawing.Point(20, 120)
    $aboutLink.Add_LinkClicked({ try { Start-Process $script:Cfg.HomepageUrl } catch { } })
    $tabAbout.Controls.Add($aboutLink)

    $aboutPub = New-Object System.Windows.Forms.Label
    $aboutPub.Text = "Publisher: $($script:Cfg.Publisher)        License: MIT"
    $aboutPub.AutoSize = $true
    $aboutPub.Location = New-Object System.Drawing.Point(20, 150)
    $tabAbout.Controls.Add($aboutPub)

    $gbPaths = New-Group -Parent $tabAbout -Text 'File locations' -X 16 -Y 190 -W 556 -H 200
    foreach ($row in @(
        @{ Label = 'Settings'; Path = $script:Cfg.SettingsFile; CanOpen = $true; Y = 25 }
        @{ Label = 'Log file'; Path = $script:Cfg.LogFile;      CanOpen = $true; Y = 57 }
        @{ Label = 'Database'; Path = $script:Cfg.RegistryFile; CanOpen = $false; Y = 89 }
        @{ Label = 'Script';   Path = $script:Cfg.InstalledScript; CanOpen = $false; Y = 121 }
        @{ Label = 'Data dir'; Path = $script:Cfg.DataFolder;   CanOpen = $true; Y = 153 }
    )) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $row.Label + ':'
        $lbl.AutoSize = $true
        $lbl.Location = New-Object System.Drawing.Point(16, ($row.Y + 3))
        $gbPaths.Controls.Add($lbl)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = $row.Path
        $tb.ReadOnly = $true
        $tb.Location = New-Object System.Drawing.Point(85, $row.Y)
        $tb.Size = New-Object System.Drawing.Size(360, 24)
        $tb.BackColor = [System.Drawing.Color]::White
        $gbPaths.Controls.Add($tb)

        if ($row.CanOpen) {
            $tgt = $row.Path
            $btn = New-Object System.Windows.Forms.Button
            $btn.Text = 'Open'
            $btn.Size = New-Object System.Drawing.Size(70, 24)
            $btn.Location = New-Object System.Drawing.Point(452, ($row.Y - 1))
            $btn.Tag = $tgt
            $btn.Add_Click({
                $p = "$($this.Tag)"
                if (-not (Test-Path -LiteralPath $p)) { return }
                try {
                    $item = Get-Item -LiteralPath $p
                    if ($item.PSIsContainer) { Start-Process explorer.exe $p }
                    else                     { Start-Process notepad.exe $p }
                } catch { }
            })
            $gbPaths.Controls.Add($btn)
        }
    }

    # ---------- Footer ----------
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '&Cancel'
    $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
    $btnCancel.Location = New-Object System.Drawing.Point(400, 500)
    $btnCancel.DialogResult = 'Cancel'
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel
    $tt.SetToolTip($btnCancel, "Close without saving changes.")

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '&Save'
    $btnSave.Size = New-Object System.Drawing.Size(100, 32)
    $btnSave.Location = New-Object System.Drawing.Point(508, 500)
    $btnSave.DialogResult = 'OK'
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'; $btnSave.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnSave)
    $form.AcceptButton = $btnSave
    $tt.SetToolTip($btnSave, "Save preferences and close.")

    $form.Add_Shown({
        $form.TopMost = $false; $form.TopMost = $true
        try { [WinRegister.Native]::ForceForeground($form.Handle) } catch { }
    })

    $result = $form.ShowDialog()
    if ($result -eq 'OK') {
        $settings.Confirmation.AskOnRegister         = $cbAskReg.Checked
        $settings.Confirmation.AskOnUnregister       = $cbAskUnreg.Checked
        $settings.Notifications.ShowOnRegister       = $cbNotifReg.Checked
        $settings.Notifications.ShowOnUnregister     = $cbNotifUnreg.Checked
        $settings.Registration.AutoDetectPrimaryExe  = $cbAutoExe.Checked
        $settings.Registration.StartMenuSubfolder    = $txtSub.Text.Trim()
        $settings.Registration.FolderScanDepth       = [int]$numDepth.Value
        $settings.Registration.ExtraBlacklist        = @(($txtBL.Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $settings.Updates.CheckEnabled               = $cbUpdates.Checked
        $settings.Updates.CheckFrequencyDays         = [int]$numFreq.Value
        Save-Settings -Settings $settings
    }
    $form.Dispose()
    if ($result -eq 'Retry') {
        Show-SettingsDialog
    }
}


function Invoke-PurgeAllRegistrations {
    # Used by the "Clear all" button in Settings. Snapshots the current
    # registrations.json before mutation so the user can roll back via the
    # .bak file under %LOCALAPPDATA%\WinRegister if they hit this by mistake.
    Backup-File -Path $script:Cfg.RegistryFile -Tag 'purge' | Out-Null

    $store = Get-RegistrationStore
    foreach ($key in @($store.Keys)) {
        $entry = $store[$key]
        try {
            Remove-ShortcutFile -Path (Get-SafeProperty $entry 'ShortcutPath')
            Remove-AppPathsEntry -KeyName (Get-SafeProperty $entry 'AppPathsKey')
            Remove-UninstallEntry -AppId  (Get-SafeProperty $entry 'AppId')
        } catch {
            Write-Log "Purge cleanup warning: $_" -Level Warn
        }
    }
    Edit-RegistrationStore {
        param($store)
        @($store.Keys) | ForEach-Object { $store.Remove($_) }
    }
    Write-Log "Purged all registrations via Settings UI."
}

#endregion

#region Top-level actions -----------------------------------------------------

function Invoke-Register {
    param(
        [Parameter(Mandatory)] [string]$InputPath,
        [string]$OverrideName,
        [switch]$SkipConfirm
    )

    Write-Log "===== Register requested: $InputPath ====="

    $settings = Get-Settings
    $extraBlacklist = @(Get-SafeProperty $settings.Registration 'ExtraBlacklist' -Default @())
    $folderDepth    = [int](Get-SafeProperty $settings.Registration 'FolderScanDepth' -Default 4)
    if ($folderDepth -lt 1) { $folderDepth = 4 }

    try {
        $exePath = $null
        try {
            $exePath = Resolve-Target -Path $InputPath -MaxFolderDepth $folderDepth
        } catch {
            Show-ErrorDialog "Could not identify a program to register.`n`n$($_.Exception.Message)"
            Write-Log "Resolve-Target failed: $_" -Level Error
            return
        }

        if (Test-ProtectedPath -Path $exePath) {
            Show-ErrorDialog "Refusing to register a file in a protected Windows system folder:`n$exePath"
            Write-Log "Refused protected path: $exePath" -Level Warn
            return
        }

        if (-not (Test-IsValidExecutable -Path $exePath)) {
            Show-ErrorDialog "Not a valid Windows executable:`n$exePath"
            Write-Log "Invalid PE: $exePath" -Level Warn
            return
        }

        $base = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
        if (Test-IsBlacklisted -ExeBaseName $base -ExtraPatterns $extraBlacklist) {
            Show-ErrorDialog "This file looks like an installer, uninstaller, or helper binary and won't be registered:`n$exePath`n`nYou can add or remove patterns under Settings > Registration > Custom blacklist."
            Write-Log "Blacklisted: $exePath" -Level Warn
            return
        }

        $meta = Get-ProgramMetadata -ExePath $exePath

        # Existing registration found: preserve the user's prior DisplayName
        # unless they explicitly provided a new override.
        $existing = Find-RegistrationByExe -ExePath $meta.ExePath
        if ($existing -and -not $OverrideName) {
            $priorName = Get-SafeProperty $existing.Entry 'DisplayName'
            if ($priorName) {
                $meta.DisplayName = $priorName
                Write-Log "Preserving prior display name: $priorName"
            }
        }
        if ($OverrideName) { $meta.DisplayName = $OverrideName }

        $shouldConfirm = -not $SkipConfirm -and $settings.Confirmation.AskOnRegister
        if ($shouldConfirm) {
            $confirmed = Show-ConfirmDialog `
                -DisplayName $meta.DisplayName `
                -ExePath $meta.ExePath `
                -Vendor $meta.Vendor `
                -Version $meta.Version
            if (-not $confirmed) {
                Write-Log "User cancelled registration."
                return
            }
            $meta.DisplayName = $confirmed
        }

        # Roll up the prior registration if present.
        if ($existing) {
            Write-Log "Updating existing registration: $($existing.Id)"
            try {
                Remove-ShortcutFile -Path (Get-SafeProperty $existing.Entry 'ShortcutPath')
                Remove-AppPathsEntry -KeyName (Get-SafeProperty $existing.Entry 'AppPathsKey')
                Remove-UninstallEntry -AppId   (Get-SafeProperty $existing.Entry 'AppId')
            } catch {
                Write-Log "Cleanup of prior registration warning: $_" -Level Warn
            }
        }

        $appId = New-AppId -DisplayName $meta.DisplayName -ExePath $meta.ExePath
        $shortcutFileName = Get-SafeFilename -Text $meta.DisplayName -Fallback $meta.BaseName

        # Optional custom Start Menu subfolder ("WinRegister", "Portable Apps", etc.)
        $subfolder = Get-SafeProperty $settings.Registration 'StartMenuSubfolder' -Default ''
        $startMenuDir = if ($subfolder) {
            $safeSub = Get-SafeFilename -Text $subfolder -Fallback 'Apps'
            $dir = Join-Path $script:Cfg.StartMenuFolder $safeSub
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $dir
        } else {
            $script:Cfg.StartMenuFolder
        }
        $shortcutPath = Join-Path $startMenuDir "$shortcutFileName.lnk"

        if ((Test-Path -LiteralPath $shortcutPath) -and -not $existing) {
            $shortcutPath = Join-Path $startMenuDir "$shortcutFileName ($($meta.BaseName)).lnk"
        }

        # Critical step: shortcut. Fail hard if this fails.
        try {
            New-StartMenuShortcut `
                -ShortcutPath $shortcutPath `
                -TargetPath $meta.ExePath `
                -DisplayName $meta.DisplayName `
                -AppUserModelId $appId `
                -Description $meta.DisplayName `
                -WorkingDirectory $meta.WorkingDir
        } catch {
            Show-ErrorDialog "Failed to create Start Menu shortcut:`n$($_.Exception.Message)"
            Write-Log "Shortcut creation failed: $_" -Level Error
            return
        }

        # Non-critical: App Paths (Run dialog) — silent on collision.
        $appPathsKey = $null
        try {
            $appPathsKey = Set-AppPathsEntry -ExeBaseName $meta.BaseName -ExePath $meta.ExePath
        } catch {
            Write-Log "App Paths entry failed (non-fatal): $_" -Level Warn
        }

        # Non-critical: ARP entry.
        $installSize = 0
        try { $installSize = Get-DirectorySize -Path $meta.WorkingDir } catch { }
        try {
            Set-UninstallEntry `
                -AppId $appId `
                -DisplayName $meta.DisplayName `
                -ExePath $meta.ExePath `
                -Vendor $meta.Vendor `
                -Version $meta.Version `
                -InstallSize $installSize
        } catch {
            Write-Log "Uninstall entry failed (non-fatal): $_" -Level Warn
        }

        $newEntry = [pscustomobject]@{
            AppId        = $appId
            DisplayName  = $meta.DisplayName
            ExePath      = $meta.ExePath
            ShortcutPath = $shortcutPath
            AppPathsKey  = $appPathsKey
            Vendor       = $meta.Vendor
            Version      = $meta.Version
            InstallSize  = $installSize
            RegisteredAt = (Get-Date).ToString('o')
        }
        Edit-RegistrationStore {
            param($store)
            $store[$appId] = $newEntry
        }.GetNewClosure()

        Write-Log "Registered: $($meta.DisplayName) ($appId)"
        if ($settings.Notifications.ShowOnRegister) {
            Show-ToastMessage -Title 'Registered' -Message "$($meta.DisplayName) is now in Windows Search." -Level Info
        }
    }
    catch {
        Write-Log "Register top-level: $_" -Level Error
        Show-ErrorDialog "WinRegister failed:`n$($_.Exception.Message)"
    }
}

function Invoke-Unregister {
    param(
        [Parameter(Mandatory)] [string]$InputPath,
        [switch]$SkipConfirm
    )

    Write-Log "===== Unregister requested: $InputPath ====="

    $settings = Get-Settings

    try {
        $exePath = $null
        try { $exePath = Resolve-Target -Path $InputPath } catch { $exePath = $InputPath }

        $found = Find-RegistrationByExe -ExePath $exePath
        if (-not $found) {
            $found = Find-RegistrationByExe -ExePath $InputPath
        }

        if (-not $found) {
            Show-ErrorDialog "This item is not registered by WinRegister:`n$InputPath"
            Write-Log "Not found in registry: $InputPath" -Level Warn
            return
        }

        $entry = $found.Entry
        $displayName = Get-SafeProperty $entry 'DisplayName' -Default '(unnamed)'
        $foundId = $found.Id

        if (-not $SkipConfirm -and $settings.Confirmation.AskOnUnregister) {
            $ok = Show-ConfirmYesNo -Title 'Unregister' -Message "Unregister '$displayName' from Windows Search?"
            if (-not $ok) {
                Write-Log "User cancelled unregistration."
                return
            }
        }

        Remove-ShortcutFile -Path (Get-SafeProperty $entry 'ShortcutPath')
        Remove-AppPathsEntry -KeyName (Get-SafeProperty $entry 'AppPathsKey')
        Remove-UninstallEntry -AppId   (Get-SafeProperty $entry 'AppId')

        Edit-RegistrationStore {
            param($store)
            $store.Remove($foundId)
        }.GetNewClosure()

        Write-Log "Unregistered: $displayName"
        if ($settings.Notifications.ShowOnUnregister) {
            Show-ToastMessage -Title 'Unregistered' -Message "$displayName was removed from Windows Search." -Level Info
        }
    }
    catch {
        Write-Log "Unregister top-level: $_" -Level Error
        Show-ErrorDialog "WinRegister failed:`n$($_.Exception.Message)"
    }
}

function Show-RegistrationList {
    $store = Get-RegistrationStore
    if ($store.Count -eq 0) {
        Write-Host "No programs registered." -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "Registered programs ($($store.Count)):" -ForegroundColor Cyan
    Write-Host ""
    foreach ($key in $store.Keys) {
        $e = $store[$key]
        $name = Get-SafeProperty $e 'DisplayName' -Default '(unnamed)'
        $path = Get-SafeProperty $e 'ExePath' -Default '?'
        $vendor = Get-SafeProperty $e 'Vendor'
        $version = Get-SafeProperty $e 'Version'
        $regAt = Get-SafeProperty $e 'RegisteredAt' -Default '?'
        $alive = if ($path -ne '?' -and (Test-Path -LiteralPath $path)) { 'OK' } else { 'MISSING' }
        $statusColor = if ($alive -eq 'OK') { 'Green' } else { 'Red' }

        Write-Host "  [$alive] $name" -ForegroundColor $statusColor
        Write-Host "    Path:   $path" -ForegroundColor Gray
        if ($vendor)  { Write-Host "    Vendor: $vendor"  -ForegroundColor Gray }
        if ($version) { Write-Host "    Ver:    $version" -ForegroundColor Gray }
        Write-Host "    Since:  $regAt" -ForegroundColor DarkGray
        Write-Host ""
    }
}

function Invoke-Repair {
    Write-Log "===== Repair requested ====="
    $store = Get-RegistrationStore
    if ($store.Count -eq 0) {
        Write-Host "Nothing to repair - no registrations." -ForegroundColor Yellow
        return
    }

    $removed = 0; $rebuilt = 0; $ok = 0
    foreach ($key in @($store.Keys)) {
        $entry = $store[$key]
        $name = Get-SafeProperty $entry 'DisplayName' -Default '(unnamed)'
        $exe  = Get-SafeProperty $entry 'ExePath'
        $sc   = Get-SafeProperty $entry 'ShortcutPath'

        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            Write-Host "  REMOVE $name  (target gone)" -ForegroundColor Yellow
            Remove-ShortcutFile -Path $sc
            Remove-AppPathsEntry -KeyName (Get-SafeProperty $entry 'AppPathsKey')
            Remove-UninstallEntry -AppId  (Get-SafeProperty $entry 'AppId')
            $store.Remove($key)
            $removed++
            continue
        }

        if ($sc -and -not (Test-Path -LiteralPath $sc)) {
            Write-Host "  REBUILD $name  (shortcut missing)" -ForegroundColor Cyan
            try {
                New-StartMenuShortcut `
                    -ShortcutPath $sc `
                    -TargetPath $exe `
                    -DisplayName $name `
                    -AppUserModelId (Get-SafeProperty $entry 'AppId') `
                    -Description $name `
                    -WorkingDirectory (Split-Path $exe -Parent)
                $rebuilt++
            } catch {
                Write-Log "Rebuild failed for $name`: $_" -Level Warn
            }
            continue
        }

        $ok++
    }

    Save-RegistrationStore -Store $store
    Write-Host ""
    Write-Host "Repair complete: $ok healthy, $rebuilt rebuilt, $removed removed." -ForegroundColor Green
    Write-Log "Repair: ok=$ok rebuilt=$rebuilt removed=$removed"
}

function Invoke-Doctor {
    Write-Host ""
    Write-Host "WinRegister diagnostic" -ForegroundColor Cyan
    Write-Host "----------------------" -ForegroundColor Cyan

    $ps = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    Write-Host "  PowerShell:    $ps"
    Write-Host "  Windows:       $os"
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    Write-Host "  Script:        $scriptPath"
    Write-Host "  Installed at:  $($script:Cfg.InstalledScript)"
    Write-Host "  Data folder:   $($script:Cfg.DataFolder)"
    Write-Host "  Log file:      $($script:Cfg.LogFile)"
    Write-Host ""

    $installed = Test-Path -LiteralPath $script:Cfg.InstalledScript
    $launcher  = Test-Path -LiteralPath $script:Cfg.HiddenLauncher
    $registry  = Test-Path -LiteralPath $script:Cfg.RegistryFile
    $classic   = Test-ClassicMenuEnabled
    $ownClassic= Test-Path -LiteralPath $script:Cfg.ClassicMenuMarker
    Write-Host "  Installed script:    $(if ($installed) {'OK'} else {'MISSING - run Install.cmd'})" -ForegroundColor $(if ($installed) {'Green'} else {'Yellow'})
    Write-Host "  Hidden launcher:     $(if ($launcher) {'OK'} else {'MISSING'})" -ForegroundColor $(if ($launcher) {'Green'} else {'Yellow'})
    Write-Host "  Registry file:       $(if ($registry) {'OK'} else {'(empty - no registrations yet)'})" -ForegroundColor $(if ($registry) {'Green'} else {'Yellow'})
    $classicSrc = if ($classic) { if ($ownClassic) { 'enabled by WinRegister' } else { 'enabled (set externally)' } } else { 'disabled - entries hide under Show more options' }
    Write-Host "  Classic menu (Win11):$classicSrc" -ForegroundColor $(if ($classic) {'Green'} else {'Yellow'})

    Write-Host ""
    Write-Host "  Context menu entries:" -ForegroundColor White
    foreach ($class in 'exefile', 'lnkfile', 'Directory') {
        foreach ($verb in $script:Cfg.ContextVerbId, $script:Cfg.ContextUnregVerbId) {
            $p = Join-Path $script:Cfg.ContextRoot "$class\shell\$verb\command"
            $present = Test-Path -LiteralPath $p
            $mark = if ($present) { '[OK]' } else { '[--]' }
            $color = if ($present) { 'Green' } else { 'DarkGray' }
            Write-Host "    $mark $class -> $verb" -ForegroundColor $color
        }
    }

    Write-Host ""
    Write-Host "  Registrations:" -ForegroundColor White
    $store = Get-RegistrationStore
    if ($store.Count -eq 0) {
        Write-Host "    (none)" -ForegroundColor DarkGray
    } else {
        $alive = 0; $dead = 0
        foreach ($k in $store.Keys) {
            $exe = Get-SafeProperty $store[$k] 'ExePath'
            if ($exe -and (Test-Path -LiteralPath $exe)) { $alive++ } else { $dead++ }
        }
        Write-Host "    $alive healthy" -ForegroundColor Green
        if ($dead -gt 0) {
            Write-Host "    $dead with missing targets (run -Repair)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

#endregion

#region Install / Uninstall (context menu wiring) -----------------------------

function Write-HiddenLauncher {
    # Generates a tiny VBScript trampoline that invokes PowerShell with
    # WindowStyle 0 (no console flash). Replaces the brief flicker that
    # `-WindowStyle Hidden` alone leaves behind on context-menu invocations.
    $launcher = @"
' WinRegister hidden launcher
' Auto-generated by WinRegister.ps1 - do not edit.
Option Explicit
Dim sh, args, cmd, i
Set sh = CreateObject("WScript.Shell")
Set args = WScript.Arguments
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$($script:Cfg.InstalledScript)"""
For i = 0 To args.Count - 1
    cmd = cmd & " " & """" & args(i) & """"
Next
sh.Run cmd, 0, False
"@
    Set-Content -LiteralPath $script:Cfg.HiddenLauncher -Value $launcher -Encoding ASCII
    Write-Log "Wrote hidden launcher: $($script:Cfg.HiddenLauncher)"
}

function Register-SelfInArp {
    # Make WinRegister itself appear in Settings > Apps so users can uninstall
    # it the standard way. Standard HKCU\...\Uninstall key, same mechanism we
    # use for the apps WE register.
    $keyPath = Join-Path $script:Cfg.UninstallRoot $script:Cfg.SelfArpId
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }

    $uninstallCmd = ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Uninstall -Purge' `
        -f $script:Cfg.InstalledScript)
    $quietCmd = $uninstallCmd

    $installDate = (Get-Date).ToString('yyyyMMdd')
    $estimatedKb = 0
    try {
        $size = (Get-ChildItem -LiteralPath $script:Cfg.DataFolder -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Sum Length).Sum
        $estimatedKb = [int]($size / 1KB)
    } catch { }

    Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayName'          -Value 'WinRegister'                    -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayIcon'          -Value 'imageres.dll,-5323'             -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayVersion'       -Value $script:Cfg.Version              -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'Publisher'            -Value $script:Cfg.Publisher            -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'InstallLocation'      -Value $script:Cfg.DataFolder           -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'InstallDate'          -Value $installDate                     -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'EstimatedSize'        -Value $estimatedKb                     -Type DWord
    Set-ItemProperty -LiteralPath $keyPath -Name 'UninstallString'      -Value $uninstallCmd                    -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'QuietUninstallString' -Value $quietCmd                        -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'URLInfoAbout'         -Value $script:Cfg.HomepageUrl          -Type String
    Set-ItemProperty -LiteralPath $keyPath -Name 'NoModify'             -Value 1                                -Type DWord
    Set-ItemProperty -LiteralPath $keyPath -Name 'NoRepair'             -Value 1                                -Type DWord

    Write-Log "Self-registered in Apps & Features at $keyPath"
}

function Unregister-SelfFromArp {
    $keyPath = Join-Path $script:Cfg.UninstallRoot $script:Cfg.SelfArpId
    if (Test-Path -LiteralPath $keyPath) {
        Remove-Item -LiteralPath $keyPath -Recurse -Force
        Write-Log "Removed self-registration from Apps & Features"
    }
}

function New-SelfStartMenuShortcuts {
    # A "WinRegister" subfolder in Start Menu with Settings and About entries.
    Initialize-Native

    if (-not (Test-Path -LiteralPath $script:Cfg.SelfStartMenuFolder)) {
        New-Item -ItemType Directory -Path $script:Cfg.SelfStartMenuFolder -Force | Out-Null
    }

    $launcher = $script:Cfg.HiddenLauncher
    if (-not (Test-Path -LiteralPath $launcher)) { return }

    # The shortcut targets wscript.exe and passes our launcher + the action.
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'

    foreach ($entry in @(
        @{ Name = 'WinRegister Settings'; Arg = '-Settings'; Aumid = 'WinRegister.Self.Settings' }
        @{ Name = 'WinRegister Updates';  Arg = '-CheckUpdate'; Aumid = 'WinRegister.Self.Updates' }
    )) {
        $scPath = Join-Path $script:Cfg.SelfStartMenuFolder "$($entry.Name).lnk"
        [WinRegister.Native]::CreateShortcut(
            $scPath,
            $wscript,
            ('"{0}" {1}' -f $launcher, $entry.Arg),
            $script:Cfg.DataFolder,
            $entry.Name,
            $script:Cfg.InstalledScript,    # icon source - PS doesn't have a great icon, fall back to imageres if PE has none
            0,
            $entry.Aumid
        )
        Write-Log "Created self Start Menu shortcut: $scPath"
    }
}

function Remove-SelfStartMenuShortcuts {
    if (Test-Path -LiteralPath $script:Cfg.SelfStartMenuFolder) {
        Remove-Item -LiteralPath $script:Cfg.SelfStartMenuFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed self Start Menu folder"
    }
}

function Install-WinRegister {
    param([switch]$SkipSelfArp)
    Write-Log "===== Install requested (SkipSelfArp=$SkipSelfArp) ====="
    Initialize-DataFolder
    Initialize-SettingsFolder

    $sourceScript = $PSCommandPath
    if (-not $sourceScript) { $sourceScript = $MyInvocation.MyCommand.Path }
    if (-not $sourceScript -or -not (Test-Path -LiteralPath $sourceScript)) {
        throw "Could not locate WinRegister.ps1 source for install."
    }
    Copy-Item -LiteralPath $sourceScript -Destination $script:Cfg.InstalledScript -Force
    Write-Log "Copied script to: $($script:Cfg.InstalledScript)"

    # CLI shim (visible window) - for command-line use
    $shim = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$($script:Cfg.InstalledScript)" %*
"@
    Set-Content -LiteralPath $script:Cfg.InstalledShim -Value $shim -Encoding ASCII

    # Hidden launcher (no console flash) - for context menu use
    Write-HiddenLauncher

    # Add install folder to user PATH if not present
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $segments = @($userPath -split ';' | Where-Object { $_ })
    if ($segments -notcontains $script:Cfg.DataFolder) {
        $newPath = (@($segments) + $script:Cfg.DataFolder) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Log "Added $($script:Cfg.DataFolder) to user PATH."
    }

    $launcherCmd = "wscript.exe `"$($script:Cfg.HiddenLauncher)`""

    $targets = @(
        @{ Class = 'exefile'   }
        @{ Class = 'lnkfile'   }
        @{ Class = 'Directory' }
    )

    foreach ($t in $targets) {
        $base = Join-Path $script:Cfg.ContextRoot "$($t.Class)\shell"

        $reg = Join-Path $base $script:Cfg.ContextVerbId
        $regCmd = Join-Path $reg 'command'
        New-Item -Path $reg -Force | Out-Null
        New-Item -Path $regCmd -Force | Out-Null
        Set-ItemProperty -LiteralPath $reg -Name '(Default)' -Value $script:Cfg.ContextLabel
        Set-ItemProperty -LiteralPath $reg -Name 'Icon'      -Value $script:Cfg.ContextIconRegister
        Set-ItemProperty -LiteralPath $regCmd -Name '(Default)' -Value "$launcherCmd -Register `"%1`""

        $unreg = Join-Path $base $script:Cfg.ContextUnregVerbId
        $unregCmd = Join-Path $unreg 'command'
        New-Item -Path $unreg -Force | Out-Null
        New-Item -Path $unregCmd -Force | Out-Null
        Set-ItemProperty -LiteralPath $unreg -Name '(Default)' -Value $script:Cfg.ContextUnregLabel
        Set-ItemProperty -LiteralPath $unreg -Name 'Icon'      -Value $script:Cfg.ContextIconUnregister
        Set-ItemProperty -LiteralPath $unregCmd -Name '(Default)' -Value "$launcherCmd -Unregister `"%1`""

        Write-Log "Wrote context menu for $($t.Class): $base"
    }

    # Make our entries appear at the top level of the Win11 right-click menu
    # (no "Show more options" required). Track whether we owned the change.
    $weEnabledClassic = Enable-ClassicContextMenu
    if ($weEnabledClassic) {
        Set-Content -LiteralPath $script:Cfg.ClassicMenuMarker -Value 'true' -Encoding ASCII
    }

    # Tell Explorer file associations changed.
    try {
        Initialize-Native
        [WinRegister.Native]::NotifyAssocChanged()
        Write-Log "SHChangeNotify(SHCNE_ASSOCCHANGED) broadcast."
    } catch {
        Write-Log "SHChangeNotify failed (non-fatal): $_" -Level Warn
    }

    # Self-register so the user can uninstall WinRegister from Settings > Apps
    # like any other program. Skipped when invoked by Inno Setup (which writes
    # its own ARP entry per the installer's standard mechanism).
    if (-not $SkipSelfArp) {
        try { Register-SelfInArp } catch { Write-Log "Self-ARP failed (non-fatal): $_" -Level Warn }
    } else {
        Write-Log "Self-ARP skipped (-SkipSelfArp specified)."
    }

    # Start Menu shortcuts for the Settings UI and update check.
    try { New-SelfStartMenuShortcuts } catch { Write-Log "Self Start Menu shortcut failed (non-fatal): $_" -Level Warn }

    # Restart Explorer so the classic menu + new entries take effect immediately.
    Restart-WindowsExplorer

    Show-ToastMessage -Title 'WinRegister installed' -Message "Right-click any .exe, shortcut, or folder -> 'Register with Windows'." -Level Info
}

function Uninstall-WinRegister {
    Write-Log "===== Uninstall requested (Purge=$Purge) ====="

    foreach ($class in 'exefile', 'lnkfile', 'Directory') {
        foreach ($verb in $script:Cfg.ContextVerbId, $script:Cfg.ContextUnregVerbId) {
            $path = Join-Path $script:Cfg.ContextRoot "$class\shell\$verb"
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
                Write-Log "Removed context menu key: $path"
            }
        }
    }

    if ($Purge) {
        $store = Get-RegistrationStore
        foreach ($key in @($store.Keys)) {
            $entry = $store[$key]
            try {
                Remove-ShortcutFile -Path (Get-SafeProperty $entry 'ShortcutPath')
                Remove-AppPathsEntry -KeyName (Get-SafeProperty $entry 'AppPathsKey')
                Remove-UninstallEntry -AppId  (Get-SafeProperty $entry 'AppId')
            } catch {
                Write-Log "Purge cleanup warning: $_" -Level Warn
            }
        }
        Save-RegistrationStore -Store ([ordered]@{})
        Write-Log "Purged all registrations."
    }

    # Remove install folder from user PATH
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $segments = $userPath -split ';' | Where-Object { $_ -and $_ -ne $script:Cfg.DataFolder }
        $newPath = ($segments -join ';')
        if ($newPath -ne $userPath) {
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Log "Removed $($script:Cfg.DataFolder) from user PATH."
        }
    }

    # Remove self-registration from Apps & Features + Start Menu shortcuts.
    try { Unregister-SelfFromArp }         catch { Write-Log "Remove self-ARP: $_" -Level Warn }
    try { Remove-SelfStartMenuShortcuts }  catch { Write-Log "Remove self Start Menu: $_" -Level Warn }

    # Revert the classic menu tweak only if WE set it on install.
    $weOwnedClassic = Test-Path -LiteralPath $script:Cfg.ClassicMenuMarker
    if ($weOwnedClassic) {
        Disable-ClassicContextMenu
        Remove-Item -LiteralPath $script:Cfg.ClassicMenuMarker -Force -ErrorAction SilentlyContinue
    }

    if ($Purge -and (Test-Path -LiteralPath $script:Cfg.DataFolder)) {
        Remove-Item -LiteralPath $script:Cfg.DataFolder -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Notify shell + restart Explorer so the menu change takes effect.
    try {
        Initialize-Native
        [WinRegister.Native]::NotifyAssocChanged()
        Write-Log "SHChangeNotify(SHCNE_ASSOCCHANGED) broadcast."
    } catch {
        Write-Log "SHChangeNotify failed (non-fatal): $_" -Level Warn
    }
    Restart-WindowsExplorer

    Show-ToastMessage -Title 'WinRegister uninstalled' -Message 'Context menu entries removed.' -Level Info
}

#endregion

#region Help ------------------------------------------------------------------

function Invoke-SelfTest {
    # Internal verification suite. Exercises every subsystem against a
    # throwaway test exe, then cleans up. Returns 0 on success, 1 on any failure.
    # Useful when shipping a new build or diagnosing a confused install.
    #
    # Counters live in a hashtable because PowerShell nested functions can read
    # parent locals but writes default to local scope - a hashtable is mutated
    # by reference and avoids the trap.
    $state = @{ Passed = 0; Total = 0; Errors = @() }

    function Test-Step {
        param([string]$Name, [scriptblock]$Block)
        $state.Total++
        try {
            $r = & $Block
            if ($r -eq $false) { throw "returned false" }
            $state.Passed++
            Write-Host ("  [OK]   {0}" -f $Name) -ForegroundColor Green
        } catch {
            $state.Errors += "$Name : $($_.Exception.Message)"
            Write-Host ("  [FAIL] {0} - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "WinRegister self-test v$($script:Cfg.Version)" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    # 1. Native helpers compile + PE detection
    Test-Step 'Initialize-Native compiles' { Initialize-Native; [WinRegister.Native] -as [type] -ne $null }
    Test-Step 'PE subsystem: notepad.exe = GUI(2)' { (Get-PESubsystem -Path "$env:WINDIR\System32\notepad.exe") -eq 2 }
    Test-Step 'PE subsystem: cmd.exe = CUI(3)'    { (Get-PESubsystem -Path "$env:WINDIR\System32\cmd.exe") -eq 3 }
    Test-Step 'PE subsystem: this script = invalid(0)' {
        $me = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        (Get-PESubsystem -Path $me) -eq 0
    }

    # 2. Identifier helpers
    Test-Step 'ConvertTo-PascalCase: "r2 mod manager" => "R2ModManager"' {
        (ConvertTo-PascalCase 'r2 mod manager') -eq 'R2ModManager'
    }
    Test-Step 'ConvertTo-PascalCase empty => "App"' { (ConvertTo-PascalCase '') -eq 'App' }
    Test-Step 'New-AppId is stable per path' {
        $a = New-AppId -DisplayName 'T' -ExePath 'C:\X\t.exe'
        $b = New-AppId -DisplayName 'T' -ExePath 'C:\X\t.exe'
        $a -eq $b
    }
    Test-Step 'New-AppId differs across paths' {
        $a = New-AppId -DisplayName 'T' -ExePath 'C:\X\t.exe'
        $b = New-AppId -DisplayName 'T' -ExePath 'D:\Y\t.exe'
        $a -ne $b
    }

    # 3. Settings round-trip
    $sf = $script:Cfg.SettingsFile
    $sfBackup = if (Test-Path $sf) { Backup-File -Path $sf -Tag 'selftest' } else { $null }
    Test-Step 'Settings: defaults are valid' {
        $s = Get-DefaultSettings
        ($s.Confirmation.AskOnRegister -eq $true) -and ($s.Updates.CheckEnabled -eq $true)
    }
    Test-Step 'Settings: save+load round-trips' {
        $s = Get-DefaultSettings
        $s.Confirmation.AskOnRegister = $false
        Save-Settings -Settings $s
        (Get-Settings).Confirmation.AskOnRegister -eq $false
    }

    # 4. Blacklist refinements
    Test-Step 'Blacklist accepts r2modman'      { -not (Test-IsBlacklisted -ExeBaseName 'r2modman') }
    Test-Step 'Blacklist accepts python (portable)' { -not (Test-IsBlacklisted -ExeBaseName 'python') }
    Test-Step 'Blacklist rejects setup'         { Test-IsBlacklisted -ExeBaseName 'setup' }
    Test-Step 'Blacklist rejects unins000'      { Test-IsBlacklisted -ExeBaseName 'unins000' }
    Test-Step 'Blacklist honors ExtraPatterns'  { Test-IsBlacklisted -ExeBaseName 'badtool' -ExtraPatterns @('badtool') }

    # 5. End-to-end register + unregister with a real binary
    $tempDir = Join-Path $env:TEMP "WinRegister-SelfTest-$([Guid]::NewGuid().ToString('N').Substring(0,6))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $tempExe = Join-Path $tempDir 'SelfTestApp.exe'
    Copy-Item "$env:WINDIR\System32\notepad.exe" $tempExe
    $aumid = New-AppId -DisplayName 'SelfTest App' -ExePath $tempExe

    Test-Step 'Register: produces shortcut + ARP entry' {
        Invoke-Register -InputPath $tempExe -OverrideName 'SelfTest App' -SkipConfirm
        $store = Get-RegistrationStore
        $hit = $store.Keys | Where-Object { (Get-SafeProperty $store[$_] 'ExePath') -ieq $tempExe }
        if (-not $hit) { return $false }
        Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$aumid"
    }
    Test-Step 'Unregister: removes shortcut + ARP entry' {
        Invoke-Unregister -InputPath $tempExe -SkipConfirm
        -not (Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$aumid")
    }

    # Cleanup
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($sfBackup -and (Test-Path $sfBackup)) {
        Copy-Item -LiteralPath $sfBackup -Destination $sf -Force
        Remove-Item -LiteralPath $sfBackup -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host ("Result: {0} passed, {1} failed" -f $state.Passed, $state.Errors.Count) -ForegroundColor $(if ($state.Errors.Count -eq 0){'Green'}else{'Red'})
    Write-Host ""
    if ($state.Errors.Count -gt 0) { exit 1 }
}

function Show-Help {
    Write-Host ""
    Write-Host "WinRegister v$($script:Cfg.Version)" -ForegroundColor Cyan
    Write-Host "Register any program with Windows Search, Start Menu, and Apps & Features." -ForegroundColor Gray
    Write-Host ""
    Write-Host "USAGE" -ForegroundColor White
    Write-Host "  .\WinRegister.ps1 -Install                  Set up (one-time, adds right-click entries)" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Register <path>          Register a .exe / .lnk / folder" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Unregister <path>        Remove a previous registration" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -List                     Show all WinRegister registrations" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Settings                 Open the settings dialog" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -CheckUpdate              Check for a newer release now" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Repair                   Heal dead entries / rebuild missing shortcuts" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Doctor                   Diagnostic snapshot of install + registrations" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -SelfTest                 Run internal verification suite" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Version                  Print version and exit" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Uninstall                Remove the right-click entries" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Uninstall -Purge         Also remove every registration" -ForegroundColor Gray
    Write-Host ""
    Write-Host "After installing, right-click any program file or its folder and choose" -ForegroundColor Gray
    Write-Host "'Register with Windows'. On Windows 11 this lives under 'Show more options'" -ForegroundColor Gray
    Write-Host "(or use Shift+Right-click)." -ForegroundColor Gray
    Write-Host ""
}

#endregion

#region Dispatch --------------------------------------------------------------

try {
    Initialize-DataFolder
} catch {
    Write-Host "Could not create data folder: $_" -ForegroundColor Red
    exit 1
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Register' {
            Invoke-StartupUpdateCheck
            Invoke-Register   -InputPath $Register   -OverrideName $DisplayName -SkipConfirm:$NoConfirm
        }
        'Unregister' {
            Invoke-StartupUpdateCheck
            Invoke-Unregister -InputPath $Unregister -SkipConfirm:$ForceUnregister
        }
        'Install'    { Install-WinRegister -SkipSelfArp:$SkipSelfArp }
        'Uninstall'  { Uninstall-WinRegister }
        'List'       { Show-RegistrationList }
        'Repair'     { Invoke-Repair }
        'Doctor'     { Invoke-Doctor }
        'Settings'   { Show-SettingsDialog }
        'Version'    { Write-Host $script:Cfg.Version }
        'SelfTest'   { Invoke-SelfTest }
        'CheckUpdate' {
            # NOTE: must not use $settings here - it collides case-insensitively
            # with the script param [switch]$Settings and triggers a switch-cast error.
            $prefs = Get-Settings
            $result = Test-UpdateAvailable -Settings $prefs -Force
            Initialize-DpiAwareness
            Add-Type -AssemblyName System.Windows.Forms
            switch ("$($result.Status)") {
                'UpdateAvailable' {
                    Show-UpdateNotification -Update $result -Settings $prefs
                }
                'UpToDate' {
                    [System.Windows.Forms.MessageBox]::Show(
                        "You're on the latest version ($($script:Cfg.Version)).",
                        'WinRegister', 'OK', 'Information') | Out-Null
                }
                default {
                    # CheckFailed - distinguish from up-to-date so user knows
                    $msg = if ($result -and $result.ErrorMessage) {
                        "Could not contact the update server:`n`n$($result.ErrorMessage)"
                    } else {
                        "Could not contact the update server. Try again later."
                    }
                    [System.Windows.Forms.MessageBox]::Show($msg, 'WinRegister', 'OK', 'Warning') | Out-Null
                }
            }
        }
        default      { Show-Help }
    }
} catch {
    Write-Log "Top-level failure: $_" -Level Error
    Show-ErrorDialog "WinRegister failed:`n$($_.Exception.Message)"
    exit 1
}

#endregion
