# WinRegister — working notes

Single-file Windows PowerShell 5.1 tool. `WinRegister.ps1` is the whole product;
`Install.cmd` / `Uninstall.cmd` are thin wrappers. Per-user, no admin, no
dependencies outside what ships with Windows.

Read [`docs/what-works-and-what-doesnt.md`](docs/what-works-and-what-doesnt.md)
before attempting a fix. It records approaches that were tried and rejected, and
the reasons are not guessable from the code.

## Commands that have side effects on the developer's own machine

This tool installs itself into the shell of whatever machine runs it. Three
switches are not safe to run casually:

| Switch | Why |
|---|---|
| `-Install` | Restarts Explorer, shows a toast, rewrites the user's `PATH`. |
| `-Uninstall` | Same, plus `-Purge` deletes every registration and the data folder. |
| `-CheckUpdate` / `-Settings` | Open WinForms windows. |

`-SelfTest`, `-SelfHeal`, `-Doctor`, `-List` and `-Repair` draw nothing and are
safe. `-SelfTest` sets `$script:SuppressDialogs`, disables notifications, and
restores the user's `settings.json` from a backup when it finishes — keep it
that way, and add new cases inside that guarantee.

**Deploying a code change needs a file copy plus `-SelfHeal`,** never
`-Install`. Since 1.6.0 the healer restores the whole install footprint, so a
copy-and-heal produces the same state `-Install` would, minus the Explorer
restart and the classic-menu preference.

## Never enumerate a real context menu to verify a change

Calling `IContextMenu` / `BHID_SFUIObject` loads **every installed shell
extension** into the calling process, and they draw their own UI and steal
focus. Verify by reading back the strings written to the registry and asserting
them against separately-measured known-good forms — which is what `-SelfTest`
does. Measurements already taken are recorded in the notes; do not re-derive
them by probing the shell.

## Language and style constraints

- **`Set-StrictMode` is deliberately not used.** `registrations.json` is read
  across script versions, and StrictMode v3 throws on a missing property. All
  reads go through `Get-SafeProperty`.
- **Never name a variable `$settings` at script scope.** PowerShell parameter
  names are case-insensitive, so it collides with the `[switch]$Settings`
  parameter and throws a cast error. Use `$prefs`. Inside a function the local
  shadows safely, which is why several functions do use it.
- **Any `[Math]` call mixing an integer literal with an `[int64]` needs the
  literal cast too.** `[Math]::Max(0, $x)` binds `Max(int, int)` and throws past
  2 GB. This has already cost two features their behaviour; both were invisible
  because the caller wrapped them in a non-fatal `try`.
- Non-fatal `try`/`catch` around registry writes is the established pattern, but
  anything swallowed must be `Write-Log`ged with enough detail to diagnose from
  the log alone. A silent `catch { }` is only acceptable in `Write-Log` itself.

## Registry and store invariants

- **`New-Item -Path <regkey> -Force` deletes the existing key's values.** For a
  verb key that means losing `AppliesTo`, which does not fail open harmlessly —
  it shows both context-menu verbs on every item at once. Create only keys that
  are missing. `Set-ContextMenuVerbs -OnlyMissing` is the safe writer, and a
  self-test case locks it.
- **`Edit-RegistrationStore` is the only safe way to mutate the store.** It takes
  an exclusive OS file lock and retries. `Save-RegistrationStore` overwrites
  wholesale and is for purge-to-empty only. Scriptblocks passed to it need
  `.GetNewClosure()` to capture locals.
- The store is keyed by `AppId`, which hashes the **exe path**. Moving a program
  necessarily mints a new AppId, a new ARP key and a new AUMID; there is no
  in-place update. `New-RelocatedEntry` tears the old artefacts down first.
- `AppliesTo` fails **closed** on malformed input and past ~30,500 characters.
  Only ever assemble a condition from validated, quoted literals, and never
  blank one with junk — removing the value is the safe reset.

## Two things WinRegister maintains

1. **Registrations** — the programs the user registered. Followed when they move,
   repaired when their artefacts drift, pruned only when genuinely gone.
2. **Its own install** — verb keys, the Apps & Features record, the Start Menu
   entries, the `PATH` entry. Added in 1.6.0 because everything in category 2
   used to be written by `-Install` alone, and `-Install` is exactly the command
   an upgrade cannot run.

Category 2 is guarded by two markers, and new footprint repairs must respect
both:

- `.installed` — written by `-Install`, removed by `-Uninstall`. Without the
  guard the healer would rebuild the context menu on the next `-List` and an
  uninstall would never stick.
- `.self-arp-owner` — `owned` or `external`. `-Install -SkipSelfArp` is the Inno
  Setup path and records `external`, so the healer never writes a second
  identical Apps & Features row beside the installer's own.

The classic-context-menu tweak is **not** in category 2. It is a machine-wide
shell preference the user may have changed on purpose, so only an explicit
`-Repair` applies it, never the silent pass.

## Verify against Microsoft, not memory

Every non-obvious Win32 decision in the script carries a Microsoft Learn link in
a comment. Keep that up. Facts already established and cited inline: PE
subsystem offset is `PE+0x5C` for both PE32 and PE32+; `ExtractIconEx` treats a
negative index as a resource id and needs a real path; a registry verb cannot
reach the Windows 11 top-level menu without `IExplorerCommand` plus package
identity.
