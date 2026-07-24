# Task 11A.6 RED Contract/Files Recovery Slice Report

## Scope and status

This is the Task 11A.6 Step 1 RED-only Contract/Files slice. It adds the
recovery authority tests before any Task 11A.6 production implementation.
No production module, restore entry point, plan/spec, package, harness, or
user-owned `.superpowers/sdd/progress.md` file was modified.

## Added Contract coverage

- `shared inventory tree digest freezes framing ordering and strict entries`
- `recovery intent accepts only the exact source preimage and fixed step schema`
- `recovery state inactivity matches Runtime over process PID and port fixtures`
- `recovery probe completion matches Runtime over journal and terminal fixtures`
- `recovery state writers reject state-only and sentinel-only manual barriers`
- `recovery blocker owns exact ACTIVE and BLOCKED revision-plus-two deltas`
- `recovery completion requires exact 000 010 020 999 authority`

The digest test freezes the `CGCE-TREE-1` vector
`412f6bcca9f94ba03373a6180ba1749034ab11912708a725605af2b32bc06c6b`,
strictly sorted entries, duplicate rejection, and exact entry fields. The
recovery tests assert persisted state bytes, return matrices, and filesystem
bytes rather than source-text implementation details. The inactivity case uses
an actual renamed `cmd.exe` server-path process plus a loopback listener; it
does not add a production test hook.

## Added Files coverage

- `recovery matrix freezes the exact phase case and two-step contract`
- `recovery matrix resumes only intent-bound before or after states`
- `recovery matrix rejects foreign quarantine without mutation`

The module export contract now also reserves `Assert-CgceRecoveryMatrix`.

## RED verification

Portable focused command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: the runner reported the intended new RED failure while the five
pre-existing handoff checks passed:

```text
FAIL defines Task 6 fixed-purpose recovery exports and restore entry point
tests/integration/discovery_handoff_spec.lua:334: expected true, got false
```

The failure is expected: Contract does not yet export
`Get-CgceInventoryTreeSha256`, `Write-CgceRecoveryRunState`,
`Block-CgceRecoveryRunState`, or `Complete-CgceRecoveryRunState`, and the
Restore entry point does not yet exist.

Windows behavior gate command (attempted exactly as required):

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Result: exit `127` / unavailable on this macOS host.

```text
zsh: command not found: powershell.exe
```

This does not claim behavioral execution. An elevated Windows PowerShell 5.1
run remains required after the Task 11A.6 production implementation.

## Files changed

- `tests/windows/Contract.Tests.ps1`
- `tests/windows/Files.Tests.ps1`
- `tests/integration/discovery_handoff_spec.lua`
- `.superpowers/sdd/task-11a-6-report.md`

## Self-review

- Verified scope excludes all production and user-owned progress files.
- Confirmed every required Contract and Files test name is present.
- Confirmed tests target observable state, filesystem, digest, and returned
  matrix behavior, with no new production test seam.
- The portable RED assertion fails specifically because the planned public
  exports are absent; Windows test execution is intentionally not represented
  as a pass.
