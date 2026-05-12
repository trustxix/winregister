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

    [Parameter(ParameterSetName = 'Install', Mandatory)]
    [switch]$Install,

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
    Version              = '1.1.0'
    SchemaVersion        = 2
    AppName              = 'WinRegister'
    StartMenuFolder      = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    DataFolder           = Join-Path $env:LOCALAPPDATA 'WinRegister'
    InstalledScript      = Join-Path $env:LOCALAPPDATA 'WinRegister\WinRegister.ps1'
    InstalledShim        = Join-Path $env:LOCALAPPDATA 'WinRegister\winregister.cmd'
    HiddenLauncher       = Join-Path $env:LOCALAPPDATA 'WinRegister\winregister-launcher.vbs'
    RegistryFile         = Join-Path $env:LOCALAPPDATA 'WinRegister\registrations.json'
    LogFile              = Join-Path $env:LOCALAPPDATA 'WinRegister\winregister.log'
    LogMaxBytes          = 1MB
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
    BlacklistPatterns    = @(
        'unins*', 'uninstall*', 'setup', 'setup_*', 'installer', 'install',
        'vc_redist*', 'vcredist*', 'msvcr*', 'msvcp*', 'ucrtbase*',
        'crashpad_handler', '*crashreporter*', '*crash_handler*', '*-crashpad*',
        'dxsetup', 'dotnet-host*', 'msedgewebview2',
        '*-helper', '*_helper', '* Helper',
        '*-gpu', '*_gpu',
        '*-updater', '*_updater', 'update', 'updater',
        'python', 'pythonw', 'node', 'nodew',
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
    param([string]$ExeBaseName)
    $name = $ExeBaseName.ToLowerInvariant()
    foreach ($pat in $script:Cfg.BlacklistPatterns) {
        if ($name -like $pat) { return $true }
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
    param([string]$FolderPath)

    Write-Log "Scanning folder for primary executable: $FolderPath"

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        throw "Folder not found: $FolderPath"
    }

    $folderFull = [System.IO.Path]::GetFullPath($FolderPath)
    $exes = @(Get-ChildItem -LiteralPath $folderFull -Filter *.exe -Recurse -Depth 4 -Force -ErrorAction SilentlyContinue |
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
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $ext = $item.Extension.ToLowerInvariant()

    if ($item.PSIsContainer) {
        return Find-PrimaryExecutable -FolderPath $item.FullName
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
        if (-not $target -or -not (Test-Path -LiteralPath $target)) {
            throw "Shortcut target unreachable: $target"
        }
        if ((Get-Item -LiteralPath $target).PSIsContainer) {
            return Find-PrimaryExecutable -FolderPath $target
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

#endregion

#region Top-level actions -----------------------------------------------------

function Invoke-Register {
    param(
        [Parameter(Mandatory)] [string]$InputPath,
        [string]$OverrideName,
        [switch]$SkipConfirm
    )

    Write-Log "===== Register requested: $InputPath ====="

    try {
        $exePath = $null
        try {
            $exePath = Resolve-Target -Path $InputPath
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
        if (Test-IsBlacklisted -ExeBaseName $base) {
            Show-ErrorDialog "This file looks like an installer, uninstaller, or helper binary and won't be registered:`n$exePath"
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

        if (-not $SkipConfirm) {
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
        $shortcutPath = Join-Path $script:Cfg.StartMenuFolder "$shortcutFileName.lnk"

        if ((Test-Path -LiteralPath $shortcutPath) -and -not $existing) {
            $shortcutPath = Join-Path $script:Cfg.StartMenuFolder "$shortcutFileName ($($meta.BaseName)).lnk"
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
        Show-ToastMessage -Title 'Registered' -Message "$($meta.DisplayName) is now in Windows Search." -Level Info
    }
    catch {
        Write-Log "Register top-level: $_" -Level Error
        Show-ErrorDialog "WinRegister failed:`n$($_.Exception.Message)"
    }
}

function Invoke-Unregister {
    param([Parameter(Mandatory)] [string]$InputPath)

    Write-Log "===== Unregister requested: $InputPath ====="

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
        Remove-ShortcutFile -Path (Get-SafeProperty $entry 'ShortcutPath')
        Remove-AppPathsEntry -KeyName (Get-SafeProperty $entry 'AppPathsKey')
        Remove-UninstallEntry -AppId   (Get-SafeProperty $entry 'AppId')

        Edit-RegistrationStore {
            param($store)
            $store.Remove($foundId)
        }.GetNewClosure()

        Write-Log "Unregistered: $displayName"
        Show-ToastMessage -Title 'Unregistered' -Message "$displayName was removed from Windows Search." -Level Info
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

function Install-WinRegister {
    Write-Log "===== Install requested ====="
    Initialize-DataFolder

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
    Write-Host "  .\WinRegister.ps1 -Repair                   Heal dead entries / rebuild missing shortcuts" -ForegroundColor Gray
    Write-Host "  .\WinRegister.ps1 -Doctor                   Diagnostic snapshot of install + registrations" -ForegroundColor Gray
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
        'Register'   { Invoke-Register   -InputPath $Register   -OverrideName $DisplayName -SkipConfirm:$NoConfirm }
        'Unregister' { Invoke-Unregister -InputPath $Unregister }
        'Install'    { Install-WinRegister }
        'Uninstall'  { Uninstall-WinRegister }
        'List'       { Show-RegistrationList }
        'Repair'     { Invoke-Repair }
        'Doctor'     { Invoke-Doctor }
        default      { Show-Help }
    }
} catch {
    Write-Log "Top-level failure: $_" -Level Error
    Show-ErrorDialog "WinRegister failed:`n$($_.Exception.Message)"
    exit 1
}

#endregion
