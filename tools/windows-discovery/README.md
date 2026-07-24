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

## Windows validation gate

From an elevated Windows PowerShell `5.1` process and an extracted, verified
handoff:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Do not use the real server unless the final line is exactly
`CGCE_WINDOWS_TESTS failures=0` and the operator Runbook marks the maintenance
procedure `[APPROVAL REQUIRED]`.

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
