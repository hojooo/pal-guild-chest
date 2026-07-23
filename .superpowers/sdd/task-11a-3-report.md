# Task 11A.3 Report

## Status

Code complete; Windows PowerShell 5.1 behavioral verification pending.

This slice adds only the isolated UE4SS inventory probe and Windows runtime
boundary. It does not modify a real server, firewall, service, watchdog,
scheduler, production Lua module, Gate A evidence, or game state.

## Contract resolution

The controller-approved runtime contract is now recorded in both the Task 3
implementation plan and authoritative stage design. It preserves the exact
41-key `Paths` schema and defines:

- Task 3-scoped fixed snapshot/probe/restore/process derived paths;
- immutable pre-launch `000-launch.json`, separate gapless `001..998` PID
  receipts, and `999-result.json`;
- exact JSON key sets, framed argument/path digests, tree digests, and no
  plaintext arguments;
- named `artifact_state` and `operation_pair_state` schemas;
- the normative selected-case × fixed-step restore matrix;
- receipt-aware executable allowlist count/digest matching; and
- the bounded ancestry-polling claim for actually observed descendants.

## RED / GREEN evidence

### RED authored first

`Runtime.Tests.ps1`, its exact runner entry, and the focused Lua handoff test
were authored before receipt-bearing runtime implementation.

Focused Lua RED:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
FAIL ... main.lua: No such file or directory
exit 1
```

Windows PowerShell 5.1 RED was attempted after the exact contract tests were
authored:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\windows\Run-CgceDiscoveryTests.ps1'
zsh:1: command not found: powershell.exe
exit 127
```

No macOS substitute is treated as Windows behavioral evidence.

### Available GREEN evidence

Focused Lua:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
PASS Windows discovery handoff > keeps the inventory probe isolated to the two UE4SS dumpers
exit 0
```

Full Lua:

```text
./scripts/run-tests.sh
lua_pass=432 lua_fail=0
exit 0
```

The Windows GREEN command was attempted after implementation and still returns
the environment limitation:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\windows\Run-CgceDiscoveryTests.ps1'
zsh:1: command not found: powershell.exe
exit 127
```

The suite contains 64 plain-PowerShell tests: Contract 22, Files 27, and
Runtime 15. No claim is made that they pass until the unchanged suite runs
under elevated Windows PowerShell 5.1.

## Runtime coverage

The Task 3 runtime tests cover:

- exact six-function export surface, Common import, and exact runner list;
- forbidden/safe argument tokens, one-element arrays, and fixed framed digest
  vectors;
- fail-closed CIM/TCP/UDP queries, exact process images, listener ports,
  receipt-aware allowlist digest matching, and PID reuse identity;
- exact probe bytes, five snapshot shapes, intent/operation/final schemas,
  nested state-pair keys, paths, checksums, and chains;
- crashes around each staging operation/receipt/final boundary;
- crashes around each restore operation/receipt/final boundary followed by
  prefix validation and idempotent resume;
- tampered frozen plan, operation, source path, and before-state rejection;
- ambiguous layout and unrelated quarantine preservation;
- active/preserved foreign artifact blocking; and
- synthetic child launch intent/root PID/result receipts, non-zero exit,
  argument non-disclosure, checksums, and replay blocking.

## Static verification

- `jq empty` on both existing Windows schemas: exit 0.
- `git diff --check`: exit 0.
- Runtime/test delimiter audit: parentheses, braces, and brackets balanced.
- Runtime export audit: exact six approved functions.
- Forbidden operator scan: no firewall/service/watchdog mutation, deletion,
  dynamic evaluation, `ConvertFrom-Json`, or game mutation surface.
- Probe exact-source test: only local control flow, `pcall`, `print`,
  `DumpAllObjects()`, and `GenerateSDK()`.
- Existing `New-CgceRunPaths` exact 41-key contract remains unchanged.

## Self-review

- Re-read the Task 3 brief, approved interfaces, authoritative stage design,
  downstream Task 5 process wording, and final controller contract sections
  for derived paths, restoration matrix, activity preflight, and acceptance.
- Confirmed snapshots precede intent and all production-path staging operations
  are no-overwrite, same-volume, receipt-chained, and crash-injected.
- Confirmed restore validates the longest staging and restoration prefixes,
  frozen plan shape/order/stage bindings, exact operation/path/state matrix,
  and only continues from the exact expected before or after state.
- Confirmed `Enable-CgceInventoryProbe` is the only probe-final writer and
  returns only its exact path/checksum.
- Confirmed launch intent is immutable and contains only argument count/digest;
  PID identity uses path plus UTC creation file time.
- Confirmed process timeout never kills, restores, restarts, or writes a
  success result.
- Confirmed no Task 4+ lifecycle entry point, capture/export payload, or
  production CGCE Lua module was added.

## Residual gates and concerns

Windows PowerShell 5.1 syntax, provider, CIM, `Start-Process`, robocopy,
one-element JSON, process creation-time, and no-overwrite filesystem semantics
remain unexecuted on this macOS host. The unchanged 64-test suite must report
`failures=0` on Windows before any synthetic or real operator use.

The process tracker polls `Win32_Process.ParentProcessId`. It enforces the
allowlist for every descendant it actually observes, but cannot prove complete
history for an extremely short-lived descendant that starts and exits between
polls. That limitation is explicit in the approved plan/spec; stronger
containment would require a native Job Object or durable process-start event
mechanism outside Task 11A.3.

No real Palworld server, listener, save, credential, or private evidence was
used. The pre-existing untracked `.superpowers/sdd/progress.md` remains
untouched and is excluded from the commit.
