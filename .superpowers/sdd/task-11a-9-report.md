# Task 11A.9 Synthetic Lifecycle And Runbook Report

## Scope

Task 9 adds the full
`prepare -> fake invoke -> restore -> export` Windows behavior contract and the
staged Task 11A operator Runbook.

## Test-first contract

`tests/windows/Lifecycle.Tests.ps1` now proves through public entry points:

- original `Saved` bytes are restored;
- backup and quarantined clone remain;
- active marker becomes the exact completed marker;
- state reaches `EXPORTED/SUCCEEDED`;
- private evidence ZIP and sidecar exist and verify.

The test was authored before the final lifecycle documentation/status
alignment. A Windows RED/GREEN execution could not be recorded because neither
`powershell.exe` nor `pwsh` is installed on the macOS development host.

## Portable verification

Commands:

```text
./scripts/run-tests.sh
./scripts/verify-package.sh discovery
sh -n scripts/verify-discovery-handoff.sh scripts/build-discovery-handoff.sh
git diff --check
```

Result:

- full Lua suite passed;
- discovery package verification passed;
- both shell scripts passed syntax validation;
- diff whitespace validation passed.
- after Task 8 commit `b83b50a`, the real tracked-clean handoff verifier
  passed and two ZIP/sidecar builds were byte-identical.

## Documentation

Added:

- `docs/superpowers/specs/2026-07-24-cgce-windows-discovery-runbook-design.md`
- `docs/windows-discovery-operator-runbook.md`

The Runbook separates `[READY NOW]`, `[IMPLEMENTATION BLOCKED]`,
`[APPROVAL REQUIRED]`, and `[STOP]`. It intentionally withholds copy-ready
real-server commands until the Windows suite reports `failures=0`.

## Remaining gate

Run on elevated Windows PowerShell `5.1`:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Only `CGCE_WINDOWS_TESTS failures=0` may promote the real maintenance command
block. A separate user-approved real run is still required for Task 11A
operational completion.

## 2026-07-26 Windows PowerShell 5.1 follow-up

### RED evidence

Commit `00f2b10` was executed in Windows PowerShell `5.1`. The run was
interrupted after 125 completed test results:

- `117 PASS`;
- `8 FAIL`;
- no final `CGCE_WINDOWS_TESTS failures=<N>` line;
- no operator smoke result.

The eight observed failures covered one invalid blocked-state fixture setup,
one nested handoff payload array, and six process identity/wait descendants.
Because 54 of the current 179 tests did not complete, this transcript is not a
full baseline or pass artifact.

### Follow-up implementation

- The blocked-transition fixture now creates its active marker from
  byte-identical `CREATED` genesis/current state before writing the progressed
  `RUNNING` fixture.
- Handoff enumeration returns a flat PowerShell string sequence.
- Process FILETIME normalization floors both sources to the same DMTF
  microsecond boundary while retaining exact comparison between boundaries.
- The bounded wait slice and `WaitForExit` argument are explicit `Int32`
  values.
- The 38-case restore crash-boundary test emits five progress checkpoints
  without adding or removing test cases.

No checksum, marker, process-identity, timeout, recovery-barrier, no-overwrite,
or production-listener requirement was weakened.

### Portable verification

Commands:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
./scripts/run-tests.sh
./scripts/verify-package.sh discovery
sh -n scripts/verify-discovery-handoff.sh scripts/build-discovery-handoff.sh
git diff --check
```

All commands passed on macOS. Windows PowerShell `5.1` is not installed on the
development host, so the exact eight-test regression, ten-test smoke, and full
179-test GREEN results remain required from the Windows checkout before merge
or real maintenance.

### Operator smoke RED on `04b7606`

The exact ten-test smoke runner completed with eight passes and two failures:

- `export archives the exact private allowlist after restore`;
- `full synthetic lifecycle restores original bytes and exports evidence`.

Both failures occurred before export in their shared synthetic capture step.
The preserved process receipt set was exactly `000-launch.json` and
`001-pid.json`; no `999-result.json` existed. A direct call to
`Invoke-CgceChildProcess` produced `System.ArgumentException` at
`CgceDiscovery.Runtime.psm1:3807`.

The failing expression projected a `Collections.Generic.List[object]` through
`@($observed)`. Windows PowerShell `5.1` rejected that result projection with
an argument type mismatch. The follow-up uses the list's explicit `ToArray()`
snapshot cast to `object[]`, matching the already validated process-count and
termination call sites. The regression assertion forbids the array
subexpression and requires the explicit snapshot. Windows smoke and full
GREEN results are still pending.

### Operator smoke RED on `997b7eb`

The exact ten-test smoke runner again completed with eight passes and the same
two lifecycle test names failing. The child process result projection now
completed, so both paths advanced into their shared restore stage.

The preserved first fixture remained exactly `CAPTURED/ACTIVE`, contained no
state errors, and contained no restore receipts. A non-mutating breakpoint
diagnostic identified the original exception as
`CGCE-OPS-MANUAL-RECOVERY ambiguous recovery layout` from
`Assert-CgceRecoveryMatrix`.

The synthetic discovery process does not alter `Saved`, so the active clone
and inactive original legitimately had the same tree checksum. The recovery
matrix required those checksums to differ before it would inspect the
checksum-bound clone inventory, incorrectly rejecting this valid read-only
layout. The follow-up instead requires the active tree to match the exact
clone inventory authority and retains the existing phase, original,
quarantine, checksum, and no-overwrite checks. An equal-byte clone case was
added inside the existing recovery-matrix test without increasing the
179-test count. Windows smoke and full GREEN results are still pending.

### Operator smoke RED on `9b6a689`

The exact ten-test smoke runner again completed with eight passes and the same
two lifecycle test names failing. Restore now completed, but their shared
`Assert-CgceRestoredFixture` assertion raised
`CGCE-OPS-INVENTORY object is required`.

`Read-CgceInventory` returns the validated entry array rather than its JSON
envelope. Four lifecycle assertions incorrectly tried to read `.entries` from
that returned array. Commit `48eb741` changed only those tests to compare the
returned entries directly. Production restore and export behavior was not
weakened. Windows smoke and full GREEN results remained pending.

### Operator smoke RED on `48eb741`

The exact ten-test smoke runner again completed with eight passes and the same
two lifecycle test names failing, now at the shared export child with exit
code `1`. A non-mutating breakpoint diagnostic recovered
`CGCE-OPS-EXPORT-ALLOWLIST header staging copy failed` from
`New-CgceExportStaging`.

The exporter created `capture\CXXHeaderDump` before calling
`Copy-CgceTreeVerified` with that same path as its destination. The verified
tree-copy contract intentionally rejects any existing destination, so the
successful export path could never publish the header tree. The follow-up
leaves only the parent `capture` directory in the staging preamble and lets
`Copy-CgceTreeVerified` atomically publish the absent `CXXHeaderDump`
destination. The existing cross-platform export surface test now rejects
future pre-creation of that no-overwrite destination without adding a Windows
test or changing the ten-test smoke selection.

Portable verification passed on macOS. Windows smoke and full GREEN results
are still pending.
