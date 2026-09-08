# What works and what doesn't

Approaches that were tried on this project and rejected, with the reason. The
reasons are not recoverable from the code, because the code no longer contains
the rejected approach.

---

## Context menu

### ✗ `wscript.exe launcher.vbs` as the context-menu trampoline

Worked for months, then began raising a modal **"There is no script engine for
file extension `.vbs`"** on every click, making registration impossible.

The engine was fine — `vbscript.dll` present, CLSID registered, the
`VBSCRIPT~~~~` Feature on Demand reporting `Installed`. The break was the
lookup: WSH resolves the engine through the extension's ProgID, Notepad++ sets
`HKCU\Software\Classes\.vbs` to `Notepad++_file` (which has no `ScriptEngine`
subkey), and **HKCU shadows HKLM in the HKCR merge** — so one per-user file
association broke `.vbs` execution machine-wide.

**Rule:** anything the shell invokes *by file extension* is owned by whichever
program last claimed that extension. A verb's `command` must point at a binary.

### ✗ `wscript.exe //E:vbscript` to force the engine

A proven one-token fix — measured `cscript //nologo //B x.vbs` exit 1, and exit
0 with `//E:vbscript` added. **Rejected on purpose.** VBScript is deprecated and
scheduled for removal, so this only moves the deadline. Replaced with a compiled
GUI-subsystem PE built by `csc.exe` at install time.

### ✗ `Add-Type -OutputAssembly` to build the launcher

Its behaviour differs between Windows PowerShell and PowerShell 7, and install
can run under either. `csc.exe` from
`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\` is invoked directly instead.

### ✗ A console-subsystem launcher stub

Flashes a window on every right-click. Subsystem 2 (`/target:winexe`) is the
whole point, and `Get-PESubsystem` asserts it in the self-test.

### ✗ Enumerating the real context menu to check verb visibility

`IContextMenu` / `BHID_SFUIObject` loads **every installed shell extension**
into the calling process — 7-Zip, PowerToys, VLC, TreeSize, WinMerge, Notepad++
and the rest — and they draw their own UI and steal focus. This caused a real
incident. Verify the strings written to the registry instead.

### ✗ Trying to put the entries on the Windows 11 top-level menu

Not possible from a script. Top-level placement requires a shell extension
implementing [`IExplorerCommand`](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)
registered with package identity — an MSIX package or a sparse package, which
needs signing. Registry verbs go under *Show more options*, full stop.
Neutralising the modern provider's CLSID per user is the only lever a script
has, and it needs an Explorer restart to take effect.

---

## Self-heal

### ✗ Deleting a registration whose target executable has vanished

The original behaviour, and wrong for the case that actually happens: portable
apps move constantly. An updater unpacks into a versioned sibling folder, a
tools drive gets reorganised, a reinstall lands elsewhere. The program still
exists and the user still wants it in Search. Relocate first; prune only when it
cannot be found at all.

### ✗ Bounding the relocation search by a fixed number of ancestor steps

Three levels. It failed on the real case that motivated the feature: an
executable four folders deep whose entire branch was replaced at once, so every
ancestor within reach was gone and the entry would have been **deleted** while
the program sat one level higher.

Correct rule: climb to the nearest *surviving* ancestor, bounded by what counts
as a searchable root — never a drive root, `%USERPROFILE%`, `%APPDATA%`,
`%TEMP%`, or the `AppData` container itself.

### ✗ Skipping a rejected ancestor and continuing the walk

That is how a search rooted in a temp folder steps over `Temp` and `Local` and
ends up enumerating all of `%APPDATA%`. The walk must **stop** at the first
rejected ancestor: everything above it is broader still.

### ✗ Inferring that a registered exe's parent folder is registered too

Tempting, for making the context menu recognise a registered folder. Wrong:
folder resolution runs `Find-PrimaryExecutable`, a heuristic over the folder's
*current* contents that can legitimately pick a different exe later. A cached
inference goes stale and starts hiding *Register* on folders that are not
registered. The path the user actually right-clicked is recorded as
`SourcePath` instead.

### ✗ Letting the footprint healer rebuild verb keys unconditionally

Would resurrect the context menu on the next `-List` or scheduled run, so an
uninstall would never stick. Gated on an install marker that `-Uninstall`
removes. A self-test case locks this.

### ✗ Having the silent healer restore the classic-menu tweak

It is a machine-wide shell preference, not WinRegister's own property. A
background task silently re-enabling something the user turned off is fighting
the user, and it cannot take effect before Explorer restarts anyway. Only the
explicit `-Repair` applies it.

---

## Registry

### ✗ `New-Item -Path <regkey> -Force` on a key that already exists

**Deletes that key's values.** Measured directly. For a verb key that means
losing `AppliesTo`, and an absent condition does not mean "no filter" in any
harmless sense — it means both verbs appear on every item at once, which is the
state 1.4.0 existed to end.

### ✗ Blanking an `AppliesTo` condition to disable it

`AppliesTo` fails **closed**, and inconsistently: an empty string and whitespace
fall back to *shown*, but junk (`!!!(`) and an unknown property fall back to
*hidden*. Removing the value is the only safe reset.

### ✗ A bare `imageres.dll,-5323` as an ARP `DisplayIcon`

`DisplayIcon` is read by whichever process renders the Settings page, so the
filename is resolved against *that* process's DLL search path.
[`ExtractIconEx`](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-extracticonexw)
documents `lpszFile` as the name of a file to extract from — it needs a real
path. The negative index is correct: it is a resource identifier, not an offset.

### ✗ `[Math]::Max(0, $someInt64)`

Binds the `Max(int, int)` overload because the literal is an `Int32`, and throws
for anything past 2 GB. Cost large programs their Apps & Features entry entirely,
invisibly, because the write was wrapped in a non-fatal `try`. Both arguments
must be `[int64]`, and the result must be clamped again before a `[int]` cast.

---

## Process

### ✗ Diagnosing from the code alone

The Apps & Features entry was missing for months and was assumed to be a
swallowed `Register-SelfInArp` failure, because the call site is wrapped in a
non-fatal `try`. It was not. The log — which had never rotated, so it was
complete back to first install — showed `-Install` had run three times in May
against a build that predates the function, and never since. The function had
simply never been called. **The log is the primary source; check it before
theorising about a failure path.**

### ✗ Letting subagents loose on a task that touches the registry

A prompt that says "analysis only" is not a constraint. Research subagents given
full tool access created their own `HKCU\Software\Classes\<class>\shell\ZZAT*`
verb keys to answer questions about the shell, several concurrently — scattering
62 junk verbs across seven classes including `*` and `AllFilesystemObjects`, and
one agent deleted keys it assumed were pre-existing user data but were actually
a sibling agent's artefacts. Constrain every subagent explicitly, or do this
work single-threaded.
