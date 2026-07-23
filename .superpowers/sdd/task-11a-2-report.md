# Task 11A.2 Report

## Status

Code complete; Windows PowerShell 5.1 verification pending.

This slice adds only verified filesystem inventory, copy, and same-volume
no-overwrite rename helpers. It adds no game mutation, lifecycle entry point,
DLL, compiler, external PowerShell module, credential, or real save.

## RED / GREEN evidence

### RED authored first

`Files.Tests.ps1` and its exact runner entry were created before
`CgceDiscovery.Files.psm1`. The required RED command was then attempted from
the macOS worktree:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\windows\Run-CgceDiscoveryTests.ps1'
zsh:1: command not found: powershell.exe
exit 127
```

The host also has no `pwsh` or `powershell` executable. Therefore the intended
Windows RED (missing filesystem module import) could not execute, and no
non-Windows substitute was treated as behavioral evidence.

### GREEN implementation and pending platform gate

The implementation now has 25 filesystem tests covering:

- drive, descendant, trailing-separator, case-insensitive, UNC, containment,
  and overlap canonical path behavior;
- path-component and nested-tree reparse rejection without recursive traversal;
- sorted relative-path/length/SHA-256 inventory and exact comparison;
- the exact 41-key deterministic run-path contract;
- strict object inventory envelopes, one-entry arrays, unknown fields,
  non-dense entries, ordering, duplicates, lengths, and lowercase checksums;
- verified file/tree copies, no-overwrite rejection, overlap rejection, and
  same-volume directory rename;
- the exact 14-function Files module export surface and Common module imports.

After implementation, the required GREEN command was attempted again and had
the same platform result:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\windows\Run-CgceDiscoveryTests.ps1'
zsh:1: command not found: powershell.exe
exit 127
```

No claim is made that the 47-test Windows suite passes. It must run unchanged
under Windows PowerShell 5.1 before any real server workflow uses these helpers.

## Available verification

- `./scripts/run-tests.sh` — full Lua suite run once; all tests reported PASS.
- `jq empty tools/windows-discovery/schemas/control-evidence.schema.json tools/windows-discovery/schemas/run-state.schema.json`
  — exit 0.
- `git diff --check` — exit 0.
- Static contract comparison — run paths `41/41`; Files exports `14/14`.
- Forbidden-surface scan — no `ConvertFrom-Json`, `Add-Type`,
  `Invoke-Expression`, recursive `Get-ChildItem`, deletion, game mutation, or
  probe invocation in `CgceDiscovery.Files.psm1`.
- Delimiter check — balanced parentheses, braces, and brackets in the new
  module and test file.

## Files changed

- `tests/windows/Files.Tests.ps1`
- `tests/windows/Run-CgceDiscoveryTests.ps1`
- `tools/windows-discovery/modules/CgceDiscovery.Files.psm1`
- `tools/windows-discovery/CgceDiscovery.Common.psm1`
- `.superpowers/sdd/task-11a-2-report.md`

The pre-existing untracked `.superpowers/sdd/progress.md` is not part of this
task and is not staged.

## Self-review

- Re-read the exact Task 2 brief, Approved Interfaces, stage design, Task 1
  path contract, and downstream lifecycle call sites.
- Confirmed canonical roots preserve `D:\` and UNC share roots, reject relative
  and drive-relative paths, compare case-insensitively, and use component
  boundaries rather than string prefixes.
- Confirmed tree traversal checks each item before descending and rechecks a
  queued directory immediately before enumeration.
- Confirmed inventory order uses ordinal comparison and every persisted entry
  has exact keys, a safe relative path, nonnegative Int64 length, and lowercase
  SHA-256.
- Confirmed `New-CgceRunPaths` is pure, emits the exact Task 1 key order, keeps
  all preserved originals/quarantines as run-qualified same-volume siblings,
  and places run artifacts below `<RunRoot>\<run_id>`.
- Confirmed tree copy calls exact `%SystemRoot%\System32\robocopy.exe` with
  `/E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ`, accepts only exit codes `0..7`,
  and exact-compares the destination inventory.
- Confirmed file copy and directory move reject an existing destination;
  directory move additionally requires equal volume roots.
- Confirmed production code contains no deletion and no later lifecycle or
  game code changed.

## Concerns / residual risk

The PowerShell source and all Windows tests remain unexecuted because this
macOS host has no PowerShell runtime. The residual risk is a Windows PowerShell
5.1 syntax/runtime or provider-semantics defect, especially in UNC
canonicalization, junction handling, one-entry JSON array preservation, or
robocopy exit behavior. Windows PowerShell 5.1 verification remains a mandatory
gate before operator use.

## Review-fix evidence — no-overwrite publication

Independent review identified that the original file copy, tree copy, and
directory move checked final-destination absence before calling APIs that could
overwrite, merge, or nest when another process created the destination between
the check and action.

The follow-up keeps the public interface unchanged and now:

1. copies files to a unique same-directory staging file with
   `System.IO.File.Copy(..., overwrite=false)`, verifies its length/SHA-256,
   revalidates source/staging/final component chains, and publishes with
   `System.IO.File.Move`;
2. robocopies trees to a unique same-directory staging tree, verifies its exact
   inventory, revalidates source/staging/final components and trees, and
   publishes with `System.IO.Directory.Move`;
3. replaces direct `Move-Item` with `System.IO.Directory.Move` after an
   immediate final revalidation;
4. leaves staging files/trees in place on copy, verification, reparse, or
   publication failure and contains no cleanup/deletion path.

Private module-scoped test seams deterministically inject:

- a competing final file after revalidation;
- a competing final directory after revalidation;
- a final-path junction before final revalidation;
- a competing direct-move destination after revalidation;
- robocopy exit code `8` with a preserved partial staging tree.

The tests assert that competing bytes are unchanged, trees are not merged,
sources are preserved, direct moves are not nested, final-path reparses are
rejected, and staging artifacts remain. A separate test selects a syntactically
different drive root and proves cross-volume move rejection occurs before the
source is touched.

Follow-up RED and GREEN Windows commands were both attempted and returned the
same honest platform limitation:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\windows\Run-CgceDiscoveryTests.ps1'
zsh:1: command not found: powershell.exe
exit 127
```

Follow-up available verification:

- `./scripts/run-tests.sh | tail -n 8` with `pipefail` — exit 0; final eight
  tests reported PASS.
- Schema parse, `git diff --check`, path-key `41/41`, export `14/14`, and
  forbidden-surface checks — exit 0.
- Balanced delimiter check for the module and test file — all deltas zero.
- Production Files module contains no `Copy-Item`, `Move-Item`, deletion,
  recursive `Get-ChildItem`, dynamic code, or game/probe mutation surface.

The synthetic cross-volume test validates the exact root-identity preflight on
one Windows host, but this macOS environment cannot execute a real
`Directory.Move` across two mounted Windows volumes. A Windows host with two
writable volumes must still confirm that provider/runtime behavior as part of
the mandatory PowerShell 5.1 gate.
