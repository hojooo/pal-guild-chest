# Task 11A.4 Implementation Report

## RED

Command:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Result: exit `127`.

```text
zsh:1: command not found: powershell.exe
```

This macOS host has no Windows PowerShell. The Windows PowerShell 5.1
synthetic execution gate remains external.

Portable RED command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: exit `1`. The new static Task 11A.4 contract failed for the intended
reason:

```text
FAIL defines a fail-closed Windows prepare entry point
tools/windows-discovery/Prepare-CgceDiscovery.ps1: No such file or directory
```

The two pre-existing Windows discovery handoff tests passed.

## GREEN

Portable focused command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: exit `0`; `3` passed.

Portable full-suite command:

```text
./scripts/run-tests.sh
```

Result: exit `0`.

Discovery package verification:

```text
./scripts/verify-package.sh discovery
```

Result: exit `0`.

```text
DISCOVERY_PACKAGE_VERIFIED
```

Schema and patch checks:

```text
jq empty tools/windows-discovery/schemas/control-evidence.schema.json \
  tools/windows-discovery/schemas/run-state.schema.json
git diff --check
```

Result: exit `0`.

The documented Windows command was rerun after implementation:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Result: exit `127`.

```text
zsh:1: command not found: powershell.exe
```

The new Windows tests are executable PowerShell 5.1 tests but were not run on
this macOS host. Static counting finds `89` `Invoke-CgceTest` cases in the
Windows suite. A real elevated Windows PowerShell 5.1 run remains mandatory.

## Failure matrix

| Required failure | Executable test evidence |
|---|---|
| process and listener activity | `Runtime.Tests.ps1`: `server activity blocks exact process images and configured ports` |
| CLI/control path mismatch | `Lifecycle.Tests.ps1`: `prepare pre-genesis failure matrix preserves active Saved bytes` |
| actual control checksum drift | same lifecycle matrix |
| handoff manifest and payload drift | same lifecycle matrix; exact manifest parsing also remains covered by `Contract.Tests.ps1` |
| PalServer checksum drift | the prepare authority re-hashes the state-bound executable before each mutation/checkpoint; `Runtime.Tests.ps1`: `child process writes immutable intent PID and result receipts without arguments` now injects a wrong expected executable checksum and proves no launch receipt is created, while state checksum identity is exercised by `Contract.Tests.ps1`: `run-state rejects identity drift non-monotonic revision and early receipts` |
| UE4SS checksum drift | lifecycle pre-genesis matrix |
| unsupported UE4SS | lifecycle pre-genesis matrix and `Contract.Tests.ps1`: `run-state accepts only null or exact UE4SS 3.0.1` |
| existing final run/layout | `Lifecycle.Tests.ps1`: replay test; `Files.Tests.ps1`: fixed final/staging layout rejection |
| expired evidence | lifecycle pre-genesis matrix and `Contract.Tests.ps1`: `rejects control drift incomplete paths and expiration` |
| containment and root overlap | lifecycle containment matrix case and explicit handoff/run-root overlap test; lower-level path cases remain in `Files.Tests.ps1` |
| reparse point | `Files.Tests.ps1`: path-component and tree reparse rejection tests |
| foreign active/incomplete artifacts | lifecycle active-marker/inactive-original matrix cases and `Runtime.Tests.ps1`: `foreign artifact preflight blocks active originals probe and mods enablement` |
| insufficient free space on each/same volume | `Files.Tests.ps1`: `disk capacity aggregates checked inventory bytes by canonical volume`, including same-volume `2S`, distinct-volume failure, and checked `Int64` overflow |
| copy/source drift | `Files.Tests.ps1`: verified tree copy drift before/after publication and robocopy failure tests |
| existing probe | lifecycle matrix and the Runtime foreign-artifact test |
| later revision versus immutable genesis/marker drift | `Contract.Tests.ps1`: original-as-genesis identity, marker genesis/path/process identity drift, immutable checksum fields, and CAS read-back replacement tests |
| pre-`BACKUP_VERIFIED` Saved byte identity | every lifecycle pre-genesis matrix case compares the complete original inventory; Files copy-failure tests prove source preservation; prepare never reaches its first production rename until durable `BACKUP_VERIFIED` CAS/read-back and a fresh authority check |

The PalServer live-byte recheck shares the same `Get-CgceSha256` primitive used
by the injected executable-checksum test. Deterministic between-checkpoint
tampering still needs the real Windows lifecycle run/fault environment; no
production environment-variable test bypass was added.

## Static safety review

- Delimiter/quote balance passed for every changed PowerShell file.
- Production Task 11A.4 files contain no UObject lookup, hook, invocation,
  game-thread, property-write, save, dirty, replication, or construction API.
- The prepare entry point has only its two final `Write-Output` sites, producing
  exactly one success or blocked terminal line.
- `git diff --check` and both JSON schema parses pass.

## Residual gate

Run the elevated Windows PowerShell 5.1 suite on the Windows discovery host:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Task 11A.4 must not be treated as Windows-verified until that command passes.
