# Task 11A.7 Private Evidence Export Report

## Scope

Task 7 adds a Windows PowerShell `5.1` private evidence exporter and its strict
manifest schema. The exporter performs no network transfer and includes no
save or configuration bytes.

## RED

Command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Observed failure before production source was added:

```text
FAIL defines the strict private evidence export surface
tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1: No such file or directory
```

Windows behavior tests were added first to `tests/windows/Lifecycle.Tests.ps1`
for phase/outcome rejection, missing/escaped/sensitive/existing-output
rejection, exact archive contents, state transition, valid resume, and tampered
resume. Follow-up review added stale-control, output-root overlap, and a
checksum-coherent but authority-rebound archive rejection case. They cannot
execute on the macOS development host.

## GREEN

Focused portable command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result:

```text
PASS Windows discovery handoff > defines the strict private evidence export surface
```

Implemented:

- checksum-bound bootstrap before importing handoff modules;
- provisional state read, server-global lock, then authoritative state re-read;
- exact `RESTORED/ACTIVE` state and completed-only marker requirement;
- current control validity/binding, fixed source path, inventory, capture and
  normalized sensitive-key validation;
- no-overwrite staging, ZIP, manifest and SHA-256 sidecar;
- exact path/length/checksum binding from every staged and resumed payload back
  to current RESTORED authority;
- output-root separation from handoff, run and server roots;
- ZIP/sidecar read-back before `EXPORTED/SUCCEEDED`;
- `-Resume` for an exact pre-existing archive after a pre-CAS crash.

## Remaining gate

Run on elevated Windows PowerShell `5.1`:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Task 11A.7 behavior is not claimed complete until the suite reports
`failures=0`.
