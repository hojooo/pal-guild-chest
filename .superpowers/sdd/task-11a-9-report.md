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
