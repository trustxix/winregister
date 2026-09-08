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

Only one of the two ever shows at a time: something already registered offers
`Unregister from Windows`, everything else offers `Register with Windows`. The
menu updates immediately — no Explorer restart or sign-out.
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
| `AppliesTo` condition on both context-menu verbs | So each item shows only the entry that applies to it |

## Registrations look after themselves

A registration is a set of pointers at one absolute path, so anything that moves
the program breaks all of them at once — and portable apps move constantly.
An updater unpacks into a versioned sibling folder, a tools drive gets
reorganised, a reinstall lands somewhere else, and the Start Menu entry silently
stops working.

WinRegister handles that without being asked. Before every action, and from a
per-user scheduled task at logon and once a day, it checks each registration and:

- **follows a program that moved** — finds it near where it used to be and
  rewrites the shortcut, the `Win+R` name and the Apps & Features record to match;
- **repairs drift** — a deleted Start Menu shortcut, an App Paths key pointing
  somewhere else, a missing uninstall record, or a version string left behind by
  an in-place update;
- **drops an entry only once the program cannot be found at all.**

The search climbs from the dead path to the nearest folder that still exists and
scans down from there. It weighs filename, product name and publisher, refuses an
executable another registration already owns, and stops at the first ancestor too
broad to search, so it never scans a whole drive. Every stage has an off switch
under `Maintenance` in `settings.json`.

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
winregister -Repair                Follow moved programs, rebuild artefacts, drop dead entries
winregister -SelfHeal              The same pass, silent (runs automatically)
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
- `Maintenance.AutoHeal` / `AutoRelocate` / `AutoPrune` / `ScheduledTask` — the
  self-maintenance stages described above, all on

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
