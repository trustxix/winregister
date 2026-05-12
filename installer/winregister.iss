; WinRegister - Inno Setup script
; Build: ISCC.exe /DAppVersion=1.2.2 installer\winregister.iss
;
; Inno Setup home: https://jrsoftware.org/isinfo.php
; Reference:       https://jrsoftware.org/ishelp/

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

[Setup]
; AppId uniquely identifies this app for upgrade detection. DO NOT change once
; published or upgrades from older builds will create a duplicate entry.
AppId={{E8E7A3B4-9C1D-4F5E-A8B2-D1E3F5A7C9D2}
AppName=WinRegister
AppVersion={#AppVersion}
AppVerName=WinRegister {#AppVersion}
AppPublisher=trustxix
AppPublisherURL=https://github.com/trustxix/winregister
AppSupportURL=https://github.com/trustxix/winregister/issues
AppUpdatesURL=https://github.com/trustxix/winregister/releases
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName=WinRegister
VersionInfoCompany=trustxix

; Per-user install - no admin / UAC required.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=

; Install to %LOCALAPPDATA%\WinRegister so the install path matches what the
; existing PowerShell script expects (it deploys itself there too).
DefaultDirName={localappdata}\WinRegister
DefaultGroupName=WinRegister
UsePreviousAppDir=yes

; Streamlined one-click experience: skip the pages that are noise for a small
; per-user tool. Keep License and Finished so users see what they're agreeing
; to and get clean post-install confirmation.
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableFinishedPage=no
LicenseFile=..\LICENSE

WizardStyle=modern
WizardSizePercent=100
SetupLogging=yes

OutputDir=output
OutputBaseFilename=WinRegister-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes

UninstallDisplayIcon={app}\WinRegister.ps1
UninstallDisplayName=WinRegister

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\WinRegister.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\CHANGELOG.md";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE";         DestDir: "{app}"; Flags: ignoreversion

[Run]
; After files are copied, run the PowerShell -Install action to wire up the
; context menu, App Paths, Start Menu shortcuts, etc. -SkipSelfArp tells it
; NOT to write its own ARP entry (Inno's standard entry is canonical).
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\WinRegister.ps1"" -Install -SkipSelfArp -Silent"; \
  StatusMsg: "Configuring Windows integration..."; \
  Flags: runhidden waituntilterminated

; Optional: offer to open Settings after install
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\WinRegister.ps1"" -Settings"; \
  Description: "Open WinRegister settings now"; \
  Flags: runhidden postinstall skipifsilent unchecked nowait

[UninstallRun]
; Before files are removed, run our cleanup: removes context menu entries,
; classic-menu tweak (if we set it), user PATH entry, Start Menu shortcuts,
; and every registration the user made.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\WinRegister.ps1"" -Uninstall -Purge"; \
  StatusMsg: "Removing WinRegister integration..."; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "WinRegisterCleanup"

[UninstallDelete]
; Remove data folders that aren't tracked by Inno but were created at runtime.
Type: filesandordirs; Name: "{localappdata}\WinRegister"
Type: filesandordirs; Name: "{userappdata}\WinRegister"
