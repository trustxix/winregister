# Insights

Non-obvious truths about this codebase and the Windows surfaces it sits on.
Rejected approaches live in
[`docs/what-works-and-what-doesnt.md`](../docs/what-works-and-what-doesnt.md);
this file is why the design is shaped the way it is.

---

## The failure mode of `AppliesTo` is invisible and inverted

Intuition says a broken or oversized filter degrades to "show everything". It
does the opposite: past ~30,500 characters, and on malformed syntax, the shell
silently **hides** the verb. For the negated condition — the "hide *Register*
when already registered" half — that means the *Register* entry disappears from
every file on the system, and the user has no way back through the UI.

This is why `ConditionMaxChars` exists, and why exceeding it deliberately
*removes* `AppliesTo` from both verbs rather than writing a shorter-but-wrong
one. Degrading to "both verbs always visible" is redundant but never a dead end.

The fail-open/fail-closed split is also inconsistent: empty and whitespace fall
back to *shown*, junk and unknown properties fall back to *hidden*. So clearing
the value is a safe reset and writing something wrong is not.

## Explorer re-reads the condition on every menu build

No `SHChangeNotify`, no Explorer restart, no sign-out. Verified by flipping a
condition three times inside one long-lived process and observing each change.
This is what makes the whole conditional-menu design viable: the menu can be
state-dependent because a registry write takes effect on the very next click.

## A `.lnk` does not expose its target to the shell's property system

`System.ItemPathDisplay` on a shortcut is the shortcut's own path, never the
target's. Matching a registration's `ExePath` will never light up its shortcut,
which is why `ShortcutPath` is bucketed separately into the `lnkfile` class.

## A path-derived AppId makes "the program moved" unrepresentable

`New-AppId` hashes the exe path, so relocating a registration necessarily mints
a new AppId, a new ARP key and a new AUMID. There is no in-place update; the
only correct move is to tear the old artefacts down and rebuild.
`New-RelocatedEntry` does exactly that, and deliberately keeps the *shortcut
file path* so the user's Start Menu layout survives even though everything
identifying the entry changed.

Two consequences that are easy to get wrong:

- The user's `DisplayName` must outrank the new binary's `ProductName`, or a
  rename silently reverts on the next move.
- `SourcePath` has to follow too, or a folder registration whose folder moved
  keeps offering *Unregister* on a directory that no longer holds the program.

## Bounding a filesystem search by step count is the wrong bound

The right bound is semantic, not numeric: climb to the nearest *surviving*
ancestor, and stop at the first directory too broad to search. A step count
answers "how far have I walked", when the question is "am I about to enumerate
something I have no business enumerating".

## Anything the shell resolves by name belongs to whoever claimed the name

Two instances of the same lesson, found eighteen weeks apart:

- A `.vbs` trampoline is owned by whichever program last claimed the `.vbs`
  extension. Notepad++ claimed it and the context menu died machine-wide.
- A bare `imageres.dll` in an ARP `DisplayIcon` is resolved against the DLL
  search path of whichever process renders Apps & Features — not ours.

If the shell will look something up on our behalf, hand it a full path or a real
binary. Never a name.

## An upgrade path that cannot run `-Install` will not have run `-Install`

The one that cost the most. `-Install` restarts Explorer, so in practice every
upgrade is deployed by replacing the script and letting the healer run. That
makes `-Install` the *least* frequently executed code path in the product —
while also being the only place several artefacts were ever written.

The Apps & Features entry added in 1.2.0 had never executed once on the author's
machine four months later, because `-Install` last ran against the build before
it. Nothing was broken; the code simply never ran.

**The general shape:** if a setup step is expensive enough that users avoid
re-running it, anything it alone performs is effectively dead code for existing
installs. Either the maintenance path performs it too, or it does not ship.
Since 1.6.0 the healer restores the whole install footprint, and `-Install` is
reduced to "the footprint, plus the Explorer restart, plus the shell preference".

## Self-healing needs a "should this exist at all" guard, not just "does it exist"

A healer that restores whatever is missing will faithfully restore an install
the user just removed. The existence check answers the wrong question. The
install marker answers the right one, and `-Uninstall` removing it is what makes
an uninstall stick.

The same shape applies to the Apps & Features entry: "the key is missing" does
not imply "write the key", because an installer may own that row. Deciding once,
writing the decision down, and honouring it thereafter is cheaper and more
correct than re-deriving it — and it must be written down *before* the write is
attempted, or a failing write turns a one-off three-hive registry scan into a
scan on every single right-click.

## Verification tooling can be more dangerous than the change

The natural way to test "is this verb visible?" is to enumerate the context menu
via `IContextMenu`. Doing so loads every installed shell extension into the
calling process, and they draw UI and steal focus. The durable alternative is to
verify the *strings written to the registry* against separately-measured
known-good forms.

The same instinct applies to the self-test generally: it asserts on constructed
entries and scratch registry roots rather than moving things on the user's disk.
The one place it declines to drive a full code path — `Repair-InstallFootprint`
with the install present — is because that path edits the user's `PATH`, and a
verification run has no business doing that.

## Stock Windows binaries are not a stable test fixture

`notepad.exe` is gone from `System32` on Windows 11 build 26200 — Notepad is a
Store app now — which had already broken two self-test cases before anyone
noticed. Any test that hard-codes a Microsoft binary path will rot. The suite
probes an ordered candidate list and takes the first that exists.

The same discipline applies to registry assertions: a test that assumes "no
other product on this machine is called WinRegister" passes today and fails on
someone else's machine. Assert on the specific key you created, not on the
absence of everything else.

## The log is the primary source

It has never rotated on the author's machine, so it is a complete record back to
the first install — and it settled in one query a question that months of
reading the code had answered wrongly. When a feature appears not to work, read
the log before theorising about which `catch` swallowed it.
