# Changelog

All notable changes to WinRegister are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-05-12

### Added
- **Settings system.** Per-user settings live in `%APPDATA%\WinRegister\settings.json`.
  Schema-versioned with forward-compatible defaults merge.
- **`-Settings` command** opens a tabbed WinForms dialog (General, Updates, About).
- **Automatic update checking.** Daily check against the GitHub Releases API with
  configurable frequency, "Skip this version" and "Remind me later" options, and a
  user opt-out toggle. Sends a proper `User-Agent` header per GitHub API requirements.
- **`-CheckUpdate` command** for on-demand update checks.
- **Self-registration in Apps & Features.** WinRegister now appears in
  Settings > Apps and can be uninstalled the standard way.
- **Start Menu shortcuts** for `WinRegister Settings` and `WinRegister Updates`,
  installed under a `WinRegister/` subfolder.
- **General-tab actions** in Settings: Clear all registrations, Open log folder,
  Reset settings.
- **`Notifications.ShowOnRegister/Unregister`** settings to toggle success toasts
  independently per action.
- **`Confirmation.AskOnRegister/Unregister`** settings to skip confirmation dialogs.

### Changed
- LICENSE added (MIT).
- Version bumped to 1.2.0.

## [1.1.0] - 2026-05-12

### Added
- WinForms confirmation dialog with foreground-grab via `AttachThreadInput`
  so the dialog is reliably visible when launched from a background context.
- `Edit-RegistrationStore` atomic file-locked read-modify-write helper.
- `-Repair` command — heals dead entries and rebuilds missing shortcuts.
- `-Doctor` command — prints a diagnostic snapshot (PowerShell/Windows
  versions, install state, context menu wiring, registration health).
- VBS hidden launcher (`winregister-launcher.vbs`) to eliminate the
  PowerShell console flash on context-menu invocation.
- `SHChangeNotify(SHCNE_ASSOCCHANGED)` broadcast on install/uninstall.
- DPI awareness via `SetProcessDPIAware` for all WinForms UI.
- Automatic enable of Windows 11 classic context menu on first install (with
  marker-tracked revert on uninstall, only if WinRegister was the one that set it).
- AppUserModelID generation per the Microsoft spec (PascalCase, ≤128 chars).
- ARP entries now include `EstimatedSize`, `InstallDate`, `QuietUninstallString`.
- `Get-SafeProperty` defensive helper for forward-compat PSCustomObject access.

### Fixed
- Process-wide `System.Threading.Mutex` was replaced with OS-level file locking;
  it could previously deadlock when an Explorer restart orphaned a confirmation
  dialog.
- Lowercase AppUserModelID slug → now PascalCase per Microsoft Win32 Shell spec.
- ARP `DisplayName` longer than 32 chars hid the entry; now truncated.
- `App Paths` `Path` value was always written; now omitted per Microsoft
  best-practice (only `(Default)` is required).
- `ProductName` consisting of only whitespace produced an empty display name.

### Removed
- `Set-StrictMode -Version Latest`. Strict mode v3+ throws on access to undefined
  `PSCustomObject` properties, which is incompatible with forward-compatible JSON
  schemas. All dynamic reads now go through `Get-SafeProperty`.

## [1.0.0] - 2026-05-11

### Added
- Initial WinRegister release.
- Right-click `Register with Windows` / `Unregister from Windows` context menu
  entries on `.exe`, `.lnk`, and `Directory` classes.
- PE-header subsystem detection for auto-discovering primary executables in
  folders (GUI vs CUI vs invalid).
- Heuristic primary-exe scoring (filename ↔ folder match, version info,
  Electron `resources/app.asar` signal, depth penalty, name blacklist).
- Per-user registration via Start Menu `.lnk`, HKCU `App Paths`, and HKCU ARP.
- Inline C# `IShellLink`/`IPropertyStore` COM interop.
- Persistent registration store at `%LOCALAPPDATA%\WinRegister\registrations.json`.

[1.2.0]: https://github.com/trustxix/windows-config/releases/tag/v1.2.0
[1.1.0]: https://github.com/trustxix/windows-config/releases/tag/v1.1.0
[1.0.0]: https://github.com/trustxix/windows-config/releases/tag/v1.0.0
