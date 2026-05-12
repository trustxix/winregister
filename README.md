# WinRegister

Register any portable program with Windows Search, the Start Menu, the Run
dialog (`Win+R`), and Apps & Features — by right-clicking it.

Solves the everyday annoyance that portable apps (Electron releases, GitHub
release `.exe`s, extracted ZIP tools, mod managers, etc.) don't show up in
Windows Search because no installer ever dropped a Start Menu shortcut for them.

WinRegister fixes that with a single right-click.

---

## Install

1. Grab **`WinRegister-Setup-x.y.z.exe`** from the
   [latest release](https://github.com/trustxix/winregister/releases/latest).
2. Double-click it.
3. Done. No admin prompt, no extracting, no console window.

> The first time you run it, Windows may show a "Windows protected your PC"
> dialog because the installer isn't yet code-signed. Click **More info → Run
> anyway**. This is the same one-time hurdle every unsigned indie tool faces
> until SmartScreen builds a reputation for the binary.

**To uninstall**: Settings → Apps → WinRegister → Uninstall.

<details>
<summary>Power-user install (ZIP)</summary>

If you'd rather not run an installer, download the
`WinRegister-x.y.z-source.zip` from the same release page, extract anywhere,
then run from PowerShell:

```
powershell -ExecutionPolicy Bypass -File .\WinRegister.ps1 -Install
```
</details>

## Use

After installing:

- **Register**: Right-click any `.exe`, `.lnk`, or folder containing a program →
  `Register with Windows` → confirm the dialog. The app now appears in Windows
  Search within seconds.
- **Unregister**: Same flow, choose `Unregister from Windows`.
- **Settings**: `Start Menu → WinRegister → WinRegister Settings`, or run
  `winregister -Settings` from any terminal.

## What it actually does

Every registration writes four things (all per-user, all reversible):

| Channel | Effect |
|---|---|
| `.lnk` in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\` with PascalCased AppUserModelID | Windows Search + Start Menu + taskbar pinning |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\<exe>` | `Win+R` launching by name |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<id>` | Visible in *Settings > Apps* with a working uninstall |
| Tracking record in `%LOCALAPPDATA%\WinRegister\registrations.json` | So unregister/repair work cleanly |

Implementation references the Microsoft Win32 specifications directly — see
the inline comments in `WinRegister.ps1` for citations against the
[PE Format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format),
[App Paths](https://learn.microsoft.com/en-us/windows/win32/shell/app-registration),
[AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/appids),
and [Uninstall registry key](https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key)
docs.

## CLI reference

```
winregister -Install               Set up (run Install.cmd or this once)
winregister -Register <path>       Register a .exe / .lnk / folder
winregister -Unregister <path>     Remove a previous registration
winregister -List                  Show all registered programs
winregister -Settings              Open the Settings dialog
winregister -CheckUpdate           Check for a newer release now
winregister -Repair                Heal dead entries / rebuild missing shortcuts
winregister -Doctor                Diagnostic snapshot
winregister -Uninstall             Remove the right-click menu entries
winregister -Uninstall -Purge      Also remove every registration
```

`winregister` is on your `PATH` after Install.cmd runs.

## Requirements

- Windows 10 or Windows 11 (any edition)
- Windows PowerShell 5.1 (ships with Windows by default) — no install needed
- Per-user install, no administrator rights required

## Settings

Located at `%APPDATA%\WinRegister\settings.json`. Editable from the Settings
UI (General / Updates / About tabs) or directly in any text editor.

Defaults:

- Ask for confirmation before register/unregister (toggle off for one-click flow)
- Show success toast after register/unregister
- Check for updates daily (toggle off to disable entirely)
- Auto-detect primary executable when registering a folder

## Updates

WinRegister checks GitHub Releases at most once per day for a newer version,
shows a non-intrusive prompt if one is found, and lets you Skip a version or
postpone the reminder. The check is fully optional and can be disabled in
Settings → Updates.

The check uses a proper `User-Agent` header (required by the GitHub API) and
respects rate-limit best practices — it makes one request per day max, never
on a hot path.

## Privacy

Zero telemetry. WinRegister makes exactly one outbound request, only when an
update check is due, only to `api.github.com/repos/trustxix/winregister/releases/latest`,
and only to read the latest tag and release notes. No identifiers, no analytics,
no third-party endpoints.

## License

MIT. See [LICENSE](LICENSE).
