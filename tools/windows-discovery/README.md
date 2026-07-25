# CGCE Windows Discovery Operator

This directory contains the server-local, read-only Task 11A operator tools.
They preserve the production `Saved` tree, run the isolated UE4SS inventory
probe only against a verified clone, restore the original and UE4SS
before-images, and create a private evidence archive.

These tools do not expand a chest, write a UObject, change a firewall or
service, start production, issue Gate A acceptance, or prove Steam Windows,
PS5, or macOS client compatibility.

## Source handoff

Build the deterministic source handoff on macOS from tracked, clean inputs:

```sh
./scripts/verify-discovery-handoff.sh
./scripts/build-discovery-handoff.sh
```

The builder creates:

- `dist/CGCE-Windows-Discovery-Handoff.zip`
- `dist/CGCE-Windows-Discovery-Handoff.zip.sha256`

The archive contains only the exact PowerShell source, schemas, inventory
probe, Windows synthetic tests, and `source-manifest.sha256`. It contains no
DLL, save, configuration, credential, private evidence, or vendored Lua
runtime.

## Windows validation gates

The existing runner is the developer/CI regression suite. It covers detailed
contract, filesystem, runtime, lifecycle, and harness behavior:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

The previous source baseline recorded on Windows PowerShell `5.1` was
174 tests, 100 passes, and 74 failures. Compatibility fixes have since changed
the source, so that result is historical and cannot validate the current
source. Do not use a real server path to work around a failure. The
developer/CI gate remains blocked until a fresh run ends with exactly
`CGCE_WINDOWS_TESTS failures=0`.

The operator smoke runner executes exactly ten representative safety and
lifecycle behaviors from an extracted, verified handoff:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoverySmokeTests.ps1
```

It passes only when its final line is exactly
`CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`. The smoke gate does not replace
the full regression gate. Real maintenance remains `[IMPLEMENTATION BLOCKED]`
until fresh runs of both gates pass and the maintenance window is separately
approved.

Synthetic regression and smoke tests must use mocked process/listener telemetry
or a dynamically allocated temporary port. They must not inspect or reserve the
production UDP `8211` listener. During an approved real maintenance run,
however, production must first be shut down and every configured server process
and listener, including `8211` when configured, must be absent. A remaining
process or listener is a hard stop.

## Private evidence

`Export-CgceDiscoveryEvidence.ps1` is a local packaging step, not a network
transfer tool. It accepts only a completed `RESTORED` run and produces:

- `CGCE-Windows-Discovery-<run_id>.zip`
- `CGCE-Windows-Discovery-<run_id>.zip.sha256`

The archive excludes save and configuration bytes, but inventory paths/hashes
and runtime dump names may still disclose pseudonymous identifiers. Keep it in
access-controlled private storage. Never commit it or attach it to a public
issue or release.

See `docs/windows-discovery-operator-runbook.md` for status gates, recovery
rules, and the approved maintenance sequence.
