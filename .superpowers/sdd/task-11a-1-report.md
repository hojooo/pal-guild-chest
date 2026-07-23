# Task 11A.1 Report

## Status

Code complete; Windows PowerShell 5.1 verification pending.

This slice remains discovery-only. It adds no game mutation, DLL, compiler,
external PowerShell module, credential, or real save.

## RED / GREEN evidence

### RED authored first

The test harness and `Contract.Tests.ps1` were created before the contract
module. The initial required command was attempted from the macOS worktree:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
zsh:1: command not found: powershell.exe
exit 127
```

The host also has no `pwsh` or `powershell` executable. Therefore the intended
Windows RED (missing module import) could not execute, and no substitute runtime
was used.

### GREEN implementation and pending platform gate

The implementation now has 17 plain-PowerShell contract tests covering:

- fixed identifiers and one-way phases;
- bounded strict UTF-8/RFC 8259 parsing, root kinds, arrays, duplicate keys,
  malformed UTF-8/surrogates/numbers, size, and depth;
- exact control evidence and expiry/checksum failures;
- UTF-8 no-BOM no-overwrite atomic JSON and run-state compare-and-swap;
- exact run-state keys, identity/revision/phase compatibility, and read-back;
- immutable genesis marker binding;
- exact sorted handoff manifest payloads;
- two-process exclusive lock rejection without lock-file content mutation.

The required GREEN command was attempted again after implementation and had the
same environment result:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
zsh:1: command not found: powershell.exe
exit 127
```

No claim is made that the Windows suite passes. It must be run unchanged on
Windows PowerShell 5.1 before this operator is used.

## Available verification

- `./scripts/run-tests.sh` — exit 0; full Lua suite passed.
- `git diff --check` — exit 0.
- `jq empty tools/windows-discovery/schemas/control-evidence.schema.json tools/windows-discovery/schemas/run-state.schema.json`
  — exit 0.
- Schema exact-key checks — control `19/19`, run state `24/24`, paths `41/41`,
  inventory checksums `4/4`.
- Forbidden-surface scan found no `ConvertFrom-Json`, `Add-Type`, compiler,
  UE4SS/game mutation, or probe invocation in Task 1 sources.

An optional Python JSON Schema meta-validation was unavailable because the
host has no `jsonschema` package; no dependency was installed.

## Files changed

- `tests/windows/TestHarness.ps1`
- `tests/windows/Run-CgceDiscoveryTests.ps1`
- `tests/windows/Contract.Tests.ps1`
- `tools/windows-discovery/modules/CgceDiscovery.Contract.psm1`
- `tools/windows-discovery/CgceDiscovery.Common.psm1`
- `tools/windows-discovery/schemas/control-evidence.schema.json`
- `tools/windows-discovery/schemas/run-state.schema.json`
- `.superpowers/sdd/task-11a-1-report.md`

The pre-existing untracked `.superpowers/sdd/progress.md` is not part of this
task and is not staged.

## Self-review

- Re-read the exact Task 1 brief, Approved Interfaces, and stage design.
- Confirmed every required state/path/control key and marker field is exact.
- Confirmed compare-and-swap is restricted to validated `run-state.json`,
  uses `File.Replace`, rechecks the old checksum, and performs strict read-back.
- Confirmed ordinary outputs, temp files, genesis, and markers are no-overwrite.
- Confirmed strict JSON does not call `ConvertFrom-Json` and uses ordinal
  duplicate-key detection. Case-variant keys fail closed because Windows
  PowerShell `PSCustomObject` cannot represent them distinctly.
- Confirmed handoff traversal rejects reparse points before descending and
  requires the final exact payload allowlist.
- Confirmed lock ownership uses `FileShare.None`; lock contents are not used as
  authority.
- Confirmed no production Lua or release artifact changed.

## Concerns / residual risk

The PowerShell source and all 17 Windows tests remain unexecuted because this
macOS host has no PowerShell runtime. The highest residual risk is a Windows
PowerShell 5.1 syntax/runtime compatibility defect in the custom parser or
filesystem semantics. Run the required Windows suite before Task 11A.2 relies
on these interfaces or any real server workflow begins.

## Review-fix evidence — 2026-07-23

Three Important review findings were addressed in a separate scoped fix:

1. `Assert-CgceStateShape` now accepts `ue4ss_version` only when it is `null`
   or the exact case-sensitive string `3.0.1`. Regression coverage accepts
   `3.0.1` and rejects `3.0.10`, `V3.0.1`, and `3.0.1 `.
2. `Assert-CgceRunMarker` now invokes the existing full immutable
   genesis/current identity comparison. Regression coverage independently
   changes a bound checksum, one recorded path, and the process-image list.
3. `Write-CgceRunState` post-replacement confirmation now reopens through a
   private test seam. Behavior tests call the public writer, prove a successful
   replacement/reopen with revision `1`, keep the pre-replacement file handle
   readable while the path resolves the replacement, and inject a reopen
   failure after replacement. The failure is surfaced while `run-state.json`
   remains present, the new revision is readable after reimport, and no temp
   path remains.

Tests were written before these production changes. The required Windows RED
and GREEN commands were each attempted:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
zsh:1: command not found: powershell.exe
exit 127
```

The suite now contains 22 PowerShell contract tests, but none can execute on
this macOS host. Available post-fix verification:

- `./scripts/run-tests.sh` — exit 0; full Lua suite passed.
- `git diff --check` — exit 0.
- `jq empty tools/windows-discovery/schemas/control-evidence.schema.json tools/windows-discovery/schemas/run-state.schema.json`
  — exit 0.

Residual risk remains unchanged: run the unchanged suite under Windows
PowerShell 5.1 before another task consumes these contracts or any real-server
operation begins.
